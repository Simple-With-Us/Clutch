#!/usr/bin/env bash
# Thin wrapper: ship the Clutch iOS companion to TestFlight (no Xcode UI).
# Prefers the in-repo fleet copy so GitHub-hosted macOS runners work without
# /Users/jay/apps/ios-fleet.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

STABLE_XCODE="${STABLE_XCODE:-/Applications/Xcode_27.0.app}"
STABLE_DEV_DIR="${STABLE_XCODE}/Contents/Developer"

resolved="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"

is_beta() {
  local dir="$1"
  [[ "$dir" == *Xcode-beta* ]] && return 0
  local plist="${dir%/Contents/Developer}/Contents/Info.plist"
  if [[ -r "$plist" ]]; then
    local ver
    ver=$(defaults read "$plist" CFBundleShortVersionString 2>/dev/null || echo "")
    [[ "$ver" == *[Bb]eta* ]] && return 0
  fi
  return 1
}

if [[ -n "$resolved" ]] && is_beta "$resolved"; then
  if [[ ! -d "$STABLE_DEV_DIR" ]]; then
    echo "ERROR: stable Xcode not found at ${STABLE_XCODE}." >&2
    echo "       Refusing to build for App Store Connect with a beta Xcode toolchain." >&2
    exit 1
  fi
  echo "[ios-ship] refusing beta toolchain at ${resolved}"
  export DEVELOPER_DIR="$STABLE_DEV_DIR"
elif [[ -n "$resolved" ]]; then
  export DEVELOPER_DIR="$resolved"
fi

if [[ -n "${DEVELOPER_DIR:-}" ]] && is_beta "$DEVELOPER_DIR"; then
  echo "ERROR: DEVELOPER_DIR still resolves to a beta Xcode (${DEVELOPER_DIR})." >&2
  exit 1
fi

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  echo "[ios-ship] DEVELOPER_DIR=${DEVELOPER_DIR}"
  xcodebuild -version 2>/dev/null | sed 's/^/[ios-ship] /' || true
fi

IN_REPO="${ROOT}/scripts/ios-fleet/ship-testflight.sh"
MAC="/Users/jay/apps/ios-fleet/ship-testflight.sh"
if [[ -f "$IN_REPO" ]]; then
  echo "[ios-ship] using in-repo fleet script: ${IN_REPO}"
  exec bash "$IN_REPO" clutch --repo-root "$ROOT" "$@"
fi
if [[ -f "$MAC" ]]; then
  echo "[ios-ship] WARNING: falling back to host ios-fleet at ${MAC}" >&2
  exec bash "$MAC" clutch --repo-root "$ROOT" "$@"
fi
echo "error: ios-fleet ship-testflight.sh not found at ${IN_REPO} or ${MAC}" >&2
exit 1
