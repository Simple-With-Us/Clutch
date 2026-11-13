#!/usr/bin/env bash
# Run the Clutch iOS UI tests and leave the screenshots where CI can publish
# them.
#
# The hosted runner does not always have an iOS simulator runtime installed,
# so this resolves a device first:  use an available iPhone simulator,
# otherwise download the iOS platform and create a device, otherwise skip
# (exit 10).  The resolution itself lives in scripts/lib/ios-simulator.sh,
# which the unit-test script uses too.
#
# Exit codes: 0 the tests passed, 10 skipped (no simulator), anything else
# the tests failed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"
RESULT_BUNDLE="${CLUTCH_UI_RESULT_BUNDLE:-$REPO_ROOT/ios-ui.xcresult}"
DEVICE_NAME="${CLUTCH_UI_DEVICE_NAME:-}"

log() { printf 'ios-ui-tests: %s\n' "$1" >&2; }

# shellcheck source=lib/ios-simulator.sh
source "$REPO_ROOT/scripts/lib/ios-simulator.sh"

cd "$IOS_DIR" || exit 1
xcodegen generate || exit 1

DEVICE="$(clutch_ios_simulator_device "$DEVICE_NAME" || true)"
if [ -z "$DEVICE" ]; then
  log "skipped: no iOS simulator runtime available on this machine"
  exit 10
fi
log "running the UI tests on simulator $DEVICE"

set -o pipefail
xcodebuild -project Clutch.xcodeproj \
  -scheme Clutch \
  -destination "platform=iOS Simulator,id=$DEVICE" \
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
