#!/usr/bin/env bash
# Update ~/Applications/Clutch.app seamlessly.
# Fast-forwards the runtime clone, reinstalls its dependencies, then re-runs
# install-dock-app.sh, which rebuilds, ad-hoc signs and relaunches Clutch.app.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LIVE="${CLUTCH_RUNTIME_ROOT:-${HOME}/apps/clutch-runtime}"

# C-78: same shared-path guard as auto-update-mac.sh.  The native app keeps
# codes.clutch.macos; the shell is codes.clutch.macos.dock, and a pre-fix
# shell still reports the native id.  Both link WebKit, so the test is the
# Xcode DT* build keys the hand-rolled shell plist never has.
NATIVE_APP_ID="codes.clutch.macos"
MAC_APP="${CLUTCH_MAC_APP:-${HOME}/Applications/Clutch.app}"

installed_is_native() {
  [ -d "$MAC_APP" ] && python3 -c '
import plistlib, sys
try:
    d = plistlib.load(open(sys.argv[1], "rb"))
except Exception:
    sys.exit(1)
ok = d.get("CFBundleIdentifier") == "codes.clutch.macos" and "DTXcodeBuild" in d
sys.exit(0 if ok else 1)
' "$MAC_APP/Contents/Info.plist" 2>/dev/null
}

# Share the auto-updater's lock (LaunchAgent com.jay.clutch-auto-update runs
# scripts/auto-update-mac.sh every 5 minutes).  Two concurrent `npm ci` runs in
# one checkout can leave node_modules broken, so wait for the automatic run to
# finish; after two minutes, say so and proceed rather than block the operator.
# Only the process that created the lock removes it.
LOCK="${CLUTCH_HOME:-${HOME}/.clutch}/auto-update.lock"
mkdir -p "$(dirname "$LOCK")"
LOCK_HELD=0
waited=0
while [ "$LOCK_HELD" = "0" ]; do
  if mkdir "$LOCK" 2>/dev/null; then
    LOCK_HELD=1
  elif [ "$waited" -ge 120 ]; then
    echo "==> auto-update lock is busy; proceeding without it" >&2
    break
  else
    sleep 2
    waited=$((waited + 2))
  fi
done
trap '[ "$LOCK_HELD" = "1" ] && rmdir "$LOCK" 2>/dev/null || true' EXIT

# C-78 short-circuited here when a native Clutch.app was installed, because this
# command only knew how to serve the deprecated shell and would otherwise have
# paved the native app with it.  C-86 is that release pipeline: install-dock-app.sh
# now builds the native `Clutch macOS` target, so this command refreshes a native
# install correctly instead of skipping it.  The installed_is_native()
# discriminator above is still what tells the two apart on disk.

if installed_is_native; then
  echo "==> Updating the installed native Clutch.app from ${LIVE}..."
else
  echo "==> Updating Clutch Mac app from ${LIVE}..."
fi
# Separate statements, not one `&&` chain: under `set -e` a command inside an
# AND-list is exempt from the errexit check unless it is the last one, so the
# old one-liner ran on after a failed `git pull` and still printed "Update
# complete" with exit 0.
git -C "$LIVE" pull --ff-only
(cd "$LIVE" && npm ci)
HEAD_SHA="$(git -C "$LIVE" rev-parse HEAD)"
if bash "$LIVE/scripts/fetch-ci-mac-app.sh" "$HEAD_SHA" "${HOME}/Applications/Clutch.app"; then
  # Clutch.app sets LSMultipleInstancesProhibited, so `open -a` against a
  # still-running older instance only reactivates that stale binary.  The local
  # rebuild path kills via install-dock-app.sh; the CI-fetch path has to as well.
  pkill -f 'Clutch.app/Contents/MacOS/Clutch' 2>/dev/null || true
  open -a "${HOME}/Applications/Clutch.app" >/dev/null 2>&1 || true
  echo "==> Update complete.  Clutch.app installed from CI build ${HEAD_SHA:0:7}."
else
  echo "==> No CI Mac build for ${HEAD_SHA:0:7}; rebuilding locally..." >&2
  bash "$LIVE/scripts/install-dock-app.sh"
  echo "==> Update complete.  Clutch.app is ready."
fi
