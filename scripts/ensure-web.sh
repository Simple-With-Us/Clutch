#!/usr/bin/env bash
# Start pm2 clutch-web if Clutch web on 127.0.0.1:$CLUTCH_WEB_PORT (default
# 3180) is down.  No Terminal, no browser.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# shellcheck source=lib/clutch-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/clutch-env.sh"

PORT="$CLUTCH_WEB_PORT"
URL="${CLUTCH_WEB_URL:-http://127.0.0.1:${PORT}/}"
ECO="${HOME}/apps/pm2-ecosystem.config.cjs"
LOG="${HOME}/Library/Logs/clutch-web-open.log"
LIVE="$CLUTCH_RUNTIME_ROOT"
mkdir -p "$(dirname "$LOG")"

http_up() {
  local code
  code="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" || true)"
  case "$code" in
    2*|3*|401|403) return 0 ;;
    *) return 1 ;;
  esac
}
listening() {
  /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
}
http_up "$URL" && exit 0
# A listener on the port is already the web UI (auth-walled 401 counts).  Do
# not pm2 restart it — that reclaim-kills the healthy process.
if listening; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ensure-web: :$PORT listening, skip restart" >>"$LOG"
  exit 0
fi

{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ensure-web starting clutch-web"
  if [[ -f "$ECO" ]] && command -v pm2 >/dev/null 2>&1; then
    pm2 start "$ECO" --only clutch-web --update-env || true
  fi
  if ! http_up "$URL" && ! listening && [[ -x "${LIVE}/scripts/start-web.sh" ]]; then
    nohup "${LIVE}/scripts/start-web.sh" >>"$LOG" 2>&1 &
  fi
} >>"$LOG" 2>&1

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  http_up "$URL" && exit 0
  sleep 0.4
done
exit 1
