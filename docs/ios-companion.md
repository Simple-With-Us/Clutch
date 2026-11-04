# Clutch iOS App

The Clutch iOS app (bundle `codes.clutch.ios`, XcodeGen project in `ios/`) is a native client of Clutch.  It drives every engine Clutch runs — DeepSeek, MiniMax, MiniMax Code and Muse Code — through the chat sidecar on your Mac, and it shows no web page at all.  Version 1.0 is the first release under the Clutch name.

## Architecture

```
iPhone / iPad                          Mac
┌────────────────────────────┐         ┌──────────────────────────────────────────┐
│ Clutch.app (SwiftUI)       │  HTTPS  │ Tailscale Serve  https://<magicdns>:3181  │
│  • pairing (QR / paste)    │ ──────▶ │        │ proxy                           │
│  • host switcher, probe    │ tailnet │        ▼                                 │
│  • thread rail, transcript │         │ chat sidecar  127.0.0.1:3181              │
│  • approvals, plan, files  │         │   dsh web (@deepseek-ai/dsh) with state   │
└────────────────────────────┘         │   in ~/.clutch/dsh                        │
                                       └──────────────────────────────────────────┘
```

- **Backend:** the always-on `clutch-web` process (`scripts/start-web.sh`, live install `~/apps/clutch-runtime`).  The app talks to its chat sidecar, and the sidecar talks to the engines.
- **Surface:** native.  The thread rail, the transcript, the approval card, the plan panel, the file browser and the tool-call tree are SwiftUI, and the iOS and macOS apps render them from the same models.
- **The web UI:** `dsh web` still serves the upstream browser client on port 3180, and Clutch still installs it.  The apps no longer open it: there is no web view and no WebKit content process on the device.

### Why The Sidecar Is The Seam

The dsh host contract is an internal, versioned-with-the-package transport, so an app that spoke it directly would break on every upstream bump.  The sidecar already speaks it: it runs the DeepSeek and MiniMax turns inside the host, relays the host's approval requests, and translates the host's session graph into the transcript the apps render.  The chat surfaces speak one contract of their own — the sidecar's `/clutch/v1` routes — and the upstream churn stays in one place.  The decision is recorded in [`decisions/0009-dsh-hosted-turns-run-in-the-host.md`](./decisions/0009-dsh-hosted-turns-run-in-the-host.md).

## Authentication And Pairing

The sidecar mints a chat token on its first boot and hands it out with the pairing link.  `clutch-pair-ios` prints `clutch://pair?url=https://<magicdns>:3180/?token=<t>&chat=<c>&chatPort=3181` and opens a QR code of it.  In the app, tap **Scan Pairing Code** or **Paste Pairing Link**.

The chat token is what the app sends as `Bearer` on every `/clutch/v1` call, and it is kept in `$CLUTCH_HOME/chat-token` on the Mac, so a restart of the sidecar does not undo a pairing.  The launch token in the same link belongs to the web origin's cookie exchange, which only the Host tab still uses: it trades the token for a signed cookie on every connect, and that cookie does not survive an app restart, so the token is kept in the keychain for the life of the pairing.

When the sidecar stops accepting the token the app shows **Pair This Device**, with the same pairing controls.  When the host cannot be reached at all it shows **Cannot Reach &lt;host&gt;**, with **Try Again** and **Switch Host**.  Both cards replace the surfaces that need the sidecar, so nothing keeps asking a host that is down, and the Host tab and Fleet Recall stay reachable while it is down.  The card keeps the host picker, and the dot on it follows the gate rather than the probe: a host that is running but has dropped this device's token reads orange, not green.

For the Simulator on the same Mac: `clutch-pair-ios --simulator` opens the link against `http://127.0.0.1:3180` in the booted simulator.  `--print` prints the link (it contains the tokens).

Accepted pairing inputs (`ios/App/Services/PairingLink.swift`):

| Input | Example |
|---|---|
| Pairing link | `clutch://pair?url=https%3A%2F%2Fmac.tailnet.ts.net%3A3180%2F%3Ftoken%3D…&name=Studio` |
| Launch URL | `http://127.0.0.1:3180/?token=…` |
| Address | `mac.tailnet.ts.net` (defaults to port 3180, HTTPS) or `127.0.0.1:3180` |

Only the `clutch://` scheme is accepted.

## Project Layout

```
ios/
├── project.yml                 # XcodeGen spec (app, ClutchTests, ClutchUITests)
├── Clutch.entitlements
├── Assets.xcassets             # full-bleed square 1024 icon, accent color
├── Resources/AppIcon.png       # in-app copy of the icon
├── Tests/PairingTests.swift    # pairing parser, host model, probe, store
├── Tests/HostGateTests.swift   # the sidecar gate, and the state the picker shows
├── Tests/HostTabsTests.swift   # the tabs a host can take away
├── UITests/ClutchLiveUITests.swift
└── App/
    ├── ClutchApp.swift         # entry; light theme by default
    ├── Info.plist              # generated from project.yml
    ├── Models/ClutchHost.swift, HostTabs.swift
    ├── Services/PairingLink.swift, HostProbe.swift, HostStore.swift, HostGate.swift
    └── Views/RootView.swift, HostGateView.swift, PairView.swift,
              HostsSheet.swift, PairingScannerSheet.swift
```

## TestFlight Ship (GitHub-hosted)

Merges to `main` that touch `ios/**` trigger `.github/workflows/ios-ship.yml` on the fleet `xcode-27` runner (stable Xcode 27.0).  The workflow loads `APPLE_API_*` and `IOS_CERT_*` from Infisical, installs App Store profiles via the App Store Connect API (`ios/appstore-profiles.json`), archives with manual Release signing, uploads to TestFlight, and publishes mandatory What to Test notes from commit subjects.  Distribution stays internal-testers only.  Bundle `codes.clutch.ios`, Apple ID `6817951255`.

Auto-ship contract (owner 2026-10-17):  a merge to `main` that touches `ios/**` uploads a fresh TestFlight build with no human step.  An hourly scheduled run (`23 * * * *`) is the catch-up for a push ship that failed or never fired (a bot-merged PR dispatches no push run);  it ships only when `scripts/ios-fleet/scheduled-ship-gate.sh` finds `ios/` changed since the last successful ship, and the ship script's 2.5 hour rate gate and same-HEAD skip stay at their defaults.  `workflow_dispatch` is the manual path.  Never set `IOS_TF_MIN_INTERVAL_SEC` or `--force-ship` in the workflow.

Deploy checks that run in CI on every PR (`tests/ios-ship-workflow.test.ts`):  the 1024 AppIcon must have no alpha channel (Apple rejects the upload with altool 90717, and the unsigned PR dry-run cannot see it), and the workflow must keep its push paths, scheduled gate, ship-state cache, What to Test publish and no standing gate override.  The Mac slot of the icon set uses its own transparent `icon-mac-1024.png`.  If the ship fails, read the `altool` error in the run log first:  the script's "no App Store Connect app" hint is only one of several causes.

## Building and Testing

```bash
bash scripts/build-ios.sh --simulator     # generic simulator build (CI)
bash scripts/build-ios.sh --device        # generic device build, unsigned
cd ios && xcodegen generate && xcodebuild -project Clutch.xcodeproj -scheme Clutch \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Never hand-edit `Clutch.xcodeproj`; change `project.yml` and regenerate.

## MiniMax Code Server Hosts

A host does not have to be a Mac running clutch web.  A Linux server with MiniMax Code installed can pair as a MiniMax Code server host (`kind=mcode`): it runs only the chat sidecar, so the app gives it a Code tab and the Chat tab's MiniMax Code surface, and skips the dsh host tab it has nothing behind.  The Mac also drops its Agent Chat tab for such a host, because that surface talks to the dsh host; the phone keeps its Chat tab, which is the surface a code server is for.  Its status probe reads the sidecar health route instead of the web auth wall, and the app's gate asks that same route before it shows a surface.  Setup, the systemd unit, and the live Hetzner host are in [`docs/minimax-code-server.md`](minimax-code-server.md); pairing is `clutch-pair-ios --server` on that machine.

## Known Limits

- The phone reaches the sidecar only over Tailscale (the web process binds loopback).  Tailscale must be connected on the phone.
- A pairing lasts as long as the chat token does.  The token is minted on the sidecar's first boot and kept in `$CLUTCH_HOME/chat-token`, so a restart keeps the pairing and a deliberate token reset does not.
- The upstream web UI is still the reference for anything the native surfaces do not carry.  The apps do not show it, so a feature that has not come across natively is not available on the phone.
