#!/usr/bin/env bash
# test-ios-simulator.sh - Offline tests for the shared iOS simulator helper.
#
# The helper in scripts/lib/ios-simulator.sh decides whether an iOS test run
# happens at all:  it picks a simulator, or downloads the platform and makes
# a device, or reports that the machine has no runtime so the caller skips.
# A wrong decision there is silent:  the test suite would stop running
# without anything failing, which is how the unit-test bundle went unrun for
# months.
#
# Everything runs offline against a FAKE_BIN:  a fake `xcrun` that lists the
# devices the test wants, and a fake `xcodebuild` that either downloads a
# platform or refuses to.  Nothing here touches Xcode, a simulator or the
# network.
#
# Usage:
#   bash scripts/ios-fleet/test-ios-simulator.sh
#
# Exits 0 when every check passed, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HELPER="$REPO/scripts/lib/ios-simulator.sh"
UNIT_SCRIPT="$REPO/scripts/ios-unit-tests.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ios-simulator-test.XXXXXX")"
FAKE_BIN="${WORK}/bin"
mkdir -p "$FAKE_BIN"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAILURES=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $name"
  else
    echo "FAIL - $name: expected [$expected], got [$actual]" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# A fake xcrun:  the device list comes from FAKE_DEVICES, and a created
# device gets a fixed identifier so the test can assert on it.
cat >"${FAKE_BIN}/xcrun" <<'FAKE'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "simctl list")
    if [ "${3:-}" = "devices" ]; then
      printf '%s' "${FAKE_DEVICES:-}"
    elif [ "${3:-}" = "runtimes" ]; then
      echo "iOS 18.2 (18.2 - 22C150) - com.apple.CoreSimulator.SimRuntime.iOS-18-2"
    elif [ "${3:-}" = "devicetypes" ]; then
      echo "iPhone 16 Pro (com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro)"
    fi
    ;;
  "simctl create")
    if [ "${FAKE_CREATE:-ok}" = "fail" ]; then
      echo "create refused" >&2
      exit 1
    fi
    echo "CREATED-DEVICE-UDID"
    ;;
esac
FAKE
chmod +x "${FAKE_BIN}/xcrun"

# A fake xcodebuild:  the platform download succeeds or fails on demand.
cat >"${FAKE_BIN}/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "-downloadPlatform" ]; then
  if [ "${FAKE_DOWNLOAD:-fail}" = "ok" ]; then
    echo "downloaded"
    exit 0
  fi
  echo "download refused" >&2
  exit 1
fi
echo "fake xcodebuild: refusing $*" >&2
exit 1
FAKE
chmod +x "${FAKE_BIN}/xcodebuild"

# A fake xcodegen:  the project is never needed, because these tests stop
# before xcodebuild runs.
cat >"${FAKE_BIN}/xcodegen" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "${FAKE_BIN}/xcodegen"

pick_device() {
  # The helper path is handed over as $0 rather than pasted into the program
  # text, so a checkout path holding shell metacharacters stays an argument.
  # The inner shell sets no pipefail on purpose:  the helper has to keep its
  # own contract whatever the caller's shell options are, and pipefail would
  # hide a pipeline that swallows a failure.
  PATH="$FAKE_BIN:$PATH" bash -c '
    set -u
    source "${0:?}"
    clutch_ios_simulator_device "${1:-}"
  ' "$HELPER" "$1"
}

# 1.  A machine with two simulators picks the newest runtime's device.
#     simctl lists the newest runtime first, so the first line is the one.
DEVICES='    iPhone 17 (UDID-NEW) (Shutdown)
    iPhone 16 Pro (UDID-OLD) (Shutdown)
'
actual="$(FAKE_DEVICES="$DEVICES" pick_device "")"
check "the newest runtime's device is picked" "UDID-NEW" "$actual"

# 2.  A named device wins over the newest one.
actual="$(FAKE_DEVICES="$DEVICES" pick_device "iPhone 16 Pro")"
check "the named device is picked" "UDID-OLD" "$actual"

# 3.  A name that is not on the image falls back to a downloaded platform.
actual="$(FAKE_DEVICES="$DEVICES" FAKE_DOWNLOAD=ok pick_device "iPhone 99")"
check "a missing name falls back to a created device" "CREATED-DEVICE-UDID" "$actual"

# 4.  No runtime and a refused download means no device.
actual="$(FAKE_DEVICES="" FAKE_DOWNLOAD=fail pick_device "")"
check "a refused download means no device" "" "$actual"

# 5.  No runtime and a good download means a created device.
actual="$(FAKE_DEVICES="" FAKE_DOWNLOAD=ok pick_device "")"
check "a good download creates a device" "CREATED-DEVICE-UDID" "$actual"

# 6.  The unit-test script exits 10, its no-runtime code, on a machine with
#     no runtime.  The workflow turns that into a failed step, so a run that
#     verified nothing never reads green.
status=0
PATH="$FAKE_BIN:$PATH" FAKE_DEVICES="" FAKE_DOWNLOAD=fail \
  bash "$UNIT_SCRIPT" >/dev/null 2>&1 || status=$?
check "the unit-test script reports no runtime" "10" "$status"

# 7.  A failed create means no device, and the helper says so.  The status
#     matters as much as the output:  a helper that returns success with no
#     UDID claims a device it never made.
status=0
actual="$(FAKE_DEVICES="" FAKE_DOWNLOAD=ok FAKE_CREATE=fail pick_device "")" || status=$?
check "a failed create means no device" "" "$actual"
check "a failed create reports failure" "1" "$status"

# 8.  A device this helper created is found by a later lookup, so CI does not
#     download the platform and create a second device for the unit tests.
CREATED_DEVICES='    Clutch Test iPhone (UDID-CREATED) (Shutdown)
'
actual="$(FAKE_DEVICES="$CREATED_DEVICES" pick_device "")"
check "a device the helper created is found again" "UDID-CREATED" "$actual"

if [ "$FAILURES" -eq 0 ]; then
  echo "ios-simulator: every check passed"
  exit 0
fi
echo "ios-simulator: $FAILURES check(s) failed" >&2
exit 1
