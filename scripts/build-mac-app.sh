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
if [[ ! -d "$PROJECT" ]]; then
  # ios/Clutch.xcodeproj is generated from ios/project.yml by XcodeGen.  CI
  # carries the generated project, but a clone that does not gets one here
  # rather than failing with a bare "cannot find scheme".
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "missing ${PROJECT} and xcodegen is not installed" >&2
    echo "install it with: bash ${LIVE}/scripts/ios-install-xcodegen.sh" >&2
    exit 1
  fi
  echo "generating ${PROJECT} from ios/project.yml"
  (cd "$IOS_DIR" && xcodegen generate)
fi

if [[ "${CLUTCH_MAC_KILL_RUNNING:-1}" == "1" ]]; then
  pkill -f 'Clutch.app/Contents/MacOS/Clutch' 2>/dev/null || true
fi

TMP="$(mktemp -d)"
# The notary API key and the notarization zip are written to $RUNNER_TEMP, not
# to $TMP, so declare them before the trap and remove them on every exit path
# (notarytool error, SIGTERM, errexit) or the private key outlives the build.
KEY_PATH="${RUNNER_TEMP:-/tmp}/clutch-notary-key.p8"
ZIP="${RUNNER_TEMP:-/tmp}/Clutch-notarize.zip"
trap 'rm -rf "$TMP"; rm -f "$KEY_PATH" "$ZIP"' EXIT

DD="$TMP/dd"
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
[[ -n "${CLUTCH_MAC_BUILD_NUMBER:-}" ]] && XCODE_ARGS+=("CURRENT_PROJECT_VERSION=${CLUTCH_MAC_BUILD_NUMBER}")
[[ -n "${CLUTCH_MAC_MARKETING_VERSION:-}" ]] && XCODE_ARGS+=("MARKETING_VERSION=${CLUTCH_MAC_MARKETING_VERSION}")

echo "==> building scheme ${SCHEME} (${CONFIGURATION})"
xcodebuild "${XCODE_ARGS[@]}" build

BUILT="$DD/Build/Products/${CONFIGURATION}/Clutch.app"
if [[ ! -d "$BUILT" ]]; then
  echo "xcodebuild produced no ${BUILT}" >&2
  exit 1
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
  python3 - "$MANIFEST_OUT" "$COMMIT" "$SIGNED_AS" "$BUNDLE_ID" <<'PY'
import json, sys
path, commit, signed, bundle_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
json.dump({"schemaVersion": 1, "commit": commit, "signedAs": signed, "bundleId": bundle_id}, open(path, "w"), indent=2)
PY
fi

echo "built ${APP} (${SIGNED_AS})"