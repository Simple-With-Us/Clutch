#!/usr/bin/env bash
# Update ~/Applications/Clutch.app seamlessly.
# Fast-forwards the runtime clone, reinstalls its dependencies, then re-runs
# install-dock-app.sh, which rebuilds, ad-hoc signs and relaunches Clutch.app.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LIVE="${CLUTCH_RUNTIME_ROOT:-${HOME}/apps/clutch-runtime}"

# Share the auto-updater's lock (LaunchAgent com.jay.clutch-auto-update runs
# scripts/auto-update-mac.sh every 5 minutes).  Two concurrent `npm ci` runs in
# one checkout can leave node_modules broken, so wait for the automatic run to
# finish; after two minutes, say so and proceed rather than block the operator.
# Only the process that created the lock removes it.
LOCK="${CLUTCH_HOME:-${HOME}/.clutch}/auto-update.lock"
mkdir -p "$(dirname "$LOCK")"
LOCK_HELD=0
waited=0
while [ "$LOCK_HELD" = "0" ]; do
  if mkdir "$LOCK" 2>/dev/null; then
    LOCK_HELD=1
  elif [ "$waited" -ge 120 ]; then
    echo "==> auto-update lock is busy; proceeding without it" >&2
    break
  else
    sleep 2
    waited=$((waited + 2))
  fi
done
trap '[ "$LOCK_HELD" = "1" ] && rmdir "$LOCK" 2>/dev/null || true' EXIT

echo "==> Updating Clutch Mac app from ${LIVE}..."
# Separate statements, not one `&&` chain: under `set -e` a command inside an
# AND-list is exempt from the errexit check unless it is the last one, so the
# old one-liner ran on after a failed `git pull` and still printed "Update
# complete" with exit 0.
git -C "$LIVE" pull --ff-only
(cd "$LIVE" && npm ci)
bash "$LIVE/scripts/install-dock-app.sh"
echo "==> Update complete.  Clutch.app is ready."
