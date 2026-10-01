#!/usr/bin/env bash
# Always-on Clutch web UI.  Loopback only; Tailscale Serve publishes
# https://<this Mac's MagicDNS name>:$CLUTCH_WEB_PORT (see serve-tailscale.sh).
# Live: ~/apps/clutch-runtime/scripts/start-web.sh, run by pm2 `clutch-web`.
#
# Engine state lives in $CLUTCH_HOME/dsh (lib/clutch-env.sh forces DSH_HOME),
# so this never reads or writes the vanilla ~/.dsh.
set -euo pipefail

# shellcheck source=lib/clutch-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/clutch-env.sh"

ROOT="$CLUTCH_RUNTIME_ROOT"
HOST="$CLUTCH_WEB_HOST"
PORT="$CLUTCH_WEB_PORT"

# Launch-URL capture: dsh web 0.1.5-rc.2+ mints a per-process token that the
# Dock app's WKWebView must visit once to set a signed cookie.  We capture
# that token via a small Node shim instead of --no-open suppressing both the
# URL print and the browser open.
export CLUTCH_LAUNCH_URL_FILE="${CLUTCH_LAUNCH_URL_FILE:-$CLUTCH_HOME/web-launch-url}"

http_up() {
  local code
  code="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" || true)"
  case "$code" in
    2*|3*|401|403) return 0 ;;
    *) return 1 ;;
  esac
}

# Exit 3 (pm2 stop_exit_codes) means the port is held by a non-clutch process.
reclaim_clutch_port() {
  local holder cmd
  holder="$(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  [[ -n "$holder" ]] || return 0
  cmd="$(ps -o command= -p "$holder" 2>/dev/null || true)"
  # Case-insensitive: a checkout named `Clutch` is still ours.
  case "$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')" in
    *clutch-runtime*|*clutch*)
      if http_up "http://${HOST}:${PORT}/"; then
        echo "clutch-web: :$PORT already healthy (pid $holder), skip reclaim" >&2
        exit 0
      fi
      echo "clutch-web: reclaiming pid $holder on :$PORT" >&2
      kill -TERM "$holder" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8; do
        /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || return 0
        sleep 0.5
      done
      kill -KILL "$holder" 2>/dev/null || true
      sleep 0.5
      ;;
    *)
      echo "clutch-web: :$PORT held by pid $holder ($cmd) — not clutch, exit 3" >&2
      exit 3
      ;;
  esac
}

reclaim_clutch_port

if [[ -x "$ROOT/scripts/serve-tailscale.sh" ]]; then
  "$ROOT/scripts/serve-tailscale.sh" || true
fi

# Every /api request must carry a trusted Host.  Trust loopback, this Mac's
# MagicDNS name (what the Clutch iOS app uses over Tailscale; override with
# CLUTCH_TAILNET_HOST), an optional CLUTCH_TAILNET_IPV4, and any
# comma-separated CLUTCH_TRUSTED_HOSTS.
TRUSTED_HOSTS=(127.0.0.1 localhost)
tailnet_host="${CLUTCH_TAILNET_HOST:-$(tailscale status --self --json 2>/dev/null \
  | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{const d=String(JSON.parse(s).Self.DNSName||"").replace(/\.$/,"").toLowerCase();if(/^[a-z0-9.-]+$/.test(d)&&d.includes("."))process.stdout.write(d)}catch{}})' 2>/dev/null || true)}"
if [[ -n "$tailnet_host" ]]; then TRUSTED_HOSTS+=("$tailnet_host"); fi
if [[ -n "${CLUTCH_TAILNET_IPV4:-}" ]]; then TRUSTED_HOSTS+=("$CLUTCH_TAILNET_IPV4"); fi
IFS=',' read -r -a extra_hosts <<< "${CLUTCH_TRUSTED_HOSTS:-}"
for h in "${extra_hosts[@]:-}"; do
  if [[ -n "$h" ]]; then TRUSTED_HOSTS+=("$h"); fi
done

TRUSTED_ARGS=()
seen_hosts=" "
for h in "${TRUSTED_HOSTS[@]}"; do
  h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
  case "$seen_hosts" in *" $h "*) continue ;; esac
  seen_hosts+="$h "
  TRUSTED_ARGS+=(--trusted-host "$h" --trusted-host "$h:${PORT}")
done

exec node "$ROOT/scripts/capture-launch-url.cjs" \
  "$ROOT/scripts/clutch.sh" web --no-open --host "$HOST" --port "$PORT" \
  "${TRUSTED_ARGS[@]}"
