# Clutch Native UI/UX Overhaul — Design Review And Program

Date: Sat Nov 21 2026
Seat: OPENCODE
Status: Proposal, ready for owner direction
Scope: `ios/App` (iPhone, iPad) and `ios/Mac` (macOS app), plus the shared views both targets compile

## Verdict

Clutch's native clients are functionally honest and visually accidental.  The code is careful about failure — it says "Not reported" instead of inventing a number, it gates a surface rather than lying about host health — but the interface was assembled one feature at a time, so it has no type scale, no shared card, no status vocabulary, and no information architecture that survived the second surface.  The result is a product whose *engineering* is more mature than its *design*, and the gap is now the main thing limiting how good the app feels.

Four independent reviews reached the same three conclusions without coordination:

1. **The structure is the problem, not the polish.**  On iOS, four top-level tabs (Workspace, Chat, Host, Fleet Recall) spend two slots on a developer console and a search surface, while the two things a user actually does — pick a thread and supervise a turn — are split across two tabs that render the same concept three different ways.  On macOS, one 2,522-line view owns the entire workspace and grows a 220 pt activity pane mid-turn.
2. **The highest-stakes moments are the least designed.**  An approval request blocks the engine and produces no notification anywhere; on iOS the Chat tab cannot stop a running turn; on macOS the agent's answer streams into a different pane from the transcript and then teleports when the turn ends.
3. **The craft layer is missing, and it is cheap to add.**  165 fixed font sizes and zero semantic ones, 7 corner radii for 5 concepts, one shadow in the whole app, 0 `@ScaledMetric`, 0 Reduce Motion checks, 0 haptics, 0 markdown rendering, and an app icon that depicts a different product than the wordmark.

The program below is deliberately sequenced: **structure, then trust surfaces, then craft, then ambient**.  Doing craft first would produce a beautifully typeset version of the wrong screen.

## How this review was run

Four specialists reviewed the actual source, not screenshots:

- **iOS interaction and information architecture** — all 21 files in `ios/App/Views`, models, services, UI tests, and the iOS docs.
- **macOS product design** — `ios/Mac` (3,452 lines), the dock-app window, the Mac build and CI path, and the macOS visual-test setup.
- **Design systems and accessibility** — token inventory by grep count, contrast measurement, Dynamic Type, VoiceOver, tap targets, brand assets, launch experience.
- **Competitive and platform benchmark** — the 2026 agentic-client landscape and Apple's current design language, with sources.

Every finding below is cited to a file and line.  Where the four reviews disagreed, the disagreement is noted; where they agreed independently, that is called out as a shared finding.

## The ten findings that matter

| # | Finding | Platform | Severity | Evidence |
|---|---|---|---|---|
| 1 | An approval request is invisible unless you are staring at the thread.  It blocks the turn, so the turn never ends, so the only notification in the app never fires. | iOS, Mac | P0 | `TurnNotifier.swift:9-32`, `SessionThreadView.swift:419-425`, `ChatView.swift:185-191` |
| 2 | The Chat tab cannot stop a turn and disables the text field while one runs.  The client already has `cancel`. | iOS | P0 | `ChatView.swift:692-739`, `ChatSessionClient.swift:165-180` |
| 3 | A phone-created thread has no working folder, so it runs in `$HOME` and is then un-resumable against the repo the user wanted. | iOS | P0 | `SessionsView.swift:735-744`, `SessionsClient.swift:333-338` |
| 4 | The Mac streams the agent's answer into a separate activity pane, then appends it to the transcript at turn end.  The answer moves panes mid-read and the window jumps 220 pt twice per turn. | macOS | P0 | `ChatViewMac.swift:685-693`, `:762-795`, `:2564-2566` |
| 5 | Replayed Mac history is stamped with `Date()`, so a three-week-old thread claims every message arrived today. | macOS | P0 | `ChatViewMac.swift:448`, `:2894-2897` |
| 6 | No menu bar, no Settings scene, no `⌘,`.  The Mac app is an iOS window; `⌘N` and `⌘R` are bound to buttons that disappear with the sidebar. | macOS | P1 | `ClutchApp.swift:20-32`, `ThreadSidebar.swift:282,340` |
| 7 | The permission card asks for trust without evidence: no command text, no diff, no path, and "Allow always" looks identical to "Allow once". | iOS, Mac | P1 | `PermissionCard.swift:46-61`, `AcpSession.swift:105-110` |
| 8 | Auto-scroll is unconditional, so reading during a stream is impossible on both platforms; iOS also animates on every token. | iOS, Mac | P1 | `SessionThreadView.swift:639-644`, `ChatViewMac.swift:1510-1524` |
| 9 | Transcripts are raw text: no markdown, no code blocks, no syntax, and timings and JSON sit in the primary reading path. | iOS, Mac | P1 | `ChatViewMac.swift:2879-2889`, `ThreadToolCard.swift:46-52` |
| 10 | The app icon is a photographic steel-and-pink-brain illustration while the documented identity is a flat indigo wordmark; no dark or tinted variants, no Mac size set, and the launch screen is blank. | Both | P2 | `ios/Assets.xcassets/AppIcon.appiconset`, `assets/clutch-wordmark.svg`, `project.yml:83` |

Ten more P1/P2 findings — silent no-ops on send, a 10-second health check that destroys an open draft, a 200-entry transcript cap with no "load earlier", find that highlights without navigating, a developer console in a top-level tab, an unverified Return-to-send promise, index-keyed row identity that collapses open tool cards, and two host stores over one defaults key — are catalogued in the specialist appendices and belong in the same program.

## North star

> Clutch is not a window onto a log.  It is the answer to one question — **what needs me right now** — with every answer one tap from the Lock Screen.

That sentence decides the roadmap.  It justifies deleting two tabs, promoting approvals to a first-class surface, building a Lock Screen presence, and refusing a large class of requests (a diff viewer, a terminal, a browser pane) that the harness already serves better.  Every competitor is a place to *do* work.  Clutch can be the place that tells you *where you are needed*, because it is native, on your person, and connected to a machine you own.

## The design system: `ClutchTheme`

Today the entire token layer is two colours in `Platform.swift:16-32`.  Everything else is a literal: 165 fixed `.system(size:)` calls, 40 `.padding(.horizontal, 12)`, 7 corner radii, one shadow, two animation durations, and a `Color(.systemBackground)` here and there that bypasses even the two tokens.  The accent colorset exists in the asset catalog and is referenced by no build setting, so the brand indigo never renders.

Add one file, `ios/App/Design/ClutchTheme.swift`, compiled into both targets, purely additive, landing before any migration:

- **Colour** — canvas, surface, sunken surface, three text levels, accent plus wash, and four semantic status colours tuned to clear 4.5:1 on the surface colour in both appearances.  The current system green and orange measure roughly 2.0:1 on `secondarySystemBackground`, which is where the 9 pt tool status is drawn today.
- **Type** — nine semantic roles plus three monospaced sizes, all Dynamic Type aware.  The 8–13 pt fixed range maps onto them; nothing needs to stay frozen except chrome that must not grow.
- **Spacing** — a 4 pt-derived scale with named roles (`hair` 2 through `screen` 24), so 12 becomes `gutter` instead of a magic number repeated 40 times.
- **Radius** — five roles: chip, control, card, bubble, composer, sheet.  Seven values collapse to five concepts.
- **Elevation** — none, card, badge.  One shadow becomes three, used deliberately.
- **Motion** — quick, standard, stream, plus a modifier that honours Reduce Motion, which the app currently ignores at all six animation sites.
- **Status** — one enum carrying colour, symbol, and label, replacing the four divergent `switch` blocks that currently disagree about what "completed" looks like (green checkmark on one card, blue wrench on another).
- **Metrics** — 44 pt tap target modifier, rail widths, readable width, and one `clutchCard()` treatment replacing six hand-rolled variants.

Migration order, by leverage per line changed: `ThreadToolCard`, `PermissionCard`, `PlanPanel`, `ThreadSidebarRow`, `MacChatInputBar` first; then the transcript and session views; then `ChatViewMac`; delete `ToolCallCard` and `ReasoningBlockView` in the same PR that replaces their last call site.  A CI grep that rejects `cornerRadius: [0-9]` and `.system(size:` outside `ClutchTheme.swift` is what stops the drift from returning.

## iOS: the Attention Stack

Replace the tab bar with one stack, sorted by what needs the user.

```
┌──────────────────────────────────────────────┐
│  ‹ MacBook Pro ▾                    ⚙︎   👤  │
├──────────────────────────────────────────────┤
│  ⌕  Search threads, files, transcripts       │
├──────────────────────────────────────────────┤
│  NEEDS YOU                                   │
│   ⚠ auth-refactor    wants to run pnpm test  │
│   ⚠ deploy-check     wants to edit 3 files   │
│  RUNNING                                     │
│   ● login-redirect   streaming · 0:42   ■    │
│  PINNED                                      │
│   ★ payments-api     ~/Code/api              │
│  TODAY                                       │
│   pricing-page       ~/Code/web       2m     │
├──────────────────────────────────────────────┤
│      [ ＋ New thread in ~/Code/web ]         │
└──────────────────────────────────────────────┘
```

What this fixes structurally:

- Approvals cannot hide, because pending work is a section of the home screen with a count on the tab badge.
- "Workspace" and "Chat" stop being two names for one idea.  The transcript is a destination, not a tab.
- The engine becomes a chip on a row instead of a tab-wide filter with three different defaults across three surfaces.
- Host diagnostics and Fleet Recall move into settings and a global search field, where they belong, and the tab set stops mutating by host kind — a pattern Apple's own tab-bar guidance calls out as unstable.
- The folder becomes a first-class choice, remembered per host, so the second thread is one tap and the thread is resumable.

On iPad the same stack becomes the sidebar of a `NavigationSplitView` (stack → thread → inspector), and multi-scene support lets two threads sit side by side — the actual iPad use case for this product: one running, one to review.

## macOS: the Session Deck, and the transcript as a Turn Ledger

The Mac's problems are structural, not cosmetic.  One view owns the window, the sidebar is only present on one tab, the answer streams into a pane that appears and disappears, and the window title says "Workspace" instead of the thread.

Two changes, in this order:

**1. Session Deck (about a week).**  A real `NavigationSplitView`: threads on the left, transcript centre, an inspector on the right for plan, context, usage, and the pending approval.  This alone unlocks a real `.toolbar`, a sidebar toggle, `.commands`, a Settings scene, `⌘,`, and a titlebar that carries the thread name.  The model strip collapses from three rows to one status row.  Nothing appears or collapses mid-turn.

```
┌───────────┬────────────────────────────────────────┬────────────────────┐
│ Threads   │  Fix the flaky retry test              │  Turn              │
│ ⌕ filter  │  ~/Code/clutch-tools · Muse · M3.1     │  Plan        3/7   │
│ TODAY     │   You                                  │  ✓ read test       │
│ ▸ threadA │   the retry test flakes on CI          │  ✓ edit test       │
│ ▸ threadB │   Agent                                │  ▸ run suite       │
│ PROJECTS  │   The backoff timer is created before  │  Context  38%      │
│ ▸ clutch  │   the socket closes.                   │  Permission        │
│           │   🔧 read  🔧 edit  ✗ npm test         │  [Allow]    Deny   │
│           ├────────────────────────────────────────┤                    │
│           │  Message the agent…              ⌘⏎   │                    │
└───────────┴────────────────────────────────────────┴────────────────────┘
```

**2. Turn Ledger (two to three weeks).**  The transcript becomes a list of turns, not a list of messages: each turn has a header (time, prompt summary, duration, tool and file counts), a collapsed state, and a stable identity.  Streaming happens inside the turn being built, so text never moves panes.  Failures become a one-glance signal.  Find can say "turn 3, tool 5".  This deletes `MacWorkspacePanels`, the activity surface, and most of `MacChatRow`.

Both changes require the same prerequisite: extracting a `MacTranscriptModel` from the 73 stored properties in `ChatViewMac`.  Today every keystroke re-maps and re-lowercases the full history, and the view *is* the model, which is why the file cannot be split.

## Cross-platform primitives

These are shared by both apps and each one removes a whole class of inconsistency:

- **Verbosity modes** — Summary, Normal, Verbose, default Normal.  Normal collapses consecutive tool calls into one row ("5 files · 2 commands · 1 test") that expands in place.  This is the single highest-leverage transcript pattern in the 2026 benchmark and it is a rendering concern, not a protocol change.
- **Typed tool cards** — four renderers to start: file read, edit with a diff and +/− counts, shell with exit code and collapsible output, test with pass/fail and failing names.  Raw JSON moves behind "Show raw".
- **Markdown and code** — assistant prose through `AttributedString(markdown:)`, fenced code in a monospaced block with a copy button.  A coding client that shows literal triple backticks is a credibility problem, not a polish problem.
- **Approvals with evidence** — show the command, the path, or a compact diff; make Deny the default-weighted action and Allow once the primary; put "Always allow" behind a second confirm that names its scope.  On the phone, Face ID before any allow, deny always permitted, and no "Always allow" from the phone at all.  This is the rule the best native clients already ship, and it is the difference between a trust surface and a remote "yes" button for `rm -rf`.
- **A composer with two verbs** — Steer and Queue.  Stop is always available while a turn runs, and the field is never disabled.  One shared component replaces three implementations with three icon orders and two different hit-target sizes.
- **Notifications and Live Activities** — an actionable notification the moment a permission arrives (`.timeSensitive`), separate from turn completion; deep link straight to the card.  A single Live Activity rotating through up to three sessions with a "2 waiting · 1 running" summary, titles and status only, updated from the host.  Plus a Lock Screen accessory count and a Control Center action.  These are the surfaces no competitor can copy from Clutch, and they are the only reason to be native on the phone.

## Roadmap

### Phase 0 — Foundations (1–2 weeks, low risk)

1. `ClutchTheme` lands additively; `Platform.swift` points at it.
2. Migrate the six highest-reuse files: tool card, permission card, plan panel, sidebar row, Mac input bar, workspace panels.
3. Fix status contrast at the 9–10 pt sites; gate all six animations on Reduce Motion; add 44 pt targets to the thread composer and rail header.
4. Wire the accent color, rebuild the icon from the wordmark with dark and tinted variants and the full macOS size set, and replace the blank launch screen.
5. Add the CI literal check.

Acceptance: no visual regression in existing UI tests, Dynamic Type no longer clips the transcript, and a grep for design literals outside `ClutchTheme.swift` returns nothing in the migrated files.

### Phase 1 — Stop the bleeding (2–3 weeks)

6. iOS: stop/queue/steer on the Chat tab; never disable the field.
7. Both: approval notification with actions and deep link; pending count on the tab and on thread rows.
8. iOS: working-folder picker in New Thread, remembered per host; create the thread on `.started` and dismiss the sheet, deleting the modal trap.
9. iOS: replace the app-wide gate with in-place degradation so a health timeout never destroys a draft.
10. Both: conditional auto-scroll with a "jump to latest" pill; stable row ids; "load earlier" for capped transcripts.
11. macOS: delete the activity pane and stream into the transcript; stop fabricating timestamps.

Acceptance: a turn can be started on the phone, left, approved from the Lock Screen with Face ID, and reviewed without opening a tab called "Host".

### Phase 2 — The redesign (6–8 weeks)

12. iOS Attention Stack and settings absorption (2–3 weeks).
13. macOS Session Deck plus `MacTranscriptModel` extraction (1.5 weeks).
14. macOS Turn Ledger (2.5 weeks).
15. Verbosity modes, typed tool cards, markdown rendering (shared, 3 weeks, overlaps 12–14).
16. Live Activity, widgets, Handoff (2–3 weeks, needs a small push relay on the host).

Acceptance: every screen has a designed empty, loading, error, and offline state; a first-run user can create a thread in a repo without a terminal; and the Mac window title names the thread.

## Verification and guardrails

The reason these defects survived is that nothing looks at the UI.  The Mac scheme has no test action, the Mac target is compiled and never executed in CI, and the only "macOS visual test" in the repo is Playwright against the *web* model picker. iOS UI tests capture screenshots as attachments with no assertions and no export.

Before Phase 2, add a `ClutchMacUITests` target using the stub sidecar the iOS suite already has, with screenshot assertions for the workspace, transcript, composer, and permission card.  Add a golden-image test for the token layer in light and dark.  The owner never takes manual screenshots, so this is the only way the surface stays honest.

## Non-goals

A diff viewer, an integrated terminal, and an in-app browser.  Every competitor built them and every competitor reports the friction; the harness already serves them better.  The phone should route to depth, not reimplement it.  Likewise: no skeletons, gradients, or custom illustration until the type scale, contrast, and icon are right — those would only add a fourth visual language to the three already fighting.

## Appendix: specialist reports

- iOS interaction and IA: 19 findings, 3 redesign concepts, full experience map.
- macOS: 12 findings, chrome inventory, native-ness audit, 3 redesign concepts, maintainability hot spots.
- Design systems: token inventory with grep counts, consistency defects, accessibility measurements, `ClutchTheme` sketch and migration table.
- Benchmark: 9 clients, Apple's 2026 design language and the April 2027 SDK deadline, mobile patterns, 12 anti-patterns with sources.

Raw reports are held in the session that produced this document; the evidence citations above are the index.
