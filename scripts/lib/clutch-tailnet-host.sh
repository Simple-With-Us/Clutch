#!/usr/bin/env bash
# Resolve this Mac's Tailscale MagicDNS name, and keep the running web server's
# --trusted-host list honest about it.
#
# Why this file exists.  Both launchers used to read the name once, at boot,
# with a one-shot `tailscale status --self --json`.  On macOS the Tailscale.app
# UI and the io.tailscale.ipn.macsy network extension routinely start minutes
# after login, so the read came back empty and the server was launched trusting
# only 127.0.0.1 and localhost.  Nothing ever corrected it: the Clutch iOS app
# sends `Host: <magicdns>:3180`, dsh's /api trust fence answered 403, and every
# remote request stayed broken until someone happened to restart clutch-web.
# Observed 2026-10-11 on jay-macbook: boot 11:55:02, clutch-web 11:55:26,
# Tailscale.app 11:59:22, ipn.macsy 12:10:54.
#
# CLUTCH_TAILNET_HOST overrides detection and skips the reconciler entirely.

# Seconds to wait for the tailscaled backend before giving up on a cold start.
CLUTCH_TAILNET_WAIT_SECONDS="${CLUTCH_TAILNET_WAIT_SECONDS:-30}"
# How often the background reconciler re-checks once the server is up.
CLUTCH_TAILNET_POLL_SECONDS="${CLUTCH_TAILNET_POLL_SECONDS:-15}"
# Give up reconciling after this long so a Mac that never joins a tailnet
# cannot keep a detached process alive forever.
CLUTCH_TAILNET_RECONCILE_SECONDS="${CLUTCH_TAILNET_RECONCILE_SECONDS:-1800}"
# Hard ceiling on self-restarts, so a flapping name cannot become a loop.
CLUTCH_TAILNET_MAX_RESTARTS="${CLUTCH_TAILNET_MAX_RESTARTS:-3}"

# One-shot detection.  Echoes the bare MagicDNS name, or nothing.
clutch_detect_tailnet_host() {
  command -v tailscale >/dev/null 2>&1 || return 0
  tailscale status --self --json 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{const d=String(JSON.parse(s).Self.DNSName||"").replace(/\.$/,"").toLowerCase();if(/^[a-z0-9.-]+$/.test(d)&&d.includes("."))process.stdout.write(d)}catch{}})' \
    2>/dev/null || true
}

# Echo the override, else detect, waiting up to CLUTCH_TAILNET_WAIT_SECONDS for
# a cold Tailscale to finish starting.  Waiting is bounded and short: the real
# backend can take far longer than any acceptable startup delay, and that case
# is handled by clutch_reconcile_tailnet_host instead.
clutch_tailnet_host() {
  if [[ -n "${CLUTCH_TAILNET_HOST:-}" ]]; then
    printf '%s' "$CLUTCH_TAILNET_HOST"
    return 0
  fi
  command -v tailscale >/dev/null 2>&1 || return 0

  local deadline=$((SECONDS + CLUTCH_TAILNET_WAIT_SECONDS)) host
  while :; do
    host="$(clutch_detect_tailnet_host)"
    [[ -n "$host" ]] && { printf '%s' "$host"; return 0; }
    (( SECONDS >= deadline )) && return 0
    sleep 1
  done
}

# Does the live dsh process already trust this authority?  Used to make the
# reconciler a no-op once it has done its job.
clutch_running_trusts_host() {
  local want="$1" pid cmd
  pid="$(/usr/sbin/lsof -nP -iTCP:"${CLUTCH_WEB_PORT:-3180}" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  [[ -n "$pid" ]] || return 1
  cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  [[ "$cmd" == *"--trusted-host ${want}"* ]]
}

# Restart the supervised server once so the corrected --trusted-host list is
# rebuilt.  Only ever called after a real mismatch was observed.
clutch_restart_web() {
  command -v pm2 >/dev/null 2>&1 || return 1
  pm2 restart clutch-web >/dev/null 2>&1
}

# Detached watchdog.  Forked before the launcher execs into the web server, so
# it outlives the startup path and can fix the host list after the fact.
clutch_reconcile_tailnet_host() {
  local deadline=$((SECONDS + CLUTCH_TAILNET_RECONCILE_SECONDS)) restarts=0 host

  # Never race the launch itself: give the port holder a moment to appear.
  sleep "$CLUTCH_TAILNET_POLL_SECONDS"

  while (( SECONDS < deadline )); do
    host="$(clutch_detect_tailnet_host)"
    if [[ -n "$host" ]]; then
      if clutch_running_trusts_host "$host"; then
        return 0
      fi
      (( restarts < CLUTCH_TAILNET_MAX_RESTARTS )) || return 0
      restarts=$((restarts + 1))
      echo "clutch-web: '$host' now reachable but not trusted; restarting to pick it up (${restarts}/${CLUTCH_TAILNET_MAX_RESTARTS})" >&2
      clutch_restart_web || true
      return 0
    fi
    sleep "$CLUTCH_TAILNET_POLL_SECONDS"
  done
}