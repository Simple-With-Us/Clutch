#!/usr/bin/env bash
# Build Clutch.app from the native `Clutch macOS` Xcode target.
#
# This used to compile a single hand-rolled WKWebView shell (src/web/dock-app/
# ClutchWindow.swift) with swiftc and write an Info.plist by hand.  That shell
# was replaced by the real native target in #123, but this script kept building
# it, so every "Mac release" shipped the deprecated app under the native app's
# own bundle identifier.  C-86 repoints the release path at the target that
# actually contains the product.
#
# Contract with the rest of the fleet (scripts/fetch-ci-mac-app.sh, the publish
# job, scripts/install-dock-app.sh, scripts/auto-update-mac.sh) is unchanged:
# the product is $APP/Clutch.app and, when CLUTCH_MAC_MANIFEST_OUT is set, a
# manifest with schemaVersion / commit / signedAs / bundleId.
#
# bundleId is now READ BACK from the built Info.plist rather than written here,
# so the manifest cannot claim an identity the binary does not carry.
#
# Local fallback, not the primary route:  scripts/fetch-ci-mac-app.sh installs the
# CI-built app first, and this script only runs when no CI build exists for the
# commit.  A local build needs a full Xcode (see the preflight below).
#
# Seams, all optional:
#   CLUTCH_MAC_REGENERATE_PROJECT=1  run `xcodegen generate` first so the build
#                                    comes from ios/project.yml, not the committed
#                                    pbxproj (the release workflow sets this)
#   CLUTCH_MAC_DERIVED_DATA          DerivedData directory; default is stable, so
#                                    dependency and incremental state survive
#   CLUTCH_MAC_BUILD_LOCK_WAIT       seconds to wait for another build on the same
#                                    DerivedData before giving up (default 3600)
#   CLUTCH_MAC_BUILD_NUMBER          CFBundleVersion; default is the commit's
#                                    America/Chicago merge timestamp (YYYYMMDDHHMM)
#   CLUTCH_MAC_MARKETING_VERSION     CFBundleShortVersionString; default 0.1.0
#
# Never prints secret values.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LIVE="${CLUTCH_RUNTIME_ROOT:-${HOME}/apps/clutch-runtime}"
APP="${CLUTCH_MAC_APP_OUT:-${HOME}/Applications/Clutch.app}"
IOS_DIR="${CLUTCH_MAC_IOS_DIR:-${LIVE}/ios}"
SCHEME="${CLUTCH_MAC_SCHEME:-Clutch macOS}"
CONFIGURATION="${CLUTCH_MAC_CONFIGURATION:-Release}"
SIGN_MODE="${CLUTCH_MAC_SIGN:-adhoc}"
MANIFEST_OUT="${CLUTCH_MAC_MANIFEST_OUT:-}"
PROJECT="${CLUTCH_MAC_XCODEPROJ:-${IOS_DIR}/Clutch.xcodeproj}"

if [[ ! -d "$IOS_DIR" ]]; then
  echo "missing ${IOS_DIR}" >&2
  exit 1
fi

# A local build needs a full Xcode.  With only the Command Line Tools selected,
# `xcodebuild` is a stub that dies with an opaque "requires Xcode" error partway
# through an update, so say what is wrong and what to do before touching
# anything.  The CI-built app is the primary route and needs none of this.
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "a local Mac build needs a full Xcode install, and xcodebuild is not usable here" >&2
  echo "install Xcode and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  echo "or wait for the CI-built app (scripts/fetch-ci-mac-app.sh installs it when it exists)" >&2
  exit 1
fi

# ios/Clutch.xcodeproj is generated from ios/project.yml by XcodeGen.  The
# committed copy is fine for a local rebuild, but the release path must ship what
# project.yml says, the way ci.yml and build-ios.sh do: a Swift file added or a
# setting changed in project.yml without a regenerated pbxproj would otherwise
# silently miss the shipped app.  A clone with no project at all gets one too,
# rather than failing with a bare "cannot find scheme".
if [[ "${CLUTCH_MAC_REGENERATE_PROJECT:-0}" == "1" || ! -d "$PROJECT" ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is needed to generate ${PROJECT} and is not installed" >&2
    echo "install it with: bash ${LIVE}/scripts/ios-install-xcodegen.sh" >&2
    exit 1
  fi
  echo "generating ${PROJECT} from ios/project.yml"
  (cd "$IOS_DIR" && xcodegen generate)
fi

# The notary API key and the notarization zip are written to $RUNNER_TEMP, so
# declare them before the trap and remove them on every exit path (notarytool
# error, SIGTERM, errexit) or the private key outlives the build.
KEY_PATH="${RUNNER_TEMP:-/tmp}/clutch-notary-key.p8"
ZIP="${RUNNER_TEMP:-/tmp}/Clutch-notarize.zip"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/clutch-build-lock.sh
. "$HERE/lib/clutch-build-lock.sh"
trap 'rm -f "$KEY_PATH" "$ZIP"; clutch_build_lock_release' EXIT

# DerivedData lives OUTSIDE anything the exit trap removes.  A throwaway one
# re-resolves CometChatUIKitSwift and recompiles the whole app on every install,
# which is most of the build time on the Mac that rebuilds on each update.
DD="${CLUTCH_MAC_DERIVED_DATA:-${CLUTCH_HOME:-${HOME}/.clutch}/derived-data/mac}"
mkdir -p "$DD"
# One build at a time against it.  The auto-updater's local rebuild, update:mac
# and an operator running clutch-install-dock can overlap, and a shared
# DerivedData plus the product removal below would let one run delete or
# half-overwrite what another is about to copy into the app.  The lock covers
# the build and the swap into $APP and is released on every exit path.
clutch_build_lock_acquire "$DD/.build.lock" "${CLUTCH_MAC_BUILD_LOCK_WAIT:-3600}"

# Version stamps.  Explicit CLUTCH_MAC_* values always win.  Otherwise every
# Clutch platform uses marketing version 0.1.0 and the build number names the
# commit's merge minute in America/Chicago.  The workflow supplies the same
# values explicitly; this fallback keeps local builds honest too.
BUILD_COMMIT="${CLUTCH_MAC_BUILD_COMMIT:-HEAD}"
COMMIT_EPOCH="$(git -C "$LIVE" show -s --format=%ct "$BUILD_COMMIT" 2>/dev/null || true)"
DEFAULT_BUILD_NUMBER=""
if [[ "$COMMIT_EPOCH" =~ ^[0-9]+$ ]]; then
  if date -r "$COMMIT_EPOCH" '+%Y%m%d%H%M' >/dev/null 2>&1; then
    DEFAULT_BUILD_NUMBER="$(TZ=America/Chicago date -r "$COMMIT_EPOCH" '+%Y%m%d%H%M')"
  else
    DEFAULT_BUILD_NUMBER="$(TZ=America/Chicago date -d "@$COMMIT_EPOCH" '+%Y%m%d%H%M')"
  fi
fi
BUILD_NUMBER="${CLUTCH_MAC_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"
MARKETING_VERSION_VALUE="${CLUTCH_MAC_MARKETING_VERSION:-0.1.0}"
if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[0-9]{12}$ ]]; then
  echo "CLUTCH_MAC_BUILD_NUMBER must be a 12-digit YYYYMMDDHHMM value" >&2
  exit 1
fi

# Build unsigned and sign below.  The target declares CODE_SIGN_STYLE
# Automatic with a development team, which cannot resolve on a runner with no
# signing identity; signing here keeps one code path for both CI modes and
# keeps the notary step exactly where it already was.
XCODE_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DD"
  -destination "platform=macOS,arch=arm64"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
)
if [[ -n "$BUILD_NUMBER" ]]; then
  XCODE_ARGS+=("CURRENT_PROJECT_VERSION=${BUILD_NUMBER}")
fi
if [[ -n "$MARKETING_VERSION_VALUE" ]]; then
  XCODE_ARGS+=("MARKETING_VERSION=${MARKETING_VERSION_VALUE}")
fi

BUILT="$DD/Build/Products/${CONFIGURATION}/Clutch.app"
# DerivedData persists now, so remove the previous product first: a build that
# fails or does nothing must never leave an old Clutch.app that passes the check
# below and gets shipped as this commit.
rm -rf "$BUILT"

echo "==> building scheme ${SCHEME} (${CONFIGURATION})"
xcodebuild "${XCODE_ARGS[@]}" build

if [[ ! -d "$BUILT" ]]; then
  echo "xcodebuild produced no ${BUILT}" >&2
  exit 1
fi

# Stop the running app only now that there is a built replacement.  Killing it
# before the build meant a failed build left the Mac with no app, and the
# auto-updater does not retry a commit it has already attempted.
if [[ "${CLUTCH_MAC_KILL_RUNNING:-1}" == "1" ]]; then
  pkill -f 'Clutch.app/Contents/MacOS/Clutch' 2>/dev/null || true
fi

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
ditto "$BUILT" "$APP"

case "$SIGN_MODE" in
  adhoc)
    codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
    SIGNED_AS="adhoc"
    ;;
  developer-id)
    : "${CLUTCH_MAC_CODESIGN_IDENTITY:?CLUTCH_MAC_CODESIGN_IDENTITY required for developer-id signing}"
    codesign --force --deep --options runtime -s "$CLUTCH_MAC_CODESIGN_IDENTITY" "$APP"
    SIGNED_AS="developer-id"
    if [[ -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" && -n "${APPLE_API_KEY_P8_BASE64:-}" ]]; then
      case "$APPLE_API_KEY_P8_BASE64" in
        *BEGIN*) printf '%s\n' "$APPLE_API_KEY_P8_BASE64" > "$KEY_PATH" ;;
        *) printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$KEY_PATH" ;;
      esac
      chmod 600 "$KEY_PATH"
      # Guard the decode the same way ios-appstore-gm-prepare.sh does, so a
      # truncated or wrong base64 export fails here instead of surfacing as
      # notarytool's opaque "no AuthKey file readable".
      if ! grep -q "BEGIN " "$KEY_PATH"; then
        echo "notary key did not decode to a PEM private key" >&2
        exit 1
      fi
      ditto -c -k --keepParent "$APP" "$ZIP"
      xcrun notarytool submit "$ZIP" --wait --key "$KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID"
      xcrun stapler staple "$APP" || true
      SIGNED_AS="developer-id-notarized"
    fi
    ;;
  skip)
    SIGNED_AS="unsigned"
    ;;
  *)
    echo "unknown CLUTCH_MAC_SIGN=${SIGN_MODE}" >&2
    exit 1
    ;;
esac

if [[ -n "$MANIFEST_OUT" ]]; then
  COMMIT="${CLUTCH_MAC_BUILD_COMMIT:-unknown}"
  # Read the identity off the product instead of repeating it here.  Two builds
  # that both claim codes.clutch.macos is the exact bug C-86 exists to kill, so
  # the manifest must not be able to assert one the bundle does not carry.
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -z "$BUNDLE_ID" ]]; then
    echo "built app has no CFBundleIdentifier; refusing to write a manifest" >&2
    exit 1
  fi
  BUILT_MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  BUILT_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
  python3 - "$MANIFEST_OUT" "$COMMIT" "$SIGNED_AS" "$BUNDLE_ID" "$BUILT_MARKETING_VERSION" "$BUILT_BUILD_NUMBER" <<'PY'
import json, sys
path, commit, signed, bundle_id, marketing_version, build_number = sys.argv[1:]
json.dump({
    "schemaVersion": 1,
    "commit": commit,
    "signedAs": signed,
    "bundleId": bundle_id,
    "marketingVersion": marketing_version,
    "buildNumber": build_number,
}, open(path, "w"), indent=2)
PY
fi

echo "built ${APP} (${SIGNED_AS})"
