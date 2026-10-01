# Bundle ID History

The macOS bundle id for `~/Applications/Harness.app` has changed as the
product's owner moved from one domain to another.  Each rename breaks
the macOS-managed per-app state, so the convention is to call it out
here at the same time the rename is committed.

## Entries

| Date       | Bundle ID                       | Notes |
|------------|---------------------------------|-------|
| 2026-09-30 | `codes.clutch.macos` (Mac), `codes.clutch.ios` (iOS) | Rename to Clutch.  `codes.clutch.macos` and `codes.clutch.ios` are adopted; `com.simplewithus.harness.mac` and `com.simplewithus.harness.ios` are retired.  `~/Applications/Clutch.app` replaces `Harness.app`, so the Dock pin and saved window frame do NOT survive (the autosave name is now `CodesClutchMacMain`) — re-pin after `bash scripts/install-dock-app.sh`.  The Mac app stays ad-hoc signed; `codes.clutch.macos` is not registered in the Apple Developer portal until a Mac TestFlight build is wanted.  Rollback: reinstall the previous release, which carries the old id and loses the Clutch frame the same way. |
| 2026-09-23 | `com.simplewithus.harness.mac`  | Consumer rebrand.  `simplewithus.com` is the new owner-facing domain (resolves to Cloudflare IPs `104.21.42.208`, `172.67.166.74`).  Dock pin and saved window frame do NOT survive the rename — re-pin after `bash scripts/install-dock-app.sh`.  Apple Developer portal registration for the new id is still pending; current `.app` is ad-hoc signed (`codesign --force --deep -s -`) only.  Marketing page at `harness.simplewithus.com` is a future-work item (NXDOMAIN as of 2026-09-23). |
| 2026-09-19 | `services.jays.harness`         | Interim owner-personal id after the DSH -> Harness rebrand.  Same caveat: Dock pin and saved frame do NOT survive. |
| earlier    | `com.jays.dsh-harness-web`      | Initial DSH-consumer id.  No consumer app, no Dock pin to preserve. |

## Why this file exists

`scripts/install-dock-app.sh` and `src/web/open-harness.ts` carry a
short history line in their headers.  This file is the longer record:
every rename (and the rollback story for each) lands here so future
operators can trace the bundle id back to the reason it changed.

Apple's `NSWindow.setFrameAutosaveName` follows a similar reverse-DNS
pattern; the Swift window uses `ComSimplewithusHarnessMacMain` to
match the current bundle id.  Renaming the bundle id also requires
renaming the autosave name or the saved frame is silently dropped.