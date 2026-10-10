# Mac Updaters, TestFlight Parity, and BotFleet Computer Tools

This document defines the architectural standards for macOS application updaters, TestFlight distribution, and tool/computer-use parity for DeepSeek and MiniMax models across the fleet.

---

## 1. Why BotFleet's Updater Was Buggy (And How We Avoid It)

BotFleet's desktop updater used `electron-updater`, which introduced several recurring production failure modes:

1. **Missing Feed Artifacts:** Required `latest-mac.yml` and dual-architecture zip files on GitHub releases.  When releases were published as drafts or secrets failed during CI, the feed 404'd or mismatched sha512 checksums.
2. **Permission Clobbering (TCC):** Naively overwriting the `.app` bundle stripped macOS Accessibility and Device Control permissions unless signed with the exact Developer ID identity and re-registered.
3. **Disruptive Modal Flow:** Popped up intrusive dialogues that interrupted active agent sessions and forced unexpected restarts.

### The Modern Fleet Standard: Three Seamless Tracks

To eliminate these issues, all Mac apps in our fleet follow three dedicated tracks:

| App Category | Primary Update Channel | Mechanism | Benefits |
|---|---|---|---|
| **App Store / TestFlight Apps** (the Clutch iOS app, bundle `codes.clutch.ios`) | macOS TestFlight | Apple App Store Connect & TestFlight macOS | Zero updater framework, automatic silent background downloads, zero signature errors, preserves all TCC permissions. |
| **Standalone macOS Apps** (`Clutch.app`, bundle `codes.clutch.macos`) | In-App Seamless Updater | `ClutchAppUpdater` + `update-mac-app.sh` | Non-intrusive background check, `Check for Updates...` menu item, semantic version comparison against GitHub API, atomic re-signing. |
| **Mac always-on engine** (`~/apps/clutch-runtime`, pm2 `clutch-web`) | Unattended LaunchAgent | `com.jay.clutch-auto-update` + `auto-update-mac.sh` | Fast-forwards `origin/main` every 5 minutes, syncs profiles and presets, smoke-tests the engine, restarts the web, and rolls a broken commit back.  See § 4. |

---

## 2. Track A: macOS TestFlight Distribution

For SwiftUI apps such as the Clutch iOS app:

- **Shared Codebase:** Built using SwiftUI and compiled for iOS 17.0+ and macOS via Mac Catalyst or Designed for iPad on Apple Silicon Mac (`TARGETED_DEVICE_FAMILY: '1,2'`).
- **TestFlight Distribution:** When uploaded to App Store Connect, the build is distributed to both iOS devices and Apple Silicon Macs running macOS Sonoma (14.0+).
- **Background Updates:** macOS TestFlight silently updates the application in the background when new builds are published, requiring zero third-party updater code.
- **In-App Awareness:** If an app is running under TestFlight (detected via `Bundle.main.appStoreReceiptURL`), the in-app updater menu cleanly defers: *"Updates are managed seamlessly by TestFlight or the Mac App Store."*

---

## 3. Track B: Seamless In-App Updater for Standalone Mac Apps

For standalone AppKit dock apps (`Clutch.app` compiled from `ClutchWindow.swift`):

1. **Application Menu Integration:**
   - Adds standard macOS menu item `Check for Updates...` (`Cmd+U`) in the main application menu under `About Clutch`.
2. **Unobtrusive Background Checking:**
   - 3 seconds after launch, an asynchronous background request queries GitHub Releases (`https://api.github.com/repos/Simple-With-Us/Clutch/releases/latest`).
   - If an update is detected, the menu item silently updates to `Check for Updates... (vX.Y Available)`.  It does not throw modal popups mid-work.
3. **Interactive Update Check:**
   - When clicked:
     - If up to date: Displays standard native sheet confirming the current version and build.
     - If an update is available: Displays release notes and offers `Update & Relaunch`, `View Release Notes`, or `Later`.
4. **Atomic Re-Signing & TCC Preservation:**
   - Triggers `scripts/update-mac-app.sh`, which fast-forwards the standalone runtime clone (`git pull --ff-only` in `~/apps/clutch-runtime`), runs `npm ci`, rebuilds the bundle, re-signs with `Developer ID Application: Jay Wedgeworth, LLC (CC8UTF7ATG)` (or ad-hoc `codesign -s -`), and relaunches the app cleanly.

---

## 4. Unattended Auto-Update (the macOS always-on deployment)

Track B asks the owner to click.  The Mac deployment also updates itself with no prompt:
LaunchAgent `com.jay.clutch-auto-update` runs `~/apps/clutch-auto-update.sh` every 300 seconds
and at load, and that script keeps `~/apps/clutch-runtime` on `origin/main`.

Each run, in order:

1. `git fetch origin` under a 60-second cap.  An up-to-date run logs nothing and exits.
2. Stop early on a pause file, a dirty checkout, an interrupted merge or rebase, or a lock held
   by a run that is still working (a lock older than 30 minutes is treated as dead).
3. `git merge --ff-only origin/main`.  A commit remembered in `~/.clutch/auto-update.bad-sha` is
   not retried until `origin/main` moves again.
4. `npm ci` only when `package-lock.json` moved or the toolchain is missing.
5. `npm run sync`, which copies profiles and agent presets into `~/.clutch/dsh`.  This is the step
   the other tracks never did, and the reason a landed preset fix used to sit unused.
6. Smoke-test the engine (`node node_modules/.bin/dsh --version`) before anything is restarted.
7. Restart pm2 `clutch-web` when code the running server loads moved, then poll
   `http://127.0.0.1:3180/` until it answers.  A docs-only, tests-only, CI, iOS or image-asset
   advance skips the restart and logs `NO-RESTART`.
8. Rebuild `~/Applications/Clutch.app` only when `src/web/dock-app/`, `assets/clutch-icon-1024.png`
   or `install-dock-app.sh` moved.

A failure after the fast-forward rolls the checkout back to the previous commit, re-syncs,
restarts the web if it had already been restarted, and remembers the bad sha.  A broken `main`
therefore neither bricks the Mac nor gets retried on every tick.

- Install or reinstall: `scripts/install-clutch-auto-update.sh`
- Verify: `scripts/install-clutch-auto-update.sh --verify`
- Pause: `touch ~/.clutch/auto-update.pause` (resume: `rm ~/.clutch/auto-update.pause`)
- Remove: `scripts/install-clutch-auto-update.sh --uninstall`
- Log: `~/apps/logs/clutch-auto-update.log`

The live copy is a regular file at `~/apps/clutch-auto-update.sh`, never a symlink into
`~/apps/clutch-runtime`: the updater moves that checkout, and bash must not read a script the
checkout rewrites underneath it.  The updater refreshes its own live copy atomically after each
successful pull.  `scripts/update-mac-app.sh` takes the same lock, so a manual update and an
automatic one can never run `npm ci` side by side in one checkout.

---

## 5. BotFleet Computer Use & Tool Parity for DeepSeek & MiniMax

BotFleet provides agents with four core computer destinations:

1. **This Mac (`local`):** Host machine execution (`bash`, `read_file`, `write_file`, `edit_file`) bounded by permission broker approval.
2. **Cloud Box (`box`):** ASCII.dev remote isolated Linux sandbox container with network egress and computer proxy.
3. **Cloud VPS (`vps`):** Dedicated self-hosted VPS running Cua Driver with full desktop GUI, mouse, and browser control.
4. **Local VM (`vm`):** Local isolated microVM container running on Apple Silicon.

### Full Parity in Clutch

To ensure MiniMax (`mm`) and DeepSeek (`ds`) have full access to all tools and computer use options:

1. **`mcpServers: true` on Both Adapters:**
   - Both `dshSupport` and `minimaxSupport` declare `mcpServers: true`.  BotFleet automatically mounts all computer destinations, Composio, and agent servers.
2. **Cordis `--patch` Dynamic Overlays:**
   - Both `bridges/dsh/dsh-acp.py` and `bridges/minimax/minimax-acp.py` support `--patch <path>` on CLI and dynamically parse `mcpServers` from ACP `session/new` requests, writing a temporary Cordis overlay that configures `@deepseek-ai/dsh-mcp-client` for each server.
3. **Model Catalog Parity:**
   - `STATIC_MINIMAX_MODELS` includes `MiniMax-M3.1-Flash-Preview` (`Preview`), `MiniMax-M3`, and `MiniMax-M2.7-highspeed` (`2x Cost`), matching `STATIC_DSH_MODELS` and `settings-minimax-headless.yaml`.
4. **iOS Parity:**
   - The Clutch iOS app shows the clutch web UI, so the same tools and the 4 destination mounts (`local`, `box`, `vps`, `vm`) are available there with no app-specific code.
