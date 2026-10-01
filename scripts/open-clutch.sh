#!/usr/bin/env bash
# Open (or focus) the local Clutch window.  No Terminal.
# Display name "Clutch"; on-disk name `Clutch.app`; bundle id
# `codes.clutch.macos`.
set -euo pipefail
APP="${HOME}/Applications/Clutch.app"
LIVE="${CLUTCH_RUNTIME_ROOT:-${HOME}/apps/clutch-runtime}"
if [[ -d "$APP" ]]; then
  open -a "$APP"
  exit 0
fi
"${LIVE}/scripts/ensure-web.sh" || true
open "${CLUTCH_WEB_URL:-http://127.0.0.1:${CLUTCH_WEB_PORT:-3180}/}"
