#!/usr/bin/env bash
# Build Clutch.app (WKWebView shell).  Used by install-dock-app.sh locally and
# by GitHub-hosted macOS runners.  Never prints secret values.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LIVE="${CLUTCH_RUNTIME_ROOT:-${HOME}/apps/clutch-runtime}"
APP="${CLUTCH_MAC_APP_OUT:-${HOME}/Applications/Clutch.app}"
PNG="${LIVE}/assets/clutch-icon-1024.png"
SWIFT="${LIVE}/src/web/dock-app/ClutchWindow.swift"
SIGN_MODE="${CLUTCH_MAC_SIGN:-adhoc}"
MANIFEST_OUT="${CLUTCH_MAC_MANIFEST_OUT:-}"

if [[ ! -f "$PNG" ]]; then
  echo "missing ${PNG}" >&2
  exit 1
fi
if [[ ! -f "$SWIFT" ]]; then
  echo "missing ${SWIFT}" >&2
  exit 1
fi

if [[ "${CLUTCH_MAC_KILL_RUNNING:-1}" == "1" ]]; then
  pkill -f 'Clutch.app/Contents/MacOS/Clutch' 2>/dev/null || true
fi

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -O \
  -target arm64-apple-macos14 \
  -sdk "$SDK" \
  -framework Cocoa -framework WebKit \
  -o "$APP/Contents/MacOS/Clutch" \
  "$SWIFT"
chmod 755 "$APP/Contents/MacOS/Clutch"

TMP="$(mktemp -d)"
# The notary API key and the notarization zip are written to $RUNNER_TEMP, not
# to $TMP, so declare them before the trap and remove them on every exit path
# (notarytool error, SIGTERM, errexit) or the private key outlives the build.
KEY_PATH="${RUNNER_TEMP:-/tmp}/clutch-notary-key.p8"
ZIP="${RUNNER_TEMP:-/tmp}/Clutch-notarize.zip"
trap 'rm -rf "$TMP"; rm -f "$KEY_PATH" "$ZIP"' EXIT
mkdir -p "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$PNG" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$PNG" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Clutch</string>
  <key>CFBundleExecutable</key><string>Clutch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>codes.clutch.macos</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Clutch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>codes.clutch.macos</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>clutch</string>
        <string>minimax</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST
echo -n "APPL????" > "$APP/Contents/PkgInfo"

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
  python3 - "$MANIFEST_OUT" "$COMMIT" "$SIGNED_AS" <<'PY'
import json, sys
path, commit, signed = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"schemaVersion": 1, "commit": commit, "signedAs": signed, "bundleId": "codes.clutch.macos"}, open(path, "w"), indent=2)
PY
fi

echo "built ${APP} (${SIGNED_AS})"
