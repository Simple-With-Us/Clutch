#!/usr/bin/env bash
# Always-on Harness web UI.  Loopback only; Tailscale Serve
# publishes https://<this Mac's MagicDNS name>:3080 (see serve-tailscale.sh).
# Live install: ~/apps/harness-runtime/scripts/start-web.sh
#
# HARNESS_RUNTIME_ROOT lets pm2 point the script's $ROOT at the repo root
# rather than scripts/, so node_modules and dsh.sh are found where the
# repo layout expects them.
set -euo pipefail

if [[ -n "${HARNESS_RUNTIME_ROOT:-}" ]]; then
  ROOT="$HARNESS_RUNTIME_ROOT"
else
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
export DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
export HARNESS_RUNTIME_ROOT="${HARNESS_RUNTIME_ROOT:-$ROOT}"
HOST="${DSH_WEB_HOST:-127.0.0.1}"
PORT="${DSH_WEB_PORT:-3080}"

# Launch-URL capture: dsh web 0.1.5-rc.2+ mints a per-process token that
# the Dock app's WKWebView must visit once to set a signed cookie.  We
# capture that token via a small Node shim instead of --no-open suppressing
# both the URL print and the browser open.
LAUNCH_URL_FILE="${DSH_LAUNCH_URL_FILE:-$DSH_HOME/web-launch-url}"

http_up() {
  local code
  code="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" || true)"
  case "$code" in
    2*|3*|401|403) return 0 ;;
    *) return 1 ;;
  esac
}

reclaim_harness_port() {
  local holder cmd
  holder="$(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  [[ -n "$holder" ]] || return 0
  cmd="$(ps -o command= -p "$holder" 2>/dev/null || true)"
  case "$cmd" in
    *dsh*|*dsh-runtime*|*harness*)
      if http_up "http://${HOST}:${PORT}/"; then
        echo "harness-web: :$PORT already healthy (pid $holder), skip reclaim" >&2
        exit 0
      fi
      echo "harness-web: reclaiming pid $holder on :$PORT" >&2
      kill -TERM "$holder" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8; do
        /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || return 0
        sleep 0.5
      done
      kill -KILL "$holder" 2>/dev/null || true
      sleep 0.5
      ;;
    *)
      echo "harness-web: :$PORT held by pid $holder ($cmd) — not harness, exit 3" >&2
      exit 3
      ;;
  esac
}

reclaim_harness_port

if [[ -x "$ROOT/scripts/serve-tailscale.sh" ]]; then
  "$ROOT/scripts/serve-tailscale.sh" || true
fi

# Every /api request must carry a trusted Host.  Trust loopback, the legacy
# tailnet name/IP, this Mac's detected MagicDNS name (what the Harness iOS app
# uses over Tailscale), and any comma-separated HARNESS_TRUSTED_HOSTS.
TRUSTED_HOSTS=(127.0.0.1 localhost "${HARNESS_TAILNET_HOST:-macbook.boa-roygbiv.ts.net}" "${HARNESS_TAILNET_IPV4:-100.113.106.39}")
detected_dns="$(tailscale status --self --json 2>/dev/null \
  | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{const d=String(JSON.parse(s).Self.DNSName||"").replace(/\.$/,"").toLowerCase();if(/^[a-z0-9.-]+$/.test(d)&&d.includes("."))process.stdout.write(d)}catch{}})' 2>/dev/null || true)"
if [[ -n "$detected_dns" ]]; then TRUSTED_HOSTS+=("$detected_dns"); fi
IFS=',' read -r -a extra_hosts <<< "${HARNESS_TRUSTED_HOSTS:-}"
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
  "$ROOT/scripts/harness.sh" web --no-open --host "$HOST" --port "$PORT" \
  "${TRUSTED_ARGS[@]}"
