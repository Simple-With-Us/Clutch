# Mac Updaters, TestFlight Parity, and BotFleet Computer Tools

This document defines the architectural standards for macOS application updaters, TestFlight distribution, and tool/computer-use parity for DeepSeek and MiniMax models across the fleet.

---

## 1. Why BotFleet's Updater Was Buggy (And How We Avoid It)

BotFleet's desktop updater used `electron-updater`, which introduced several recurring production failure modes:

1. **Missing Feed Artifacts:** Required `latest-mac.yml` and dual-architecture zip files on GitHub releases.&nbsp; When releases were published as drafts or secrets failed during CI, the feed 404'd or mismatched sha512 checksums.
2. **Permission Clobbering (TCC):** Naively overwriting the `.app` bundle stripped macOS Accessibility and Device Control permissions unless signed with the exact Developer ID identity and re-registered.
3. **Disruptive Modal Flow:** Popped up intrusive dialogues that interrupted active agent sessions and forced unexpected restarts.

### The Modern Fleet Standard: Two Seamless Tracks

To eliminate these issues, all Mac apps in our fleet follow two dedicated tracks:

| App Category | Primary Update Channel | Mechanism | Benefits |
|---|---|---|---|
| **App Store / TestFlight Apps** (`HarnessCompanion`) | macOS TestFlight | Apple App Store Connect & TestFlight macOS | Zero updater framework, automatic silent background downloads, zero signature errors, preserves all TCC permissions. |
| **Standalone macOS Apps** (`Harness.app`) | In-App Seamless Updater | `HarnessAppUpdater` + `update-mac-app.sh` | Non-intrusive background check, `Check for Updates...` menu item, semantic version comparison against GitHub API, atomic re-signing. |

---

## 2. Track A: macOS TestFlight Distribution

For multiplatform SwiftUI apps such as `HarnessCompanion`:

- **Shared Codebase:** Built using SwiftUI and compiled for iOS 17.0+ and macOS via Mac Catalyst or Designed for iPad on Apple Silicon Mac (`TARGETED_DEVICE_FAMILY: '1,2'`).
- **TestFlight Distribution:** When uploaded to App Store Connect, the build is distributed to both iOS devices and Apple Silicon Macs running macOS Sonoma (14.0+).
- **Background Updates:** macOS TestFlight silently updates the application in the background when new builds are published, requiring zero third-party updater code.
- **In-App Awareness:** If an app is running under TestFlight (detected via `Bundle.main.appStoreReceiptURL`), the in-app updater menu cleanly defers: *"Updates are managed seamlessly by TestFlight or the Mac App Store."*

---

## 3. Track B: Seamless In-App Updater for Standalone Mac Apps

For standalone AppKit dock apps (`Harness.app` compiled from `HarnessWindow.swift`):

1. **Application Menu Integration:**
   - Adds standard macOS menu item `Check for Updates...` (`Cmd+U`) in the main application menu under `About Harness`.
2. **Unobtrusive Background Checking:**
   - 3 seconds after launch, an asynchronous background request queries GitHub Releases (`https://api.github.com/repos/jaywedgeworth22/Harness/releases/latest`).
   - If an update is detected, the menu item silently updates to `Check for Updates... (vX.Y Available)`.&nbsp; It does not throw modal popups mid-work.
3. **Interactive Update Check:**
   - When clicked:
     - If up to date: Displays standard native sheet confirming the current version and build.
     - If an update is available: Displays release notes and offers `Update & Relaunch`, `View Release Notes`, or `Later`.
4. **Atomic Re-Signing & TCC Preservation:**
   - Triggers `scripts/update-mac-app.sh`, which pulls latest commits (if in git), rebuilds the bundle, re-signs with `Developer ID Application: Jay Wedgeworth, LLC (CC8UTF7ATG)` (or ad-hoc `codesign -s -`), and relaunches the app cleanly.

---

## 4. BotFleet Computer Use & Tool Parity for DeepSeek & MiniMax

BotFleet provides agents with four core computer destinations:

1. **This Mac (`local`):** Host machine execution (`bash`, `read_file`, `write_file`, `edit_file`) bounded by permission broker approval.
2. **Cloud Box (`box`):** ASCII.dev remote isolated Linux sandbox container with network egress and computer proxy.
3. **Cloud VPS (`vps`):** Dedicated self-hosted VPS running Cua Driver with full desktop GUI, mouse, and browser control.
4. **Local VM (`vm`):** Local isolated microVM container running on Apple Silicon.

### Full Parity in Harness

To ensure MiniMax (`mm`) and DeepSeek (`ds`) have full access to all tools and computer use options:

1. **`mcpServers: true` on Both Adapters:**
   - Both `dshSupport` and `mmhSupport` declare `mcpServers: true`.&nbsp; BotFleet automatically mounts all computer destinations, Composio, and agent servers.
2. **Cordis `--patch` Dynamic Overlays:**
   - Both `bridges/dsh/dsh-acp.py` and `bridges/mmh/mmh-acp.py` support `--patch <path>` on CLI and dynamically parse `mcpServers` from ACP `session/new` requests, writing a temporary Cordis overlay that configures `@deepseek-ai/dsh-mcp-client` for each server.
3. **Model Catalog Parity:**
   - `STATIC_MMH_MODELS` includes `MiniMax-M3.1-Flash-Preview` (`Preview`), `MiniMax-M3`, and `MiniMax-M2.7-highspeed` (`2x Cost`), matching `STATIC_DSH_MODELS` and `settings-mmh-headless.yaml`.
4. **iOS & Mac Companion Parity:**
   - `ToolItem.swift` and `ToolsView.swift` expose a dedicated **Computer Use** section detailing Computer Control GUI actions (`screenshot`, `mouse_click`, `key`, `cursor_position`) and the 4 destination mounts (`local`, `box`, `vps`, `vm`).
