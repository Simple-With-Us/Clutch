# Clutch Native UI/UX And Capability Program - Three Sequenced Passes

Date: Sun Nov 22 2026
Seat: MM
Status: Proposal, owner-directed on Nov 22 2026
Linear: C-137
Lane: `~/apps/lanes/Clutch/minimax-ui-ux-power`, branch `minimax/ui-ux-power`
Scope: `ios/App` (iPhone, iPad), `ios/Mac` (macOS), the shared views both targets compile, and the sidecar contract in `src/web/chat-bridge.ts` where a change must reach both apps

## Purpose

The owner asked for the native Mac and iOS apps to get better UI/UX, more features, and to be more efficient and capable.  This document is the program that answers that, in three passes.

The design vocabulary is already fixed.  `docs/plans/ui-ux-overhaul.md` is the source review, the north star, and the roadmap; this document does not replace it.  It narrows that roadmap to what is actually left, sequences it so each pass makes the next one verifiable, and gives each pass acceptance criteria.

The north star from that document stands:

> Clutch is not a window onto a log.  It is the answer to one question - what needs me right now - with every answer one tap from the Lock Screen.

That sentence carries one tension this program has to live inside, and it is worth naming before it becomes a surprise.  One tap from the Lock Screen can be a Deny, or it can be a deep link into the app.  It cannot be an informed Allow, because an informed allow needs the command, the path or the diff in front of the owner, and the Lock Screen is the wrong place for that.  The answer is one tap away; the signature takes an unlock and two more.

## The inventory behind the program

The programme is the sequencing; the catalogue is the inventory.  `docs/plans/ui-improvements-catalog.md` is the OpenCode seat's living document (PR #307), and it carries every improvement brainstormed for the native apps across the four-specialist review, the peer sub-threads and the passes that have landed.  It is where an idea goes when it is real, and this document is where it goes when it is scheduled.

The mapping is mostly settled, and it is worth writing down so two seats do not build the same thing twice:

| Pass | Catalogue items |
|---|---|
| Pass 1, honest ground | L1 (the Mac UI test target), J3 (the CI literal ratchet), and the accessibility remainder I1 to I4 that the ratchet makes visible |
| Pass 2, Mac parity and a readable transcript | G3 (`MacTranscriptModel`), D11 (the activity pane), D7 (the fabricated timestamps), D10 (the Session Deck), D9 on the Mac (the Turn Cockpit), D1, D2 and D3 (verbosity, markdown, typed tool cards) |
| Pass 3, the phone as the attention surface | B2 and B3 (the unlock before an allow, and the evidence an approval shows), B1 remainder (the actionable notification), H1 to H3 (the Live Activity, the Lock Screen accessory, the Control Center action) |

The catalogue names items that no pass owns yet, and the programme should not quietly absorb them:  G1 and G2 (the menu bar, the `Settings` scene, `⌘,` and shortcuts that are not bound to buttons that disappear), D12 (a readable transcript width on iPad), D13 (a new thread from a summary), E2 (return-to-send honesty), F5 (the Mac rail refreshes itself) and F6 (one host store rather than two over one defaults key).  F6 is half-answered by the host store change in this branch: both stores now resolve the same preferences, but they are still two stores.

The catalogue also says plainly where the weight is:  the Mac structural fixes, the approval-evidence remainder, the ambient surfaces and the accessibility remainder.  The first of those is Pass 2, which is the reason Pass 2 exists.

## Where the app stands today

Measured in this lane against base `126342b`, not assumed.

**Landed on Nov 22 in PR #296.** The iOS app got the Attention Stack home surface (Agent Chat, Needs You, Running, Pinned, then one section per working folder) in `ios/App/Views/SessionsView.swift:292`.  The Turn Cockpit landed with the plan panel on top, an approval card carrying the tool name and a queued-request count, conditional auto-scroll with a Latest pill, and a composer that never closes but steers or queues (`ios/App/Views/SessionThreadView.swift:221`, `:296`).  New Thread names a working folder before the first turn and remembers it per host (`ios/App/Models/RecentFolders.swift`).  An approval now wakes the owner (`ios/App/Services/TurnNotifier.swift:18`).

**Not touched by that PR.**  The macOS app is unchanged.  `ios/Mac/ChatViewMac.swift` is 3,050 lines and one view still owns the whole window.  The agent's answer streams into a separate activity pane and then teleports into the transcript at turn end (`ios/Mac/ChatViewMac.swift:686`, rendering `MacWorkspacePanels(responseText: streamingText)`).  Replayed history is stamped with `Date()` (`ios/Mac/ChatViewMac.swift:429`, `:448`, `:464`), so a three-week-old thread claims every message arrived today.  There is no `.commands` block, no Settings scene, no menu bar and no `⌘,`; the only shortcuts are ad-hoc `.keyboardShortcut` calls, and `⌘N` and `⌘R` are bound to sidebar buttons that disappear with the sidebar (`ios/App/Views/ThreadSidebar.swift:282`, `:340`).

**Verification is thin on both platforms.**  The `macos` job in `.github/workflows/ci.yml` compiles the Mac target and never runs it.  The iOS job runs `scripts/ios-ui-tests.sh` and `scripts/ios-unit-tests.sh`, and the UI result bundle is published as the `ios-ui-screenshots` artifact.  But nothing compares a screenshot to a baseline, so a visual regression does not fail the build; it has to be noticed by a human opening the artifact.  And the script runs one test class of the three in the target, because `scripts/ios-ui-tests.sh` filters on `-only-testing:ClutchUITests/ClutchThreadSurfaceUITests`, so `ClutchChatTabUITests` and `ClutchLiveUITests` never execute in CI at all.

**Foundations are half landed.**  `ios/App/Design/ClutchTheme.swift` is a real 309-line token layer with colour, type, spacing, radius, elevation, motion and status roles.  Three files consume it: `ThreadToolCard.swift`, `PlanPanel.swift` and `PermissionCard.swift`.  Everything else still carries its own literals: 165 `.system(size:)` calls and 28 literal `cornerRadius:` values across `ios/App` and `ios/Mac`, zero `@ScaledMetric`, zero Reduce Motion checks at the animation sites, and zero markdown rendering.

**No capability work has started.**  There are no typed tool cards, no diffs, no exit codes, no verbosity modes and no Live Activity.

**A landed redaction that Pass 3 must not widen.**  The automated review of PR #296 flagged that the permission notification may expose request details on a locked screen.  The shipped code answers it: `TurnNotifier.permissionRequest` takes only a thread title, and its comment states that the request text can carry tool commands and paths, so it stays behind the tap and the lock screen gets the thread's name only (`ios/App/Services/TurnNotifier.swift:16-19`).  That redaction is the baseline this program inherits.  Nothing in the repo stops a later change from widening that payload, so Pass 3 treats it as a line that has to be defended rather than a defect to repair.

**One finding changes Pass 3's scope.**  The ACP `session/request_permission` params carry the tool's real input in `toolCall.rawInput` - the command for a shell tool, the path and old and new text for an edit.  The sidecar throws it away.  `PermissionParamsSchema` in `src/web/chat-bridge.ts:1284` keeps only `toolCallId`, `title` and `kind`, and the `PermissionRequest` interface it produces (`:1264`) has no field for the tool input.  The apps therefore render a headline and a tool name (`ios/App/Views/PermissionCard.swift:56`) and never the command, the path or the diff.  The evidence is available upstream and discarded at the boundary, so Pass 3 is not an app-only change.

## Non-goals

These are out of scope for all three passes.

- **The app icon and launch screen.**  AGENTS.md forbids generating, flattening, cropping or substituting icon art; only the owner or their assigned seat supplies it.  The overhaul plan's item on rebuilding the icon from the wordmark stays parked until the owner provides art.
- **A diff viewer, an integrated terminal, and an in-app browser.**  The engines already serve those better.  The phone routes to depth rather than reimplementing it.
- **Skeletons, gradients and custom illustration.**  The type scale, contrast and icon have to be right before a fourth visual language is added.
- **Rewriting the iOS Attention Stack.**  It landed today and is not being re-litigated in this program.
- **Touching `/Users/jay/Code/Clutch`.**  Every change happens in a lane.

## Pass 1 - Honest ground

Foundation and verification first.  The reason these defects survived is that nothing looks at the UI, so the first pass makes the surface observable and stops new drift.  Every later pass then lands on a surface that can be checked.

### 1.1 A macOS UI test target

A `ClutchMacUITests` target, driven by the stub sidecar the iOS suite already uses, with screenshot assertions for the workspace, the transcript, the composer and the permission card.

- The Mac scheme gains a test action and the `macos` job in `.github/workflows/ci.yml` runs it instead of only building.
- Screenshot assertions cover light and dark, because the token layer is appearance-aware and a token that only works in one is not a token.
- This target is what makes Pass 2 reviewable.  A 3,050-line restructure with no visual assertions is exactly how the current defects got in.

### 1.2 iOS UI tests become assertive

The screenshot attachments are published as an artifact, but nothing compares them to a baseline, so a visual regression is a thing a human notices rather than a thing the build catches.  Two changes fix that.  A snapshot helper in the test target compares the current screenshot against a checked-in baseline with a pixel tolerance and fails with a diff image attached.  And the script stops filtering down to one class, so `ClutchChatTabUITests` and `ClutchLiveUITests` run in CI as well; a class that cannot pass in CI needs a reason to exist, not a silent skip.

### 1.3 Accessibility that actually lands

- Dynamic Type in the transcript and the tool cards.  The transcript is where the app is read, and a fixed 8-13 pt range clips there first.  `@ScaledMetric` is the mechanism, and no file uses it today.
- Reduce Motion honoured at every animation site.  The app currently ignores it at all six.
- 44 pt tap targets on the thread composer and the rail header.
- Status contrast at the 9-10 pt sites.  The current system green and orange measure roughly 2.0:1 on `secondarySystemBackground`, where the tool status is drawn.  `ClutchTheme` already carries semantic status colours tuned past 4.5:1; this is the migration of the sites that still use the raw ones.

### 1.4 A CI check that stops the drift

A test that rejects new design literals: `.system(size:` and `cornerRadius:` with a numeric argument, outside `ios/App/Design/ClutchTheme.swift`.

The remaining files are not migrated in one sweep.  They migrate when Pass 2 and Pass 3 touch them, which keeps the diff reviewable and keeps a large cosmetic change from masking a behavioural one.  The CI check is what makes that policy enforceable instead of aspirational.

### Acceptance

- CI runs the macOS target's tests and they fail when the Mac surface regresses.
- Every iOS UI test class runs in CI, and a screenshot that differs from its checked-in baseline fails the build with a diff image attached.
- The transcript and tool cards respect Dynamic Type up to the accessibility sizes without clipping.
- Every animation site respects Reduce Motion.
- The 9-10 pt status sites clear 4.5:1 in both appearances.
- A grep for new design literals outside `ClutchTheme.swift` returns nothing.
- `npm run typecheck && npm test` green, plus the iOS unit and UI scripts.

## Pass 2 - Mac parity and a readable transcript

The Mac gets the structure the iOS got today, and both apps get a transcript that can be read.

### 2.1 Extract `MacTranscriptModel`

The prerequisite.  `ChatViewMac.swift` holds 73 stored properties and the view is the model, which is why the file cannot be split.  Extract the transcript state into its own `@Observable` model so the view renders and the model holds.

Before the extraction, measure the streaming re-render cost.  The lesson from BF-2612 is that a body that re-executes every frame is a hypothesis, not a finding, and that the fix is not where the frame goes.  Measure, record the numbers in the PR, then refactor against them.

### 2.2 Stop the pane teleporting

- Delete the separate activity pane.  The answer streams inside the transcript, in the turn being built, so text never moves panes and the window stops jumping 220 pt twice per turn.
- Stop stamping replayed history with `Date()`.  Replayed messages carry the timestamp the engine recorded.  A thread that cannot show a real time cannot be trusted about anything else it shows.

### 2.3 The Session Deck

A real `NavigationSplitView`: threads on the left, transcript in the centre, an inspector on the right for plan, context, usage and the pending approval.

This unlocks the macOS chrome that does not exist today:

- A real `.toolbar` and a sidebar toggle.
- `.commands`, a Settings scene and `⌘,`.
- A titlebar that carries the thread name instead of the word Workspace.
- `⌘N` and `⌘R` that are real commands, not sidebar buttons that vanish with the sidebar.
- The model strip collapses from three rows to one status row, and nothing appears or collapses mid-turn.

### 2.4 The Turn Ledger

The transcript becomes a list of turns, not a list of messages.  Each turn has a header with the time, the prompt summary, the duration and the tool and file counts, a collapsed state, and a stable identity.  Find can then say "turn 3, tool 5" instead of highlighting a string and hoping.

This deletes `MacWorkspacePanels` and most of `MacChatRow`.

### 2.5 Shared capability: markdown and typed tool cards

These are shared, so both apps get them at once.

- **Markdown.**  Assistant prose through `AttributedString(markdown:)`, fenced code in a monospaced block with a copy button.  A coding client that renders literal triple backticks is a credibility problem, not a polish problem.  There are zero markdown call sites today.
- **Typed tool cards.**  Four renderers to start: file read; edit with a diff and `+`/`-` counts; shell with the exit code and collapsible output; test with pass and fail and the failing names.  Raw JSON moves behind "Show raw".  The current card shows a title and a tool name and nothing else.
- **Verbosity modes.**  Summary, Normal, Verbose, default Normal.  Normal collapses consecutive tool calls into one row - "5 files, 2 commands, 1 test" - that expands in place.  This is the single highest-leverage transcript pattern in the 2026 benchmark and it is a rendering concern, not a protocol change.

### Acceptance

- The answer never changes panes mid-turn, and the window does not resize mid-turn.
- A replayed thread shows the real times of its messages.
- The Mac window title is the thread name.
- `⌘,` opens Settings, `⌘N` opens a new thread, and both work with the sidebar hidden.
- A diff renders in the transcript with `+` and `-` counts.
- Assistant prose renders as markdown and a fenced block copies as code.
- Verbose mode shows every tool call; Normal collapses consecutive ones; Summary shows counts.
- The macOS UI test target's screenshot assertions pass, and they fail against the old shell.

## Pass 3 - The phone as the attention surface

The reason to be native on the phone.  The engine is on the Mac, the phone is on the owner, and this pass makes the phone worth carrying.

### 3.1 Carry the evidence to the client

The blocker, and the change that makes the rest possible.

- `src/web/chat-bridge.ts`: widen `PermissionParamsSchema` to keep the tool's real input, and add the field to `PermissionRequest`.  The payload is untrusted and stays validated; the schema drops what it does not recognise, so this has to be an explicit allow of a known shape rather than a passthrough.
- `ios/App/Models/AcpSession.swift`: decode it.
- `src/shared/dshHostContract.ts` and the native clients, if the wire contract names the field.

What reaches the client is the command for a shell tool, the path for a file tool, and a compact diff for an edit.  Nothing larger than that crosses the wire.

### 3.2 Approvals that show their work

- Show the command, the path or the compact diff.  An approval the owner cannot read is not an approval.
- Deny is the default-weighted action and Allow once is primary.  "Always allow" sits behind a second confirm that names the scope it is granting.
- On the phone: Face ID or Touch ID before any allow.  Deny is always permitted and never gated.  There is no "Always allow" from the phone at all.

This is the difference between a trust surface and a remote yes button for `rm -rf`.

### 3.3 Notification with actions and a deep link

`TurnNotifier` already wakes the owner when a permission arrives.  Pass 3 extends it with a time-sensitive notification that carries actions, and a deep link straight to the card.

Two rules govern that extension, and both come from the landed redaction rather than from taste.

- **The locked payload stays as it is.**  The lock screen keeps the thread name and nothing else.  The tool name, the command, the path and the diff never reach it.  Widening the locked payload to show the tool name is an explicit owner decision, proposed as a delta with the exposure it adds stated, not a default this program picks.
- **A locked device may deny, and may only open the app.**  The notification's actions are Deny and a deep link into the app.  Allow is not on the locked screen at all, because an allow nobody can read is an allow nobody informed.  Approving from a Lock Screen without the command, the path or the diff on it would make Face ID a signature on a blank page, and that is the exact failure the evidence rule in 3.2 exists to prevent.  The owner unlocks, sees the evidence, and allows there.

The redaction is a constraint on the payload rather than a setting on the notification, so it holds for the notification action labels too and not only for the body.

### 3.4 Live Activity, Lock Screen and Control Center

- A Live Activity rotating through up to three sessions, with a "2 waiting, 1 running" summary, thread titles and status only, and no tool names and no request text, under the same redaction the notification follows.
- A Lock Screen accessory count.
- A Control Center action.
- A small push relay on the host, so the phone can be reached when the app is not running.  This is the one piece of real infrastructure in the program and it is the main schedule risk.

### Acceptance

- An approval shows the command or the path or the diff.  A shell approval shows the command.
- On the phone, an allow requires Face ID or Touch ID, and a deny never does.
- There is no "Always allow" on the phone.
- A permission arriving while the app is backgrounded produces a time-sensitive notification that can deny the request or open the app to answer it.
- A locked screen shows the thread name and nothing else, and never the command, the path, the diff or the tool name.
- The locked notification offers Deny and an open-app action.  It does not offer Allow.
- An allow requires the app to be open, unlocked, and showing the command, the path or the diff.
- The Live Activity shows up to three sessions and a waiting count.
- The whole loop is walkable on a real phone: start a turn on the Mac, see the approval on the Lock Screen, deep link into the app, unlock, read the command or the diff, allow it with Face ID, and read the result.  The Lock Screen alone can deny.

## Sequencing rationale

Foundation before structure, structure before capability.

Pass 1 comes first because the Mac target has never been executed in CI, and Pass 2 is a large restructure of a 3,050-line view.  Doing that with no visual assertions would repeat the failure mode this whole program exists to fix.  Pass 1 also makes the token drift enforceable, so Pass 2 and Pass 3 migrate the files they touch instead of sweeping the tree at the end.

Pass 2 comes before Pass 3 because the approval evidence is now discarded at the sidecar.  Fixing that before the Mac transcript can render typed tool cards would mean carrying a richer payload into two transcript renderers that do not yet exist.  Doing the transcript first means the evidence lands in a renderer that can show it.

Pass 3 is last because it is the only pass with infrastructure risk.  It should ride on a stable transcript, and it should be the pass that can be deferred without leaving the app half-built.

## Verification strategy

- Every pass runs `npm run typecheck && npm test` before the PR, plus the iOS scripts the pass touches: `scripts/build-ios.sh --simulator`, `scripts/ios-unit-tests.sh`, `scripts/ios-ui-tests.sh`, and the Mac build and test the pass adds.
- The macOS UI test target is the gate for Pass 2 and it is created in Pass 1.
- `ios/project.yml` is the source of truth for the Xcode project.  New Swift files are added there and the project is regenerated, never hand-edited in `project.pbxproj`.  This is the fix recorded in C-127.
- A UI change without a verification path is not done.  The owner never takes manual screenshots, so the automated check is the only way the surface stays honest.

## Ground rules

- Work happens in `~/apps/lanes/Clutch/minimax-ui-ux-power` on `minimax/ui-ux-power`.  Never in `/Users/jay/Code/Clutch` and never in another seat's lane.
- The seat identity is MM.  Posts carry the MM header and the `claimed:MM` board label.
- GitHub work goes through Fleet Tools/simple-git (`gr_*`) through ST-MCP with your own seat identity for every GitHub operation.  If an operation is missing or refused, stop that operation and record the exact verb, seat, error or refusal, and proof in the [Fleet Tool Deficiencies log](https://linear.app/simple-with-us/document/gr-fleet-tool-deficiencies-gh-fallback-log-4735fb0d5d01).  If the outcome is unknown, read back the exact target before retrying.  Do not use `gh`, the owner's login, or another seat as a fallback.
- Linear issue C-137 is the umbrella.  Each pass gets its own issue, its own branch, its own PR and its own review gate.
- Commit messages, PR bodies and Zulip posts carry the sentence gap, and the copy rules in `FLEET-UI-COPY.md` apply to every user-visible string.
- Measure before refactoring the streaming path.

## Risks

| Risk | Pass | Mitigation |
|---|---|---|
| The Mac restructure is larger than it looks | 2 | The model extraction is its own commit, and the screenshot assertions gate the rest |
| The approval payload grows the wire contract | 3 | The schema keeps a known shape and stays validated; only a compact summary crosses |
| The push relay does not land | 3 | The Live Activity and the notification deep link are worth having without it; the relay is the last slice, not the first |
| The theme migration never completes | 1, 2 | The CI check makes new drift impossible and the remaining files migrate as later passes touch them |
| A pass grows too wide to review | all | One pass is one PR; a pass that grows past its acceptance criteria is split |

## Open questions for the owner

1. **The push relay.**  Pass 3 wants the phone reachable when the app is not running.  That needs a small relay on the host.  Is a relay acceptable, or should the phone reach the host the way the app already does, over the tailnet?
2. **Face ID on the Mac too.**  Pass 3 puts Touch ID in front of an allow on the phone.  The Mac already has the owner at the keyboard.  Should the Mac gate allows the same way, or stay ungated?
3. **The locked-screen payload.**  The lock screen shows the thread name today and Pass 3 keeps it that way.  Showing the tool name as well would tell a passerby that a shell command is waiting, without showing the command.  Is that worth the exposure, or does the thread name alone stay?
4. **The icon.**  The overhaul plan wants the icon rebuilt from the wordmark with dark and tinted variants and the full macOS size set.  AGENTS.md puts that art with the owner.  Is there art, or does the program ship with the current icon?
