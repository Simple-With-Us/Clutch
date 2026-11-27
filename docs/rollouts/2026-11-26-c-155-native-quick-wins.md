# Native Quick Wins (C-155)

## Context & Objective

Owner request, November 26, 2026: improve the iOS and macOS apps across intuitiveness, UI and UX, reliability, performance, efficiency, telemetry and stats, and breadth of capabilities, after a thorough review, acting as autonomously as possible.  Six parallel source auditors plus a completeness critic produced fifty ranked actions across navigation, chat reading, Mac parity, reliability, performance, and telemetry with accessibility.  This rollout lands the first scoped batch: the quick, high-value fixes on files unchanged upstream.  Structural work stays open under C-155.

## Changes Made

- `ios/App/Services/DshHostClient.swift`: stream inboxes bounded at 4096 with a dropped counter; streams end and leave the registry on host end and error frames, on `closeStream`, on `closeMux`, and on socket death.
- `ios/App/Services/HostGate.swift`: a 5xx health answer classifies as unreachable, so a broken sidecar no longer reads ready.
- `ios/App/Services/ChatSessionClient.swift`: an unreadable permission event fails the turn instead of vanishing while the engine waits.
- `ios/App/Services/PairingLink.swift`: bare addresses default to plaintext only for loopback, private, link-local, and tailnet ranges; the `name!` force unwrap is gone.
- `ios/App/Services/KeychainStore.swift`: items are `WhenUnlockedThisDeviceOnly`.
- `ios/App/Services/ErrorReporting.swift` and `ios/App/SentryTelemetry.swift`: transport lines carry domain and code, redaction covers credentials and emails, environments split by build stream, and `beforeSend` scrubs every event.
- `ios/App/Views/HostSwitcher.swift`: status is a symbol plus a spoken value in token colours, and the two fixed font sizes left the design-literal allowlist.
- `ios/Shared/ClutchShared.swift` and both widgets: one staleness rule and spoken summary, an approvals deep link and label on the count, a waiting-only island count, and full-contrast island status.
- `ios/App/Views/ClutchMarkdownText.swift`: fence splits and inline parses are cached by source text across body passes.
- `ios/App/Services/HostStore.swift`: host probes run concurrently and persist once.
- `ios/Resources/PrivacyInfo.xcprivacy`: new manifest for both apps and the widget extension, wired through `ios/project.yml` and the regenerated project.
- Tests: host-gate 5xx, permission decode failure, pairing address ranges, transport domain and code, credential redaction, stream bounds, snapshot freshness, and Sentry environments.

## Decisions & Trade-offs

Scope stops at files identical to `origin/main`, except the three-line `HostStore` divergence outside the edited function, so the batch rebases without rework.  Unknown or malformed non-permission stream events still drop quietly, because only a permission can leave an engine blocked.  The markdown cache keys on full source text, which fixes history re-renders and deliberately leaves live-row throttling to the transcript-model batch.  The regenerated `project.pbxproj` renumbers recently added files; no build setting changed.

## Verification State

`xcodebuild -project Clutch.xcodeproj -scheme Clutch -destination 'generic/platform=iOS Simulator' build` and the `Clutch macOS` twin both succeeded, as did `build-for-testing` for the iOS test bundles.  The privacy manifest is present in the built iOS app, widget extension, and macOS app.  `npm run typecheck` passed; `npm test` ran 1148 of 1150 green, with one pre-existing environmental failure in `tests/zcode-acp.test.ts` because this Mac has `/usr/local/bin/zcode-acp-server` installed and the test expects none.  The two suites this diff touches, `tests/design-literal-guard.test.ts` and `tests/dsh-host-pinned.test.ts`, pass 20 of 20.  No simulator runtime is installed on this Mac, so the new Swift unit tests compile but still need an execution run in CI.  No visual pass or Instruments run was taken.

## Next Steps & Blockers

Next under C-155: memoize the Mac transcript derivation and decompose `ChatViewMac.swift`, supervise mux reconnects, isolate the host client, add an idempotency key with a persisted outbox, render iOS assistant text as markdown, persist drafts and window state, and add one privacy-safe product metrics pass.  Later: Home Screen widgets, App Intents, Handoff, localization, and the remote Live Activity push decision.  Nothing blocks this batch.
