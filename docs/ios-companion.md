# Clutch iOS App

The Clutch iOS app (bundle `codes.clutch.ios`, XcodeGen project in `ios/`) puts the clutch web UI that runs on your Mac onto iPhone and iPad.  It is a native shell around one real backend, not a second client with its own API.  Version 1.0 is the first release under the Clutch name.

## Architecture

```
iPhone / iPad                          Mac
┌────────────────────────────┐         ┌──────────────────────────────────────────┐
│ Clutch.app (SwiftUI)       │  HTTPS  │ Tailscale Serve  https://<magicdns>:3180  │
│  • pairing (QR / paste)    │ ──────▶ │        │ proxy                           │
│  • host switcher, probe    │ tailnet │        ▼                                 │
│  • WKWebView ─ clutch web  │         │ pm2 clutch-web  127.0.0.1:3180           │
│    (sessions, streaming,   │         │   dsh web (@deepseek-ai/dsh) with state  │
│     model picker, tools)   │         │   in ~/.clutch/dsh                       │
└────────────────────────────┘         └──────────────────────────────────────────┘
```

- **Backend:** the always-on `clutch-web` process (`scripts/start-web.sh`, live install `~/apps/clutch-runtime`).  DeepSeek and MiniMax models both come from it, so the app needs no model-specific code.
- **Surface:** the full clutch web UI in a `WKWebView` — session list, streaming replies, model switching, tools, settings, and file attachments all work exactly as on the desktop.  The Clutch "C" monogram is injected the same way the Mac Dock app (`src/web/dock-app/ClutchWindow.swift`) does it.
- **Native parts:** pairing (camera QR scan, paste, or typed address), a host switcher, a cookie-less health probe, and native cards for the "pairing expired" and "cannot reach host" states.  Links that leave the paired origin open in Safari.

### Why Not a Native Chat Client

`dsh web` exposes no REST API.  Its browser talks to `/api` over the cordis connection protocol (`@deepseek-ai/dsh-client-connection`), which is an internal, versioned-with-the-package transport.  A native client would have to re-implement it and would break on every upstream bump.  The app therefore shows the real UI instead of a second implementation of it.

## Authentication And Pairing

`dsh web` mints a launch token per process and prints `http://127.0.0.1:3180/?token=<t>`; `scripts/capture-launch-url.cjs` saves it to `~/.clutch/web-launch-url`.  Visiting `/?token=<t>` on any trusted authority sets a signed cookie bound to that authority (30-day lifetime; the signing secret survives restarts) and redirects to `/`.  Every `/api` request must also carry a trusted `Host`, so `start-web` trusts this Mac's detected Tailscale MagicDNS name (read from `tailscale status`) and the names in `CLUTCH_TRUSTED_HOSTS`.

To pair a phone, run on the Mac:

```bash
clutch-pair-ios               # or: node ~/apps/clutch-runtime/src/web/pair-ios.ts
```

It copies a `clutch://pair?url=https://<magicdns>:3180/?token=<t>` link to the clipboard (Universal Clipboard carries it to the iPhone) and opens a QR code.  In the app, tap **Scan Pairing Code** or **Paste Pairing Link**.  The app loads the token URL once, clutch web sets its cookie, and the app drops the token.  When the cookie expires the app shows **Pair This Device** again.

For the Simulator on the same Mac: `clutch-pair-ios --simulator` opens the link against `http://127.0.0.1:3180` in the booted simulator.  `--print` prints the link (it contains the token).

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
├── UITests/ClutchLiveUITests.swift
└── App/
    ├── ClutchApp.swift         # entry; light theme by default
    ├── Info.plist              # generated from project.yml
    ├── Models/ClutchHost.swift
    ├── Services/PairingLink.swift, HostProbe.swift, HostStore.swift
    └── Views/RootView.swift, ClutchWebView.swift, PairView.swift,
              HostsSheet.swift, PairingScannerSheet.swift
```

## Building and Testing

```bash
bash scripts/build-ios.sh --simulator     # generic simulator build (CI)
bash scripts/build-ios.sh --device        # generic device build, unsigned
cd ios && xcodegen generate && xcodebuild -project Clutch.xcodeproj -scheme Clutch \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Never hand-edit `Clutch.xcodeproj`; change `project.yml` and regenerate.

## Known Limits

- The phone reaches clutch web only over Tailscale (the web process binds loopback).  Tailscale must be connected on the phone.
- Pairing links stop working when `clutch-web` restarts; an already-paired phone keeps working on its cookie for 30 days.
- The clutch web layout is the upstream one; very narrow phone widths get the upstream mobile layout, not a bespoke native design.
