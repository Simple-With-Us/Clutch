# Decision 0004 — Automated visual verification for UI surfaces

**Date:** 2026-09-27
**Status:** Accepted (standing rule)
**Author:** [MUSE]

## Context

The owner killed the manual live-screenshot review requirement for UI
changes (2026-09-24): he does not open apps to preview screens and does
not take manual screenshots.  That left a verification gap — UI changes
were landing with only code review and CI.  The owner approved
reinstating screenshot review as **automated-only**: Playwright for web
surfaces, `simctl` for iOS simulator, never by him manually.

Harness's web UI surface is the upstream `@deepseek-ai/dsh` web app,
served through `bash scripts/harness.sh web` on `127.0.0.1:3080` (see
README "Install").  It is auth-walled: `/` answers 401 until a signed
browser cookie is minted from the per-process launch URL the server
prints on stdout.  The 401 still counts as healthy (see
`src/shared/http-up.ts`).

## Decision

**1. Playwright covers the web UI.**  `playwright.config.ts` at the repo
root boots the real server (`scripts/harness.sh web`, isolated `DSH_HOME`
under `e2e/`, no Tailscale sidecar), mints the launch-token cookie once
in a `setup` project, and asserts `toHaveScreenshot` snapshots on
stable deterministic screens.  Baselines are committed; flaky regions
are masked, and screens that cannot be made deterministic are skipped
rather than shipped flaky.

**2. CI runs the specs on every PR.**  The `e2e` job in
`.github/workflows/ci.yml` installs the Chromium browser bundle and
runs `npm run test:e2e`.  The job is a required signal: never merge with
it red.

**3. Manual screenshots are not a verification method.**  The owner
never takes manual screenshots and does not run local UI preview
sessions.  Native Mac app UI (the `HarnessWindow.swift` dock shell) is
verified through code review and CI only.  iOS simulator surfaces, if
any appear, use `xcrun simctl io booted screenshot`.

## Consequences

- UI-changing PRs add or update Playwright snapshots; reviewers treat a
  changed baseline PNG as a deliberate visual diff, not noise.
- The web server must keep booting credential-free (fresh `DSH_HOME`,
  no provider keys) or the `e2e` job fails on every PR.
- Snapshot baselines are Chromium-on-Linux; platform-specific rendering
  differences are expected and not chased.
