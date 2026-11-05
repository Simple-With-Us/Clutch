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
  PATH="$FAKE_BIN:$PATH" bash -c '
    set -uo pipefail
    source "'"$HELPER"'"
    clutch_ios_simulator_device "${1:-}"
  ' _ "$1"
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

# 6.  The unit-test script skips, with exit 10, on a machine with no runtime.
#     A skip is not a failure:  the caller reports it and the job still
#     publishes what it has.
status=0
PATH="$FAKE_BIN:$PATH" FAKE_DEVICES="" FAKE_DOWNLOAD=fail \
  bash "$UNIT_SCRIPT" >/dev/null 2>&1 || status=$?
check "the unit-test script skips without a runtime" "10" "$status"

if [ "$FAILURES" -eq 0 ]; then
  echo "ios-simulator: every check passed"
  exit 0
fi
echo "ios-simulator: $FAILURES check(s) failed" >&2
exit 1
