#!/usr/bin/env bash
# Run the Clutch macOS UI tests and leave the result bundle where CI can
# publish it.
#
# The Mac target used to be compiled in CI and never executed, so no defect
# on the Mac surface could fail a build.  This script is what gives the Mac
# surface a verdict.
#
# Exit codes: 0 the tests passed, 10 skipped (no runnable UI test host),
# anything else the tests failed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"
RESULT_BUNDLE="${CLUTCH_MAC_UI_RESULT_BUNDLE:-$REPO_ROOT/mac-ui.xcresult}"

log() { printf 'mac-ui-tests: %s\n' "$1" >&2; }

# Xcode hands environment variables prefixed with TEST_RUNNER_ to the test
# runner process, so the snapshot flags travel that way.  Exporting them into
# the shell alone leaves the runner without them, and the run compares
# against a baseline that was never recorded.
export TEST_RUNNER_CLUTCH_RECORD_SNAPSHOTS="${CLUTCH_RECORD_SNAPSHOTS:-}"
export TEST_RUNNER_CLUTCH_SNAPSHOT_DIR="${CLUTCH_SNAPSHOT_DIR:-}"

cd "$IOS_DIR" || exit 1
xcodegen generate || exit 1

# xcodebuild refuses to write over an existing result bundle, and a failed
# run leaves one behind.  Clearing it keeps a rerun working.
rm -rf "$RESULT_BUNDLE"

set -o pipefail
xcodebuild -project Clutch.xcodeproj \
  -scheme "Clutch macOS" \
  -destination "platform=macOS" \
  -resultBundlePath "$RESULT_BUNDLE" \
  test
status=$?

if [ "$status" -ne 0 ]; then
  log "the macOS UI tests failed (xcodebuild exit $status)"
  exit "$status"
fi
log "the macOS UI tests passed; the result bundle is at $RESULT_BUNDLE"
exit 0
