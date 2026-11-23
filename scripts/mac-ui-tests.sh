#!/usr/bin/env bash
# Run the Clutch macOS UI tests and leave the result bundle where CI can
# publish it.
#
# Exit codes: 0 the tests passed, 10 the runner has no window server to host
# them, anything else they failed or they verified nothing at all.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"
RESULT_BUNDLE="${CLUTCH_MAC_UI_RESULT_BUNDLE:-$REPO_ROOT/mac-ui.xcresult}"
LOG_FILE="${CLUTCH_MAC_UI_LOG:-${TMPDIR:-/tmp}/clutch-mac-ui-tests.log}"
# The derived data holds the test runner itself, and a runner on a
# removable volume makes macOS ask the owner for permission to read it
# before the run can start.  A machine whose checkout is on such a volume
# can point the build output at the local disk instead.
DERIVED_DATA="${CLUTCH_MAC_UI_DERIVED_DATA:-}"

log() { printf 'mac-ui-tests: %s\n' "$1" >&2; }

# Xcode hands environment variables prefixed with TEST_RUNNER_ to the test
# runner process, so the snapshot flags travel that way.  Exporting them into
# the shell alone leaves the runner without them, and the run compares
# against a baseline that was never recorded.
export TEST_RUNNER_CLUTCH_RECORD_SNAPSHOTS="${CLUTCH_RECORD_SNAPSHOTS:-}"
export TEST_RUNNER_CLUTCH_SNAPSHOT_DIR="${CLUTCH_SNAPSHOT_DIR:-}"
export CLUTCH_RECORD_SNAPSHOTS="${CLUTCH_RECORD_SNAPSHOTS:-}"
export CLUTCH_SNAPSHOT_DIR="${CLUTCH_SNAPSHOT_DIR:-}"

# The test runner does not inherit the environment of this shell, so the
# ask to record travels in a file at the root of the checkout.  The file
# goes away when the run is over, so a later run compares instead.
RECORD_FLAG="$REPO_ROOT/.clutch-record-snapshots"
if [ "${CLUTCH_RECORD_SNAPSHOTS:-}" = "1" ]; then
  printf 'record\n' > "$RECORD_FLAG"
  # The runner is sandboxed and may not be able to read the checkout, so
  # the flag goes to the scratch directory as well.
  printf 'record\n' > "${TMPDIR:-/tmp}/.clutch-record-snapshots"
  trap 'rm -f "$RECORD_FLAG" "${TMPDIR:-/tmp}/.clutch-record-snapshots"' EXIT
fi

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
# The hosted runner has no Mac Development certificate for the team, and the
# Mac targets ask for one by team id.  A UI test has to be signed to run at
# all, so the run signs ad hoc instead:  an ad-hoc signature is enough for a
# test bundle and its host on the machine that runs it.
DERIVED_ARGS=()
if [ -n "$DERIVED_DATA" ]; then
  DERIVED_ARGS=(-derivedDataPath "$DERIVED_DATA")
fi

xcodebuild -project Clutch.xcodeproj \
  -scheme "Clutch macOS" \
  -destination "platform=macOS" \
  -resultBundlePath "$RESULT_BUNDLE" \
  "${DERIVED_ARGS[@]}" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  test 2>&1 | tee "$LOG_FILE"
status=${PIPESTATUS[0]}

if [ "$status" -ne 0 ]; then
  # A runner with no window server cannot host a UI test at all.  That is a
  # property of the machine and not a defect in the surface, so it is a skip
  # and the build says so out loud.
  if grep -qiE "no window server|could not connect to the window server|WindowServer" "$LOG_FILE"; then
    log "skipped: this runner has no window server to host the macOS UI tests"
    exit 10
  fi
  log "the macOS UI tests failed (xcodebuild exit $status)"
  exit "$status"
fi

# A run in which every test skipped has verified nothing, and a green build
# that checked nothing is the failure this step exists to prevent.  The count
# comes from the result bundle, so it is the number the test runner reported.
summary="$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null || true)"
passed="$(printf '%s' "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("passedTests", 0))' 2>/dev/null || echo 0)"
skipped="$(printf '%s' "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("skippedTests", 0))' 2>/dev/null || echo 0)"
if [ "${passed:-0}" -eq 0 ] && [ "${skipped:-0}" -gt 0 ]; then
  # A skip is either a fact about this machine or a gap in the repository,
  # and the two are not the same.  A machine that cannot show the window, or
  # cannot bring the app to the front of it, is a runner that cannot host
  # the test, and the workflow skips it.  A state with no baseline is a gap
  # in the checkout, and that fails the build until the baseline is
  # recorded and committed.
  if grep -q "could not see the Mac app" "$LOG_FILE"; then
    log "skipped: this runner cannot host the macOS UI tests"
    exit 10
  fi
  log "the macOS UI tests verified nothing: $skipped skipped and 0 passed"
  exit 1
fi

log "the macOS UI tests passed; the result bundle is at $RESULT_BUNDLE"
exit 0
