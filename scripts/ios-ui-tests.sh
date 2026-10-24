#!/usr/bin/env bash
# Run the Clutch iOS UI tests and leave the screenshots where CI can publish
# them.
#
# The hosted runner does not always have an iOS simulator runtime
# installed, so this resolves a device first:
#
#   1. use an available iPhone simulator, if the image has one;
#   2. otherwise download the iOS platform and create a device;
#   3. otherwise skip (exit 10) — the iOS build job still gates the change,
#      and a missing runtime is not a broken test.
#
# Exit codes: 0 the tests passed, 10 skipped (no simulator), anything else
# the tests failed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"
RESULT_BUNDLE="${CLUTCH_UI_RESULT_BUNDLE:-$REPO_ROOT/ios-ui.xcresult}"
DEVICE_NAME="${CLUTCH_UI_DEVICE_NAME:-}"

log() { printf 'ios-ui-tests: %s\n' "$1" >&2; }

available_devices() {
  # Names of the iPhone simulators this image can actually run.
  xcrun simctl list devices available 2>/dev/null \
    | awk -F '[()]' '/iPhone/ { print $2 }' \
    | sed 's/[[:space:]]*$//' \
    | grep -v '^$' \
    | head -20
}

pick_device() {
  local devices
  devices="$(available_devices)"
  [ -n "$devices" ] || return 1
  if [ -n "$DEVICE_NAME" ]; then
    printf '%s\n' "$devices" | grep -Fxq "$DEVICE_NAME" || return 1
    printf '%s\n' "$DEVICE_NAME"
    return 0
  fi
  # The newest runtime first: simctl lists them newest first.
  printf '%s\n' "$devices" | head -1
}

download_runtime() {
  log "no iOS simulator runtime on this image; downloading the iOS platform"
  xcodebuild -downloadPlatform iOS >>"$REPO_ROOT/ios-ui-download.log" 2>&1 || return 1
  # A downloaded runtime needs a device of its own.
  local runtime
  runtime="$(xcrun simctl list runtimes 2>/dev/null | awk -F '[()]' '/iOS/ { print $2; exit }')"
  [ -n "$runtime" ] || return 1
  local identifier
  identifier="$(xcrun simctl list devicetypes 2>/dev/null | awk -F '[()]' '/iPhone 16 Pro/ { print $2; exit }')"
  [ -n "$identifier" ] || identifier="iPhone 16 Pro"
  xcrun simctl create "Clutch UI iPhone" "$identifier" "$runtime" >/dev/null 2>&1 || return 1
  return 0
}

cd "$IOS_DIR" || exit 1
xcodegen generate || exit 1

DEVICE="$(pick_device || true)"
if [ -z "$DEVICE" ]; then
  if download_runtime; then
    DEVICE="$(pick_device || true)"
  fi
fi
if [ -z "$DEVICE" ]; then
  log "skipped: no iOS simulator runtime available on this machine"
  exit 10
fi
log "running the UI tests on $DEVICE"

set -o pipefail
xcodebuild -project Clutch.xcodeproj \
  -scheme Clutch \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -only-testing:ClutchUITests/ClutchThreadSurfaceUITests \
  -resultBundlePath "$RESULT_BUNDLE" \
  test
status=$?

if [ "$status" -ne 0 ]; then
  log "the UI tests failed (xcodebuild exit $status)"
  exit "$status"
fi
log "the UI tests passed; the result bundle is at $RESULT_BUNDLE"
exit 0
