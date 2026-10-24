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
# The device this script created, when it had to make one.
CREATED_DEVICE=""

log() { printf 'ios-ui-tests: %s\n' "$1" >&2; }

available_devices() {
  # "iPhone 16 Pro (UDID) (Shutdown)" lines, reduced to "UDID<TAB>name".
  # The UDID is what xcodebuild wants: a name is ambiguous when two runtimes
  # offer a device with the same name.  The parsing is plain awk, so it works
  # the same on macOS's BSD tools and on GNU ones.
  xcrun simctl list devices available 2>/dev/null \
    | awk '
        /^[[:space:]]+iPhone/ {
          name = $1
          for (i = 2; i <= NF; i++) {
            if ($i ~ /^\(/) { gsub(/[()]/, "", $i); print $i "\t" name; break }
          }
        }
      ' \
    | head -20
}

pick_device() {
  local devices
  devices="$(available_devices)"
  [ -n "$devices" ] || return 1
  if [ -n "$DEVICE_NAME" ]; then
    printf '%s\n' "$devices" | awk -F '\t' -v want="$DEVICE_NAME" '$2 == want { print $1; exit }'
    return 0
  fi
  # The newest runtime first: simctl lists them newest first.
  printf '%s\n' "$devices" | head -1 | cut -f1
}

download_runtime() {
  log "no iOS simulator runtime on this image; downloading the iOS platform"
  local log_file="${RUNNER_TEMP:-/tmp}/clutch-ios-ui-download.log"
  xcodebuild -downloadPlatform iOS >>"$log_file" 2>&1 || {
    log "the platform download failed (see $log_file); skipping the UI tests"
    return 1
  }
  # A downloaded runtime needs a device of its own.  `simctl list runtimes`
  # prints "iOS 18.2 (18.2 - 22C150) - com.apple.CoreSimulator.SimRuntime.iOS-18-2",
  # and `simctl create` wants that last identifier, not the version label.
  local runtime
  runtime="$(xcrun simctl list runtimes 2>/dev/null | awk '/iOS/ && /com.apple.CoreSimulator.SimRuntime/ { print $NF; exit }')"
  [ -n "$runtime" ] || return 1
  local identifier
  identifier="$(xcrun simctl list devicetypes 2>/dev/null | awk -F '[()]' '/iPhone 16 Pro/ { print $2; exit }')"
  [ -n "$identifier" ] || identifier="iPhone 16 Pro"
  # The created device is named "Clutch UI iPhone", which the device filter
  # below does not keep, so its identifier is captured here and used
  # directly.
  CREATED_DEVICE="$(xcrun simctl create "Clutch UI iPhone" "$identifier" "$runtime" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$CREATED_DEVICE" ] || return 1
  return 0
}

cd "$IOS_DIR" || exit 1
xcodegen generate || exit 1

DEVICE="$(pick_device || true)"
if [ -z "$DEVICE" ]; then
  if download_runtime; then
    DEVICE="$CREATED_DEVICE"
  fi
fi
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
