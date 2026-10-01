#!/usr/bin/env bash
# Build ~/Applications/Harness.app (WKWebView shell around DeepSeek Harness web,
# Dock running-dot) and pin it to the Dock.  Icon is a full-bleed 1:1 square,
# sharp 90° corners.  Display name "Harness"; bundle id history (newest first):
#   2026-09-23 — com.simplewithus.harness.mac (consumer rebrand; ownership
#                transferred to simplewithus.com).  Dock pin and saved frames
#                do NOT survive the rename — re-pin after install.
#   2026-09-19 — services.jays.harness (interim owner-personal id).
#   earlier    — com.jays.dsh-harness-web.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIVE="${CLUTCH_RUNTIME_ROOT:-${HOME}/apps/clutch-runtime}"
APP="${HOME}/Applications/Harness.app"
PNG="${ROOT}/assets/harness-icon-1024.png"
[[ -f "$PNG" ]] || PNG="${LIVE}/assets/harness-icon-1024.png"
SWIFT="${ROOT}/src/web/dock-app/HarnessWindow.swift"
[[ -f "$SWIFT" ]] || SWIFT="${ROOT}/HarnessWindow.swift"
[[ -f "$SWIFT" ]] || SWIFT="${LIVE}/HarnessWindow.swift"

if [[ ! -f "$PNG" ]]; then
  echo "missing harness-icon-1024.png" >&2
  exit 1
fi
if [[ ! -f "$SWIFT" ]]; then
  echo "missing HarnessWindow.swift" >&2
  exit 1
fi

# Terminate existing running instance so new build takes effect immediately
pkill -f DeepSeekHarness 2>/dev/null || true

mkdir -p "${HOME}/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -O \
  -target arm64-apple-macos14 \
  -sdk "$SDK" \
  -framework Cocoa -framework WebKit \
  -o "$APP/Contents/MacOS/DeepSeekHarness" \
  "$SWIFT"
chmod 755 "$APP/Contents/MacOS/DeepSeekHarness"

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
  <key>CFBundleDisplayName</key><string>Harness</string>
  <key>CFBundleExecutable</key><string>DeepSeekHarness</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.simplewithus.harness.mac</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Harness</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
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

# LIVE is a symlink to this repo on the owner's Mac.  Copying onto itself
# is a no-op at best and a loop at worst.
live_real="$(cd "$LIVE" 2>/dev/null && pwd -P || true)"
root_real="$(cd "$ROOT" && pwd -P)"
if [[ -n "$live_real" && "$live_real" != "$root_real" ]]; then
  mkdir -p "${LIVE}/assets" "${LIVE}/scripts/lib"
  cp "$SWIFT" "${LIVE}/HarnessWindow.swift"
  cp "${ROOT}/scripts/lib/clutch-env.sh" "${LIVE}/scripts/lib/clutch-env.sh"
  cp "${ROOT}/scripts/ensure-web.sh" "${LIVE}/scripts/ensure-web.sh"
  cp "${ROOT}/scripts/open-clutch.sh" "${LIVE}/scripts/open-clutch.sh"
  cp "${ROOT}/scripts/clutch.sh" "${LIVE}/scripts/clutch.sh"
  cp "$PNG" "${LIVE}/assets/harness-icon-1024.png"
  # HarnessWindow.swift inlines the MiniMax mark for the sidebar chip and the
  # model-picker provider group, so it has to land in the live assets dir too.
  MARK="${ROOT}/assets/minimax-mark.svg"
  [[ -f "$MARK" ]] || MARK="${LIVE}/assets/minimax-mark.svg"
  [[ -f "$MARK" ]] && cp "$MARK" "${LIVE}/assets/minimax-mark.svg"
  chmod 755 "${LIVE}/scripts/ensure-web.sh" "${LIVE}/scripts/open-clutch.sh" \
            "${LIVE}/scripts/clutch.sh"
fi

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
  # Legacy pins from the pre-rebrand .app name.  Remove by either label.
  for label in "Harness" "DeepSeek Harness Web"; do
    if dockutil --list | grep -q "$label"; then
      dockutil --remove "$label" --no-restart || true
    fi
  done
  if dockutil --list | awk -F'\t' '{print $1}' | grep -qx "DeepSeek"; then
    dockutil --add "$APP" --after "DeepSeek" --no-restart
  else
    dockutil --add "$APP" --no-restart
  fi
  killall Dock 2>/dev/null || true
else
  echo "dockutil not installed; app is at $APP — drag it to the Dock" >&2
fi

echo "installed $APP"
echo "WKWebView shell; Dock running-dot; second click focuses the same window"
open -a "$APP"
