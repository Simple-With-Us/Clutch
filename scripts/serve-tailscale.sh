#!/usr/bin/env bash
# Publish Clutch web (127.0.0.1:$CLUTCH_WEB_PORT, default 3180) on this Mac's
# Tailscale HTTPS port of the same number.  Idempotent.  Does not funnel
# (tailnet only).  Live: ~/apps/clutch-runtime/scripts/serve-tailscale.sh
set -euo pipefail

# shellcheck source=lib/clutch-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/clutch-env.sh"
# shellcheck source=lib/clutch-tailnet-host.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/clutch-tailnet-host.sh"

if ! command -v tailscale >/dev/null 2>&1; then
  echo "clutch serve-tailscale: tailscale CLI not on PATH" >&2
  exit 127
fi

PORT="$CLUTCH_WEB_PORT"
TARGET="http://127.0.0.1:${PORT}"
# This Mac's MagicDNS name, unless CLUTCH_TAILNET_HOST overrides it.  Same cold
# start race as start-web.sh: at boot Tailscale is often not up yet, in which
# case `tailscale serve` below is deferred rather than dropped.
HOST="$(clutch_tailnet_host)"

if [[ -n "$HOST" ]]; then
  tailscale serve --bg --https="$PORT" "$TARGET"
  echo "clutch-web on Tailscale: https://${HOST}:${PORT} -> ${TARGET}"
else
  echo "clutch serve-tailscale: Tailscale not ready; will publish https://:<${PORT}> once it is" >&2
  (
    deadline=$((SECONDS + ${CLUTCH_TAILNET_RECONCILE_SECONDS:-1800}))
    while (( SECONDS < deadline )); do
      sleep "${CLUTCH_TAILNET_POLL_SECONDS:-15}"
      host="$(clutch_detect_tailnet_host)"
      [[ -n "$host" ]] || continue
      tailscale serve --bg --https="$PORT" "$TARGET" >/dev/null 2>&1 && {
        echo "clutch-web on Tailscale (late): https://${host}:${PORT} -> ${TARGET}" >&2
        return 0
      }
    done
  ) >/dev/null 2>&1 &
  disown || true
  echo "clutch-web on Tailscale: pending (Tailscale not up at start) -> ${TARGET}"
fi
