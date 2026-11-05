#!/usr/bin/env bash
# Run the Clutch iOS unit tests, the ClutchTests bundle.
#
# CI compiles this bundle today, because the Clutch scheme's test action
# builds every test target, but it never runs it: a failing assertion in the
# bundle could not fail a build, so the bundle was a compile gate and nothing
# more.  This script gives it a verdict.
#
# The simulator is resolved the way the UI tests resolve one:  use an
# available iPhone simulator, otherwise download the iOS platform and create a
# device, otherwise skip.  A missing runtime is not a broken test, so the
# script exits 10 when the machine has none, and the caller reports a skip.
#
# Exit codes: 0 the tests passed, 10 skipped (no simulator), anything else
# the tests failed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"
RESULT_BUNDLE="${CLUTCH_UNIT_RESULT_BUNDLE:-$REPO_ROOT/ios-unit.xcresult}"
DEVICE_NAME="${CLUTCH_UNIT_DEVICE_NAME:-}"

log() { printf 'ios-unit-tests: %s\n' "$1" >&2; }

# shellcheck source=lib/ios-simulator.sh
source "$REPO_ROOT/scripts/lib/ios-simulator.sh"

cd "$IOS_DIR" || exit 1
xcodegen generate || exit 1

DEVICE="$(clutch_ios_simulator_device "$DEVICE_NAME" || true)"
if [ -z "$DEVICE" ]; then
  log "skipped: no iOS simulator runtime available on this machine"
  exit 10
fi
log "running the unit tests on simulator $DEVICE"

set -o pipefail
xcodebuild -project Clutch.xcodeproj \
  -scheme Clutch \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  -only-testing:ClutchTests \
  -resultBundlePath "$RESULT_BUNDLE" \
  test
status=$?

if [ "$status" -ne 0 ]; then
  log "the unit tests failed (xcodebuild exit $status)"
  exit "$status"
fi
log "the unit tests passed; the result bundle is at $RESULT_BUNDLE"
exit 0
