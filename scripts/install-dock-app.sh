#!/usr/bin/env bash
# Build ~/Applications/Clutch.app and pin it to the Dock.  Sources come from
# the runtime clone ($CLUTCH_RUNTIME_ROOT, default ~/apps/clutch-runtime).
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LIVE="${CLUTCH_RUNTIME_ROOT:-${HOME}/apps/clutch-runtime}"
APP="${CLUTCH_MAC_APP:-${HOME}/Applications/Clutch.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# C-78: this script installs the deprecated WKWebView shell to the same path
# the native app uses.  Refuse to pave a native install unless the operator
# says so explicitly with CLUTCH_DOCK_OVERWRITE_NATIVE=1.
if [ "${CLUTCH_DOCK_OVERWRITE_NATIVE:-0}" != "1" ] && [ -d "$APP" ]; then
  bundle_id="$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb")).get("CFBundleIdentifier",""))' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$bundle_id" = "codes.clutch.macos" ] \
    && ! grep -q "WKWebView" "$APP/Contents/MacOS/Clutch" 2>/dev/null; then
    echo "refusing to install the Dock shell over the native Clutch.app at $APP (C-78)" >&2
    echo "set CLUTCH_DOCK_OVERWRITE_NATIVE=1 to proceed anyway" >&2
    exit 1
  fi
fi

export CLUTCH_RUNTIME_ROOT="$LIVE"
export CLUTCH_MAC_APP_OUT="$APP"
export CLUTCH_MAC_KILL_RUNNING=1
bash "${ROOT}/scripts/build-mac-app.sh"

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
