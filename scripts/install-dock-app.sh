#!/usr/bin/env bash
# Build ~/Applications/Clutch.app (WKWebView shell around the clutch web UI,
# Dock running-dot) and pin it to the Dock.  Icon is a full-bleed 1:1 square,
# sharp 90° corners.  Display name "Clutch"; bundle id codes.clutch.macos;
# version 1.0 (1).  The app is ad-hoc signed.  Sources and assets come from
# the runtime clone ($CLUTCH_RUNTIME_ROOT, default ~/apps/clutch-runtime), so
# this script copies nothing into it.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LIVE="${CLUTCH_RUNTIME_ROOT:-${HOME}/apps/clutch-runtime}"
APP="${HOME}/Applications/Clutch.app"
PNG="${LIVE}/assets/clutch-icon-1024.png"
SWIFT="${LIVE}/src/web/dock-app/ClutchWindow.swift"

if [[ ! -f "$PNG" ]]; then
  echo "missing ${PNG}" >&2
  exit 1
fi
if [[ ! -f "$SWIFT" ]]; then
  echo "missing ${SWIFT}" >&2
  exit 1
fi

# Terminate existing running instance so new build takes effect immediately
pkill -f 'Clutch.app/Contents/MacOS/Clutch' 2>/dev/null || true

mkdir -p "${HOME}/Applications"
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
trap 'rm -rf "$TMP"' EXIT
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
</dict>
</plist>
PLIST
echo -n "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true

# Put the pinned `clutch` CLI on PATH as a real wrapper file, not a symlink:
# scripts/clutch.sh resolves its lib relative to itself, and a link would
# resolve it under ~/.local instead.  ~/.local/bin/dsh (vanilla dsh) is left
# alone.
CLI_SH="${LIVE}/scripts/clutch.sh"
if [[ -x "$CLI_SH" ]]; then
  mkdir -p "$HOME/.local/bin"
  rm -f "$HOME/.local/bin/clutch"
  printf '#!/usr/bin/env bash\nexport CLUTCH_RUNTIME_ROOT="%s"\nexec "%s" "$@"\n' "$LIVE" "$CLI_SH" \
    > "$HOME/.local/bin/clutch"
  chmod 755 "$HOME/.local/bin/clutch"
  echo "wrote $HOME/.local/bin/clutch -> $CLI_SH"
else
  echo "clutch CLI not found at $CLI_SH — 'clutch' may not resolve on PATH" >&2
fi

if command -v dockutil >/dev/null 2>&1; then
  if ! dockutil --list | awk -F'\t' '{print $1}' | grep -qx "Clutch"; then
    if dockutil --list | awk -F'\t' '{print $1}' | grep -qx "DeepSeek"; then
      dockutil --add "$APP" --after "DeepSeek" --no-restart
    else
      dockutil --add "$APP" --no-restart
    fi
    killall Dock 2>/dev/null || true
  fi
else
  echo "dockutil not installed; app is at $APP — drag it to the Dock" >&2
fi

echo "installed $APP"
echo "WKWebView shell; Dock running-dot; second click focuses the same window"
open -a "$APP"
