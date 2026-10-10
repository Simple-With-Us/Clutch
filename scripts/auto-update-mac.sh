#!/usr/bin/env bash
# auto-update-mac.sh -- keep the Clutch Mac deployment current with origin/main.
#
# The live copy is a STABLE regular file at ~/apps/clutch-auto-update.sh, run by
# LaunchAgent com.jay.clutch-auto-update every 5 minutes and at load.  It must
# never be a symlink into ~/apps/clutch-runtime: this script moves that checkout,
# and bash must not be reading a file the checkout rewrites.
#
# Each run:
#   1. fetch origin under a hard time cap; an up-to-date run exits silently;
#   2. stop early on a pause file, a dirty checkout, an interrupted merge, or a
#      lock held by a run that is still working;
#   3. fast-forward main to origin/main; a commit remembered as bad is skipped
#      until origin/main moves again;
#   4. npm ci only when package-lock.json moved or the toolchain is missing;
#   5. npm run sync, which copies profiles and agent presets into ~/.clutch/dsh;
#   6. smoke-test the engine (node_modules/.bin/dsh --version);
#   7. restart pm2 clutch-web when code the running server loads moved, then wait
#      for the port to answer and roll back if it never does;
#   8. rebuild the Dock app only when its own sources moved.
#   A failure after the fast-forward rolls the checkout back to the previous
#   commit, re-syncs, and remembers the bad sha, so a broken main never bricks
#   the Mac.
#
# Pause:   touch ~/.clutch/auto-update.pause     (resume: rm it)
# Log:     ~/apps/logs/clutch-auto-update.log    (no-op runs stay silent)
# Install: scripts/install-clutch-auto-update.sh (bootout/bootstrap the label)
#
# Every path and external command is overridable so the tracked vitest suite can
# exercise the branches against a fixture repo.  See tests/auto-update-mac.test.ts.
set -u

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

RUNTIME="${CLUTCH_RUNTIME_ROOT:-$HOME/apps/clutch-runtime}"
CLUTCH_HOME_DIR="${CLUTCH_HOME:-$HOME/.clutch}"
STATE_DIR="$CLUTCH_HOME_DIR"
LOG="${CLUTCH_AUTO_UPDATE_LOG:-$HOME/apps/logs/clutch-auto-update.log}"
LOCK_DIR="${CLUTCH_AUTO_UPDATE_LOCK:-$STATE_DIR/auto-update.lock}"
PAUSE_FILE="${CLUTCH_AUTO_UPDATE_PAUSE:-$STATE_DIR/auto-update.pause}"
BAD_FILE="${CLUTCH_AUTO_UPDATE_BAD_SHA:-$STATE_DIR/auto-update.bad-sha}"
SELF_STABLE="${CLUTCH_AUTO_UPDATE_SELF:-$HOME/apps/clutch-auto-update.sh}"
GIT_TIMEOUT="${CLUTCH_AUTO_UPDATE_GIT_TIMEOUT:-60}"
NPM_BIN="${CLUTCH_AUTO_UPDATE_NPM:-npm}"
NODE_BIN="${CLUTCH_AUTO_UPDATE_NODE:-node}"
PM2_BIN="${CLUTCH_AUTO_UPDATE_PM2:-pm2}"
PM2_JOB="${CLUTCH_AUTO_UPDATE_PM2_JOB:-clutch-web}"
ECOSYSTEM="${CLUTCH_AUTO_UPDATE_ECOSYSTEM:-$HOME/apps/pm2-ecosystem.config.cjs}"
WEB_PORT="${CLUTCH_WEB_PORT:-3180}"
HEALTH_URL="${CLUTCH_AUTO_UPDATE_HEALTH_URL:-http://127.0.0.1:$WEB_PORT/}"
HEALTH_ENABLED="${CLUTCH_AUTO_UPDATE_HEALTH:-1}"
CURL_BIN="${CLUTCH_AUTO_UPDATE_CURL:-/usr/bin/curl}"

# Command seams: set to override the real toolchain (the test suite uses this).
CMD_INSTALL="${CLUTCH_AUTO_UPDATE_INSTALL_CMD:-}"
CMD_SYNC="${CLUTCH_AUTO_UPDATE_SYNC_CMD:-}"
CMD_SMOKE="${CLUTCH_AUTO_UPDATE_SMOKE_CMD:-}"
CMD_DOCK="${CLUTCH_AUTO_UPDATE_DOCK_CMD:-}"
CMD_RESTART="${CLUTCH_AUTO_UPDATE_RESTART_CMD:-}"

# Paths whose change means the running web server must be restarted, and paths
# that mean the Dock app bundle must be rebuilt.  Docs, tests, CI config, the
# iOS app and image assets are none of the running Mac engine's business.
CODE_EXCLUDE_RE='^(docs/|tests/|e2e/|ios/|assets/|\.github/|[^/]+\.md$)'
DOCK_RE='^(src/web/dock-app/|assets/clutch-icon-1024\.png$|scripts/install-dock-app\.sh$)'

OLD=""
NEW=""
CHANGED=""
LOCKFILE_CHANGED=0

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %I:%M:%S%p')" "$*" >>"$LOG"; }

# git with a hard time cap: perl's alarm survives exec and kills a hung git.
rgit() { perl -e 'alarm shift; exec @ARGV' "$GIT_TIMEOUT" git -C "$RUNTIME" "$@"; }

do_install() {
  if [ -n "$CMD_INSTALL" ]; then bash -c "$CMD_INSTALL"; else (cd "$RUNTIME" && "$NPM_BIN" ci --no-audit --no-fund); fi
}
do_sync() {
  if [ -n "$CMD_SYNC" ]; then bash -c "$CMD_SYNC"; else (cd "$RUNTIME" && "$NPM_BIN" run --silent sync); fi
}
do_smoke() {
  if [ -n "$CMD_SMOKE" ]; then bash -c "$CMD_SMOKE"; else (cd "$RUNTIME" && "$NODE_BIN" node_modules/.bin/dsh --version); fi
}
do_dock() {
  if [ -n "$CMD_DOCK" ]; then bash -c "$CMD_DOCK"; else (cd "$RUNTIME" && bash scripts/install-dock-app.sh); fi
}
do_restart() {
  if [ -n "$CMD_RESTART" ]; then bash -c "$CMD_RESTART"; return $?; fi
  "$PM2_BIN" restart "$PM2_JOB" --update-env && return 0
  log "RESTART-FALLBACK  pm2 restart $PM2_JOB failed; trying pm2 start --only $PM2_JOB"
  [ -f "$ECOSYSTEM" ] || return 1
  "$PM2_BIN" start "$ECOSYSTEM" --only "$PM2_JOB" --update-env
}

web_up() {
  local code
  code="$("$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time 8 "$HEALTH_URL" 2>/dev/null || true)"
  case "$code" in
    2*|3*|401|403) return 0 ;;
    *) return 1 ;;
  esac
}

wait_web_up() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    web_up && return 0
    sleep 2
  done
  return 1
}

code_paths_changed() { printf '%s\n' "$CHANGED" | grep -Ev "$CODE_EXCLUDE_RE" | grep -q .; }
dock_paths_changed() { printf '%s\n' "$CHANGED" | grep -Eq "$DOCK_RE"; }
changed_contains() { printf '%s\n' "$CHANGED" | grep -qx "$1"; }

# Return the checkout to the last known-good commit and remember the bad one, so
# the next run does not retry it and a broken main never keeps the Mac down.
rollback() {
  local why="$1"
  log "ROLLBACK  $why; returning to ${OLD:0:7}"
  if ! rgit reset --hard "$OLD" >/dev/null 2>&1; then
    log "ROLLBACK-FAILED  could not reset to ${OLD:0:7}; operator needed"
    return 1
  fi
  if [ "$LOCKFILE_CHANGED" = "1" ]; then
    do_install >/dev/null 2>&1 || log "ROLLBACK-DEPS  npm ci at ${OLD:0:7} failed"
  fi
  do_sync >/dev/null 2>&1 || log "ROLLBACK-SYNC  npm run sync at ${OLD:0:7} failed"
  printf '%s\n' "$NEW" >"$BAD_FILE"
  return 0
}

# Refresh the stable live copy when the tracked script itself moved.  Atomic
# replace: the running bash keeps reading the inode it started with.
refresh_self() {
  local tracked="$RUNTIME/scripts/auto-update-mac.sh" tmp
  [ -f "$tracked" ] || return 0
  [ "$tracked" = "$SELF_STABLE" ] && return 0
  cmp -s "$tracked" "$SELF_STABLE" && return 0
  tmp="$SELF_STABLE.tmp.$$"
  if cp "$tracked" "$tmp" && chmod 755 "$tmp" && mv "$tmp" "$SELF_STABLE"; then
    log "SELF-UPDATED  live copy refreshed from ${NEW:0:7}"
  else
    rm -f "$tmp" 2>/dev/null || true
    log "SELF-UPDATE-FAILED  could not refresh $SELF_STABLE"
  fi
}

main() {
  mkdir -p "$(dirname "$LOG")" "$STATE_DIR"
  [ -e "$PAUSE_FILE" ] && exit 0

  # One run at a time.  A lock older than 30 minutes belongs to a dead run
  # (npm ci is the slow step, not git).
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
      log "STALE-LOCK  removing a lock older than 30 minutes"
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    else
      exit 0
    fi
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

  if ! git -C "$RUNTIME" rev-parse --git-dir >/dev/null 2>&1; then
    log "ERROR  $RUNTIME is not a git worktree"
    exit 1
  fi

  # A human mid-merge or mid-rebase owns the checkout; never touch it.
  if rgit rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || [ -d "$RUNTIME/.git/rebase-merge" ] || [ -d "$RUNTIME/.git/rebase-apply" ]; then
    log "SKIP-MERGING  $RUNTIME has a merge or rebase in progress"
    exit 0
  fi

  if ! rgit fetch -q origin; then
    log "FETCH-FAILED  git fetch origin did not finish; will retry next run"
    exit 0
  fi

  OLD="$(rgit rev-parse HEAD 2>/dev/null)" || { log "ERROR  cannot read HEAD"; exit 1; }
  NEW="$(rgit rev-parse origin/main 2>/dev/null)" || { log "ERROR  cannot read origin/main"; exit 1; }
  [ "$OLD" = "$NEW" ] && exit 0

  if [ "$NEW" = "$(cat "$BAD_FILE" 2>/dev/null)" ]; then
    exit 0 # already tried, rolled back; wait for origin/main to move
  fi

  # Tracked changes only; the runtime clone is never reset, cleaned or stashed.
  if [ -n "$(rgit status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    log "SKIP-DIRTY  $RUNTIME has tracked changes; not moving ${OLD:0:7} -> ${NEW:0:7}"
    exit 0
  fi

  CHANGED="$(rgit diff --name-only "$OLD" "$NEW" 2>/dev/null)"
  changed_contains "package-lock.json" && LOCKFILE_CHANGED=1

  if ! rgit merge --ff-only origin/main >/dev/null 2>&1; then
    log "FF-FAILED  ${OLD:0:7} -> ${NEW:0:7} is not a fast-forward; left as it was"
    exit 1
  fi

  # Dependencies: only when the lockfile moved, or when the toolchain the next
  # steps need is not actually installed.
  if [ "$LOCKFILE_CHANGED" = "1" ] || [ ! -x "$RUNTIME/node_modules/.bin/tsx" ] || [ ! -x "$RUNTIME/node_modules/.bin/dsh" ]; then
    if ! do_install; then
      rollback "npm ci failed at ${NEW:0:7}"
      exit 1
    fi
  fi

  if ! do_sync; then
    rollback "npm run sync failed at ${NEW:0:7}"
    exit 1
  fi

  # Smoke-test the engine before any restart can take the server down with it.
  if ! do_smoke; then
    rollback "engine smoke test failed at ${NEW:0:7}"
    exit 1
  fi
  rm -f "$BAD_FILE"

  log "UPDATED  ${OLD:0:7} -> ${NEW:0:7}  ($(printf '%s\n' "$CHANGED" | grep -c .) files)"

  if code_paths_changed; then
    if ! do_restart; then
      rollback "pm2 restart $PM2_JOB failed at ${NEW:0:7}"
      do_restart >/dev/null 2>&1 && log "RECOVERED  $PM2_JOB restarted at ${OLD:0:7}"
      exit 1
    fi
    if [ "$HEALTH_ENABLED" = "1" ] && ! wait_web_up; then
      rollback "$PM2_JOB did not answer $HEALTH_URL after restart"
      do_restart >/dev/null 2>&1 && wait_web_up && log "RECOVERED  $PM2_JOB healthy again at ${OLD:0:7}"
      exit 1
    fi
    log "RESTARTED  $PM2_JOB (engine code changed)"
  else
    log "NO-RESTART  only docs, tests, CI, iOS or assets moved"
  fi

  if dock_paths_changed; then
    if do_dock; then
      log "DOCK-REBUILT  ~/Applications/Clutch.app relaunched"
    else
      log "DOCK-FAILED  install-dock-app.sh failed; the Dock app is stale, the web is fine"
    fi
  fi

  refresh_self
}

main "$@"
exit $?
