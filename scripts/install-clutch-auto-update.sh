#!/usr/bin/env bash
# install-clutch-auto-update.sh -- install (or remove) the Clutch auto-updater.
#
# Writes two things and then loads the LaunchAgent:
#   ~/apps/clutch-auto-update.sh                        stable live copy of the updater
#   ~/Library/LaunchAgents/com.jay.clutch-auto-update.plist
#
# The live copy is deliberately a regular file OUTSIDE ~/apps/clutch-runtime:
# the updater moves that checkout, and bash must never read a script the checkout
# rewrites underneath it.  The updater refreshes its own live copy atomically
# after each successful pull.
#
# Usage:
#   scripts/install-clutch-auto-update.sh              install + bootout/bootstrap
#   scripts/install-clutch-auto-update.sh --no-load    write files, do not load
#   scripts/install-clutch-auto-update.sh --print-plist  print the plist, touch nothing
#   scripts/install-clutch-auto-update.sh --uninstall  bootout and remove both
#   scripts/install-clutch-auto-update.sh --verify     show job state and last log lines
#
# Requires no sudo: it is a per-user LaunchAgent.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$HERE/auto-update-mac.sh"
LABEL="${CLUTCH_AUTO_UPDATE_LABEL:-com.jay.clutch-auto-update}"
LIVE_SCRIPT="${CLUTCH_AUTO_UPDATE_SELF:-$HOME/apps/clutch-auto-update.sh}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/apps/logs"
LOG="$LOG_DIR/clutch-auto-update.log"
DOMAIN="gui/$(id -u)"

MODE="install"
for arg in "$@"; do
  case "$arg" in
    --no-load) MODE="write" ;;
    --print-plist) MODE="print" ;;
    --uninstall) MODE="uninstall" ;;
    --verify) MODE="verify" ;;
    -h | --help)
      sed -n '2,21p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "install-clutch-auto-update: unknown option $arg" >&2
      exit 64
      ;;
  esac
done

# The plist is a pure function of the paths, so it can be printed and checked
# without touching launchd or the home directory.
render_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$LIVE_SCRIPT</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/clutch-auto-update.launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/clutch-auto-update.launchd.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>$HOME</string>
  </dict>
</dict>
</plist>
PLIST
}

have_launchctl() { command -v launchctl >/dev/null 2>&1; }

unload() {
  have_launchctl || return 0
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 && echo "booted out $LABEL" || true
}

case "$MODE" in
  print)
    render_plist
    exit 0
    ;;
  uninstall)
    unload
    rm -f "$PLIST"
    rm -f "$LIVE_SCRIPT"
    echo "removed $PLIST and $LIVE_SCRIPT"
    exit 0
    ;;
  verify)
    if have_launchctl && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      echo "$LABEL is loaded:"
      launchctl print "$DOMAIN/$LABEL" | grep -E 'state = |last exit code = |runs = |program = ' || true
    else
      echo "$LABEL is NOT loaded"
    fi
    echo "--- live script ---"
    ls -l "$LIVE_SCRIPT" 2>/dev/null || echo "missing $LIVE_SCRIPT"
    echo "--- last 10 log lines ($LOG) ---"
    tail -n 10 "$LOG" 2>/dev/null || echo "(no log yet)"
    exit 0
    ;;
esac

[ -f "$SRC" ] || {
  echo "install-clutch-auto-update: missing $SRC" >&2
  exit 66
}

mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

# Atomic replace of the live copy: a run in flight keeps the inode it started on.
tmp="$LIVE_SCRIPT.tmp.$$"
cp "$SRC" "$tmp"
chmod 755 "$tmp"
mv "$tmp" "$LIVE_SCRIPT"
echo "installed $LIVE_SCRIPT"

render_plist >"$PLIST.tmp.$$"
chmod 644 "$PLIST.tmp.$$"
mv "$PLIST.tmp.$$" "$PLIST"
echo "wrote $PLIST"

if [ "$MODE" = "write" ]; then
  echo "not loaded (--no-load).  Load it with: launchctl bootstrap $DOMAIN $PLIST"
  exit 0
fi

if ! have_launchctl; then
  echo "install-clutch-auto-update: launchctl not found; this is a macOS-only install" >&2
  exit 69
fi
if ! command -v pm2 >/dev/null 2>&1; then
  echo "install-clutch-auto-update: warning: pm2 is not on PATH; the updater will log RESTART-FAILED" >&2
fi

unload
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "bootstrapped $LABEL (every 300s, RunAtLoad)"
echo "pause with: touch \$HOME/.clutch/auto-update.pause    remove with: rm \$HOME/.clutch/auto-update.pause"
