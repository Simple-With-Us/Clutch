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

## 3. Build Runner Execution Hierarchy (Owner Preference)

The fleet enforces a three-tier execution hierarchy for Xcode builds, Simulator tests, and TestFlight deployments:

### Tier 1: GitHub-Hosted macOS Runners (`macos-15` / `macos-14`) — Primary Default for Public Repos
- **Policy:** For all **public repositories**, build and test jobs run primarily on GitHub-hosted Apple Silicon macOS runners (`runs-on: macos-15` or `macos-14`).
- **Rationale:** Free for public repositories, offloads CPU and memory usage from the developer's physical Mac, executes inside a guaranteed clean-room macOS image, and automatically reports verifiable commit and PR status checks directly on GitHub.
- **Workflow:** Configured in `.github/workflows/ci.yml` under the `ios` job.

### Tier 2: Headless Local macOS Guest VM (`mac_vm`) — Required Secondary Tier
- **Policy:** Reserved for scenarios where GitHub hosted runners cannot or should not be used:
  1. **Private Repositories:** Where GitHub Actions macOS runner minutes incur billable per-minute costs.
  2. **Specialized Credential Enclaves:** Jobs requiring local hardware signing keys, local secrets, or sensitive provisioning certificates that must not reside on public cloud runners.
  3. **Local/Offline Workflows:** Rapid iteration during offline development or when testing local daemon communication (e.g. testing Harness daemon on `127.0.0.1:3080` against an active iOS simulator).
- **Execution:** Headless execution via Apple Virtualization / Tart (`scripts/mac-guest-vm-runner.sh`) ensures simulators and compilers run without stealing active window focus or mouse/keyboard events on the host Mac.

### Tier 3: Direct Host Mac (`local`) — Fallback Only
- **Policy:** Only used for interactive debugging, manual UI inspection, or on machines where hardware virtualization is unavailable.

---

## 4. Provisioning & Headless Execution via Tart / Virtualization

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

## 5. Subagent Role: `xcode_ship`

In `src/shared/subagent-tool-profiles.ts`, the specialized subagent role `xcode_ship` is configured with minimal tool surface area:
- **Allowed Tools:** `view_file`, `run_command`, `send_message`.
- **Model Tier:** Flash (mechanical build automation and log parsing).
- **Execution Target:** Dispatches build and test commands to the headless `mac_vm` runner (`scripts/mac-guest-vm-runner.sh`).
