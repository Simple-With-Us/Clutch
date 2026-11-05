#!/usr/bin/env bash
# Shared iOS simulator resolution for the Clutch test scripts.
#
# The hosted runner does not always have an iOS simulator runtime installed,
# so a caller asks for a device first:
#
#   1. use an available iPhone simulator, if the image has one;
#   2. otherwise download the iOS platform and create a device;
#   3. otherwise report that no runtime is available, and the caller skips.
#
# Source this file, then call clutch_ios_simulator_device.  It prints the
# device UDID on stdout and returns 1 when the machine has no runtime, so a
# caller can skip instead of failing.  Nothing here writes outside the
# temporary directory the caller owns.
#
# The parsing is plain awk, so it works the same on macOS's BSD tools and on
# GNU ones.

# The log file the platform download writes to.
CLUTCH_IOS_DOWNLOAD_LOG="${CLUTCH_IOS_DOWNLOAD_LOG:-${RUNNER_TEMP:-/tmp}/clutch-ios-download.log}"

# The device this helper creates when it has to download a runtime.  The
# device lookup matches it by name, so a later resolution reuses it instead
# of downloading the platform a second time.
CLUTCH_IOS_CREATED_DEVICE="${CLUTCH_IOS_CREATED_DEVICE:-Clutch Test iPhone}"

# The iOS simulator devices this machine can run, as "UDID<TAB>name" lines.
clutch_ios_available_devices() {
  # "iPhone 16 Pro (UDID) (Shutdown)" lines, reduced to "UDID<TAB>name".
  # The UDID is what xcodebuild wants: a name is ambiguous when two runtimes
  # offer a device with the same name.  The name is every word before the
  # parenthesised identifier, so a caller can ask for "iPhone 16 Pro" and
  # have that device picked rather than the first one it sees.
  # The device this helper created is matched too, so a second lookup finds
  # it instead of downloading the platform again.
  xcrun simctl list devices available 2>/dev/null \
    | awk -v created="$CLUTCH_IOS_CREATED_DEVICE" '
        $0 ~ ("^[[:space:]]+(iPhone|" created ")") {
          name = ""
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^\(/) break
            name = (name == "" ? $i : name " " $i)
          }
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^\(/) { gsub(/[()]/, "", $i); print $i "\t" name; break }
          }
        }
      ' \
    | head -20
}

# The device to run on, or nothing when this machine has no runtime.
#
# The argument is the device name to prefer, empty for the newest runtime.
# When the image has no runtime, the iOS platform is downloaded and a device
# is created for it, because a missing runtime is not a broken test.
clutch_ios_simulator_device() {
  local want="${1:-}"
  local devices
  devices="$(clutch_ios_available_devices)"
  if [ -n "$devices" ]; then
    if [ -n "$want" ]; then
      local found
      found="$(printf '%s\n' "$devices" | awk -F '\t' -v name="$want" '$2 == name { print $1; exit }')"
      if [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 0
      fi
      # The named device is not on this image, so a new one is made below.
    else
      # The newest runtime first: simctl lists them newest first.
      printf '%s\n' "$devices" | head -1 | cut -f1
      return 0
    fi
  fi
  clutch_ios_download_runtime
}

# Download the iOS platform and create a device for it, printing its UDID.
clutch_ios_download_runtime() {
  printf 'ios-simulator: no iOS simulator runtime on this image; downloading the iOS platform\n' >&2
  if ! xcodebuild -downloadPlatform iOS >>"$CLUTCH_IOS_DOWNLOAD_LOG" 2>&1; then
    printf 'ios-simulator: the platform download failed (see %s)\n' "$CLUTCH_IOS_DOWNLOAD_LOG" >&2
    return 1
  fi
  # A downloaded runtime needs a device of its own.  `simctl list runtimes`
  # prints "iOS 18.2 (18.2 - 22C150) - com.apple.CoreSimulator.SimRuntime.iOS-18-2",
  # and `simctl create` wants that last identifier, not the version label.
  local runtime
  runtime="$(xcrun simctl list runtimes 2>/dev/null | awk '/iOS/ && /com.apple.CoreSimulator.SimRuntime/ { print $NF; exit }')"
  [ -n "$runtime" ] || return 1
  local identifier
  identifier="$(xcrun simctl list devicetypes 2>/dev/null | awk -F '[()]' '/iPhone 16 Pro/ { print $2; exit }')"
  [ -n "$identifier" ] || identifier="iPhone 16 Pro"
  # The created device is named "Clutch Test iPhone", and its identifier is
  # captured here and used directly.  A failed create leaves no UDID, and the
  # helper's contract is that it returns 1 when the machine has no runtime,
  # so an empty result is a failure rather than a device with no name.
  local created
  created="$(xcrun simctl create "$CLUTCH_IOS_CREATED_DEVICE" "$identifier" "$runtime")" || return 1
  created="$(printf '%s' "$created" | tr -d '[:space:]')"
  [ -n "$created" ] || return 1
  printf '%s\n' "$created"
}
