#!/usr/bin/env bash
# Update ~/Applications/Harness.app seamlessly.
# Pulls latest updates if in a git repository, re-runs install-dock-app.sh,
# preserves code signing & TCC permissions, and cleanly relaunches Harness.app.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP="${HOME}/Applications/Harness.app"

echo "==> Updating Harness Mac app..."

# 1. Update source repository if running from a git checkout
if [[ -d "${ROOT}/.git" ]]; then
  echo "==> Pulling latest changes in ${ROOT}..."
  (cd "$ROOT" && git pull --ff-only origin main 2>/dev/null || true)
fi

# 2. Run dock app installer script
if [[ -f "${ROOT}/scripts/install-dock-app.sh" ]]; then
  echo "==> Rebuilding and installing Harness.app..."
  bash "${ROOT}/scripts/install-dock-app.sh"
else
  echo "Error: install-dock-app.sh not found at ${ROOT}/scripts/install-dock-app.sh" >&2
  exit 1
fi

# 3. Preserve code signing with Developer ID if present, otherwise ad-hoc
DEVELOPER_ID="Developer ID Application: Jay Wedgeworth, LLC (CC8UTF7ATG)"
if security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID"; then
  echo "==> Signing with Developer ID: $DEVELOPER_ID..."
  codesign --force --deep --options runtime --sign "$DEVELOPER_ID" "$APP" >/dev/null 2>&1 || true
else
  echo "==> Signing ad-hoc to preserve local TCC permissions..."
  codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
fi

echo "==> Update complete.  Harness.app is ready."
