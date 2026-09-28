# macOS Guest Virtual Machines for Headless Xcode & TestFlight Bots

## Executive Summary

While standard Linux microVMs (`vm`) are ideal for Node, Python, and headless Chrome, they **cannot run Xcode, Apple Simulators, or Developer ID code-signing**.  For automation bots responsible for `xcodebuild`, Simulator visual tests, and App Store Connect (ASC) / TestFlight distribution, the fleet standard is a **macOS Guest Virtual Machine (`mac_vm`)** running on Apple Silicon via Apple's native `Virtualization.framework` (or [Tart](https://tart.run)).

---

## 1. Why Xcode Bots Need a Dedicated macOS Guest VM

Running `xcodebuild` or Simulator tests directly on the operator's physical desktop (`local`) introduces significant workflow friction:
1. **Display & Focus Hijacking:** iOS Simulator windows pop up, steal active window focus, and intercept keystrokes while the operator is typing.
2. **Keychain Prompt Contention:** Signing and provisioning profile unlocks can prompt modal dialogs on the host screen.
3. **Dirty DerivedData & Caches:** Concurrent builds across different agent seats can conflict over module caches and simulator runtimes.

Running inside a headless macOS Guest VM (`mac_vm`) completely eliminates these issues:
- **Headless Virtual Framebuffer:** The guest macOS VM runs with a dedicated virtual display (e.g. 1920x1080).  Simulators boot, animate, and capture screenshots entirely inside the VM buffer without opening a window on your physical desktop.
- **Credential Isolation:** App Store Connect API keys (`AuthKey_*.p8`, `ASC_KEY_ID`, `ASC_ISSUER_ID`) and Developer certificates live inside the guest VM environment.
- **Instant Snapshots:** Roll back to a pristine clean-room state in seconds using APFS copy-on-write snapshots.

---

## 2. Architecture: Host vs. Guest VM

```
┌─────────────────────────────────────────────────────────────┐
│                       Host Mac (Host OS)                    │
│  - Operator desktop: Cursor, Slack, Terminal (Uninterrupted)│
│  - BotFleet / Harness Agent Orchestrator                    │
└──────────────────────────────┬──────────────────────────────┘
                               │ Mounts repo worktree & dispatches
                               ▼
┌─────────────────────────────────────────────────────────────┐
│            macOS Guest Virtual Machine (mac_vm)             │
│  - Engine: Apple Virtualization.framework / Tart            │
│  - Virtual Display: Headless 1920x1080@60Hz                │
│  - Isolated Xcode 15/16 + Command Line Tools                │
│  - Dedicated Simulators (iPhone 15/16, iPad Pro)            │
│  - Dedicated ASC & TestFlight credentials                   │
│                                                             │
│  Lanes Running Inside Guest VM:                             │
│  1. `xcodebuild` (Clean compilation & linking)              │
│  2. `xcrun simctl` (Headless UI tests & screenshots)        │
│  3. `ship-testflight.sh` (ASC validation & upload)          │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Provisioning & Headless Execution via Tart / Virtualization

### Step A: Pull or Create the Base macOS Image
```bash
# Pull standard macOS Sequoia/Sonoma builder image
tart clone ghcr.io/cirruslabs/macos-sonoma-xcode:latest macos-builder
```

### Step B: Launch Headless VM with Mounted Worktree
```bash
# Run headless (no GUI window on host display) with shared repo directory
tart run macos-builder --no-graphics --dir harness-lane:/Users/jay/apps/harness-ag
```

### Step C: Execute Build / TestFlight Command Inside VM
```bash
# SSH into guest VM and execute the build pipeline
tart exec macos-builder -- bash -c "
  cd /Volumes/My\ Shared\ Files/harness-lane
  bash scripts/build-ios.sh --device
  bash scripts/ios-fleet/ship-testflight.sh Harness
"
```

---

## 4. Subagent Role: `xcode_ship`

In `src/shared/subagent-tool-profiles.ts`, the specialized subagent role `xcode_ship` is configured with minimal tool surface area:
- **Allowed Tools:** `view_file`, `run_command`, `send_message`.
- **Model Tier:** Flash (mechanical build automation and log parsing).
- **Execution Target:** Dispatches build and test commands to the headless `mac_vm` runner (`scripts/mac-guest-vm-runner.sh`).
