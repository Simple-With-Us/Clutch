# Harness iOS App

The Harness iOS app (bundle `com.simplewithus.harness.ios`, XcodeGen project in `ios/`) puts the harness web UI that runs on your Mac onto iPhone and iPad.  It is a native shell around one real backend, not a second client with its own API.

## Architecture

```
iPhone / iPad                          Mac
┌────────────────────────────┐         ┌──────────────────────────────────────────┐
│ Harness.app (SwiftUI)      │  HTTPS  │ Tailscale Serve  https://<magicdns>:3080  │
│  • pairing (QR / paste)    │ ──────▶ │        │ proxy                           │
│  • host switcher, probe    │ tailnet │        ▼                                 │
│  • WKWebView ─ harness web │         │ pm2 harness-web  127.0.0.1:3080          │
│    (sessions, streaming,   │         │   dsh web (@deepseek-ai/dsh) with the    │
│     model picker, tools)   │         │   dsh-web / mmh-web cordis profiles      │
└────────────────────────────┘         └──────────────────────────────────────────┘
```

- **Backend:** the always-on `harness-web` process (`scripts/start-web.sh`, live install `~/apps/harness-runtime`).  DeepSeek and MiniMax models both come from it through the cordis profiles, so the app needs no model-specific code.
- **Surface:** the full harness web UI in a `WKWebView` — session list, streaming replies, model switching, tools, settings, and file attachments all work exactly as on the desktop.  The Harness "H" monogram is injected the same way the Mac Dock app (`src/web/dock-app/HarnessWindow.swift`) does it.
- **Native parts:** pairing (camera QR scan, paste, or typed address), a host switcher, a cookie-less health probe, and native cards for the "pairing expired" and "cannot reach host" states.  Links that leave the paired origin open in Safari.

### Why not a native chat client

`dsh web` exposes no REST API.  Its browser talks to `/api` over the cordis connection protocol (`@deepseek-ai/dsh-client-connection`), which is an internal, versioned-with-the-package transport.  A native client would have to re-implement it and would break on every upstream bump.  v0.2 of this app shipped native Chat, Tools, Sessions, Fleet RAG, and Composio tabs that called `/v1/*` endpoints nothing served (the only `/v1/*` server was the now-retired MiniMax Remote companion on port 7842), so those tabs never worked.  v0.3 removes them from the build and shows the real UI instead.

## Authentication And Pairing

`dsh web` mints a launch token per process and prints `http://127.0.0.1:3080/?token=<t>`; `scripts/capture-launch-url.cjs` saves it to `~/.dsh/web-launch-url`.  Visiting `/?token=<t>` on any trusted authority sets a signed cookie bound to that authority (30-day lifetime; the signing secret survives restarts) and redirects to `/`.  Every `/api` request must also carry a trusted `Host`, so `start-web` now trusts this Mac's detected Tailscale MagicDNS name as well as the legacy names.

To pair a phone, run on the Mac:

```bash
harness-pair-ios              # or: node ~/apps/harness-runtime/src/web/pair-ios.ts
```

It copies a `harness://pair?url=https://<magicdns>:3080/?token=<t>` link to the clipboard (Universal Clipboard carries it to the iPhone) and opens a QR code.  In the app, tap **Scan Pairing Code** or **Paste Pairing Link**.  The app loads the token URL once, harness web sets its cookie, and the app drops the token.  When the cookie expires the app shows **Pair This Device** again.

For the Simulator on the same Mac: `harness-pair-ios --simulator` opens the link against `http://127.0.0.1:3080` in the booted simulator.  `--print` prints the link (it contains the token).

Accepted pairing inputs (`ios/App/Services/PairingLink.swift`):

| Input | Example |
|---|---|
| Pairing link | `harness://pair?url=https%3A%2F%2Fmac.tailnet.ts.net%3A3080%2F%3Ftoken%3D…&name=Studio` |
| v0.2 link | `harness://pair?h=studio.local&p=3080&tls=0&t=…` |
| Launch URL | `http://127.0.0.1:3080/?token=…` |
| Address | `mac.tailnet.ts.net` (defaults to port 3080, HTTPS) or `127.0.0.1:3080` |

`minimax://` links and port 7842 are rejected with a message that MiniMax Remote is retired.

## Project Layout

```
ios/
├── project.yml                 # XcodeGen spec (app + HarnessTests)
├── Harness.entitlements
├── Assets.xcassets             # full-bleed square 1024 icon, accent color
├── Resources/AppIcon.png       # in-app copy of the icon
├── Tests/PairingTests.swift    # pairing parser, host model, probe, store
└── App/
    ├── HarnessApp.swift        # entry; light theme by default
    ├── Info.plist              # generated from project.yml
    ├── Models/HarnessHost.swift
    ├── Services/PairingLink.swift, HostProbe.swift, HostStore.swift
    └── Views/RootView.swift, HarnessWebView.swift, PairView.swift,
              HostsSheet.swift, PairingScannerSheet.swift
```

The v0.2 mock surfaces still in `ios/App` are listed under `excludes:` in `project.yml` and are not compiled; they are pending deletion.

## Building And Testing

```bash
bash scripts/build-ios.sh --simulator     # generic simulator build (CI)
bash scripts/build-ios.sh --device        # generic device build, unsigned
cd ios && xcodegen generate && xcodebuild -project Harness.xcodeproj -scheme Harness \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Never hand-edit `Harness.xcodeproj`; change `project.yml` and regenerate.

## Known Limits

- The phone reaches harness web only over Tailscale (the web process binds loopback).  Tailscale must be connected on the phone.
- Pairing links stop working when `harness-web` restarts; an already-paired phone keeps working on its cookie for 30 days.
- The harness web layout is the upstream one; very narrow phone widths get the upstream mobile layout, not a bespoke native design.
