#!/usr/bin/env bash
# Run the Clutch chat bridge (the native-chat SSE sidecar) and publish it on
# Tailscale.  Loopback only; tailnet clients arrive through `tailscale serve`.
# Started backgrounded from start-web.sh before it execs dsh web; safe to run
# by hand for a foreground sidecar.  Live: ~/apps/clutch-runtime/scripts/.
set -euo pipefail

# shellcheck source=lib/clutch-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/clutch-env.sh"

export CLUTCH_CHAT_PORT="${CLUTCH_CHAT_PORT:-3181}"
TARGET="http://127.0.0.1:${CLUTCH_CHAT_PORT}"

if command -v tailscale >/dev/null 2>&1; then
  tailscale serve --bg --https="$CLUTCH_CHAT_PORT" "$TARGET" >/dev/null 2>&1 || true
  echo "chat-bridge on Tailscale: https://:<${CLUTCH_CHAT_PORT}> -> ${TARGET} (tailnet only)" >&2
else
  echo "chat-bridge: tailscale CLI not on PATH; loopback only" >&2
fi

TSX="$CLUTCH_RUNTIME_ROOT/node_modules/.bin/tsx"
if [[ ! -x "$TSX" ]]; then
  echo "chat-bridge: missing $TSX — run npm ci in $CLUTCH_RUNTIME_ROOT" >&2
  exit 127
fi

exec "$TSX" "$CLUTCH_RUNTIME_ROOT/src/web/chat-bridge.ts"
