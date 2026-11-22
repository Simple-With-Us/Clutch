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

# The workflow turns exit 10 into a warning and a skip, so the script has to
# be able to say "there is nothing here to run".  A runner that offers no
# macOS destination cannot host the UI test, and the run skips with that
# answer instead of failing on a machine that was never able to run it.
#
# The listing has to succeed for the skip to be allowed:  a listing that
# fails is a broken project, and that is an error rather than a skip.
DESTINATIONS="$(xcodebuild -project Clutch.xcodeproj -scheme "Clutch macOS" -showdestinations 2>&1)"
show_status=$?
if [ "$show_status" -ne 0 ]; then
  log "xcodebuild could not list the destinations of the 'Clutch macOS' scheme"
  printf '%s\n' "$DESTINATIONS" >&2
  exit 1
fi
if ! printf '%s\n' "$DESTINATIONS" | grep -qE 'platform[:=]macOS'; then
  log "skipped: no runnable macOS UI test host on this machine"
  printf '%s\n' "$DESTINATIONS" >&2
  exit 10
fi

# xcodebuild refuses to write over an existing result bundle, and a failed
# run leaves one behind.  Clearing it keeps a rerun working.
rm -rf "$RESULT_BUNDLE"

set -o pipefail
# The hosted runner has no Mac Development certificate, and the Mac targets
# ask for one by team id.  A UI test has to be signed to run at all, so the
# run signs ad hoc instead:  an ad-hoc signature is enough for a test
# bundle and its host on the machine that runs it.
xcodebuild -project Clutch.xcodeproj \
  -scheme "Clutch macOS" \
  -destination "platform=macOS" \
  -resultBundlePath "$RESULT_BUNDLE" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  test
status=$?

if [ "$status" -ne 0 ]; then
  log "the macOS UI tests failed (xcodebuild exit $status)"
  exit "$status"
fi
log "the macOS UI tests passed; the result bundle is at $RESULT_BUNDLE"
exit 0
