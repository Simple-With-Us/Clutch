#!/usr/bin/env bash
# Update ~/Applications/Clutch.app seamlessly.
# Fast-forwards the runtime clone, reinstalls its dependencies, then re-runs
# install-dock-app.sh, which rebuilds, ad-hoc signs and relaunches Clutch.app.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LIVE="${CLUTCH_RUNTIME_ROOT:-${HOME}/apps/clutch-runtime}"

echo "==> Updating Clutch Mac app from ${LIVE}..."
git -C "$LIVE" pull --ff-only && (cd "$LIVE" && npm ci) && bash "$LIVE/scripts/install-dock-app.sh"
echo "==> Update complete.  Clutch.app is ready."
