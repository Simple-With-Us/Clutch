#!/usr/bin/env bash
# Publish Clutch web (127.0.0.1:$CLUTCH_WEB_PORT, default 3180) on this Mac's
# Tailscale HTTPS port of the same number.  Idempotent.  Does not funnel
# (tailnet only).  Live: ~/apps/clutch-runtime/scripts/serve-tailscale.sh
set -euo pipefail

# shellcheck source=lib/clutch-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/clutch-env.sh"

if ! command -v tailscale >/dev/null 2>&1; then
  echo "clutch serve-tailscale: tailscale CLI not on PATH" >&2
  exit 127
fi

PORT="$CLUTCH_WEB_PORT"
TARGET="http://127.0.0.1:${PORT}"
# This Mac's MagicDNS name, unless CLUTCH_TAILNET_HOST overrides it.
HOST="${CLUTCH_TAILNET_HOST:-$(tailscale status --self --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).Self.DNSName||"").replace(/\.$/,""))}catch{}})' 2>/dev/null || true)}"

tailscale serve --bg --https="$PORT" "$TARGET"
HOST="${HOST:-<this Mac MagicDNS name>}"
echo "clutch-web on Tailscale: https://${HOST}:${PORT} -> ${TARGET}"
