# Clutch UI Improvement Catalog

Date: Sun Nov 22 2026 (updated after the peer sub-thread merges)
Seat: OPENCODE
Status: Living document, companion to `docs/plans/ui-ux-overhaul.md` and `docs/plans/native-ui-capability-program.md`
Scope: every UI improvement brainstormed for the native apps, across all review and implementation sub-threads — the four-specialist review (iOS interaction and IA, macOS product design, design systems and accessibility, competitive benchmark), this seat's implementation PRs, and the parallel peer sub-threads (the AE OpenCode thread that landed the Attention Stack and Turn Cockpit in #296, and the MM thread whose program spec (#302), honest-ground pass (#303), readability pass (#304), composer pass (#305), and Mac-test follow-up (#306) are folded in below)

## How to read this

Each item carries an ID, the improvement, why it matters, the evidence, and a status.  Statuses: **Landed** (merged, with the PR), **Partial** (some of it landed, the rest queued), **Open** (agreed, not started), **Proposed** (needs a decision).  The programme now runs off `native-ui-capability-program.md` (Linear C-137) and its passes (C-138 is pass 1, honest ground); this catalogue is the complete brainstorm inventory behind both.

## A.  Structure and information architecture

- **A1 — Attention Stack home surface** (Landed on iOS, #296).  The tab bar is gone on iPhone: `SessionsView` is the one home surface with Agent Chat, Needs You, Running, Pinned, and one section per working folder, backed by a new `TurnActivity` model (`ios/App/Views/SessionsView.swift:292`, `ios/App/Models/TurnActivity.swift`).  Open: the same treatment as the Mac home surface, and deleting the residual tab logic on macOS.
- **A2 — Kill the Workspace/Chat split on iOS** (Landed, #296, for iPhone).  One list-to-thread flow.  Open: the Mac's `NavigationSplitView` equivalent (D10).
- **A3 — Repo-first grouping option** (Proposed).  Folder as the organising axis across all sections; per-folder sections exist (#296), a full folder-first alternative does not.  Needs a decision against A1.
- **A4 — Host tab becomes a status screen** (Partial, #296 touched `DshHostView`).  Full version: health, last contact, sidecar version, engine inventory, restart guidance; the raw JSON-RPC console behind a Diagnostics disclosure (`DshHostView.swift:39-56`, `isBusy` always false `:121-126`).  Status: Open.
- **A5 — Fleet Recall becomes a verb** (Open).  `@recall` in the composer and a global search field; the tab disappears into settings or search.
- **A6 — iPad multi-scene** (Open).  Two threads side by side (one running, one to review); no scene manifest today (`project.yml:84-99`).
- **A7 — State restoration** (Open).  `@SceneStorage` for tab, thread, and draft; a relaunch loses all three (`RootView.swift:9`, `SessionsView.swift:90`, `SessionThreadView.swift:51`).

## B.  Trust surfaces: approvals and permissions

- **B1 — Approval wakes the owner** (Landed, #296 — `TurnNotifier.swift:18` now fires on a permission arrival).  Open remainder: actionable Approve/Deny on the notification, `.timeSensitive` interruption level, and a deep link that opens the exact card.
- **B2 — Face ID before any allow from the phone** (Open).  Deny always permitted from the phone; no "Always allow" from the phone.  The programme doc names the tension honestly: one tap can Deny or deep-link, but an informed Allow needs the unlock and the evidence (B3) in front of the owner.
- **B3 — Approvals show evidence** (Partial, #296 — the card now carries the tool name and a queued-request count).  Open: command text, target path, or a compact diff; "Always allow" behind a confirm naming its scope; default-weighted Deny.  Evidence base: `PermissionCard.swift` reworked in #296 (+61).
- **B4 — Pending requests visible outside the thread** (Landed, #296 — Needs You section plus the queue count on the card).  Open remainder: tab-badge style surfacing on macOS.
- **B5 — Tiered approval modes** (Proposed).  Ask every time / Assisted / Approve all.  Needs sidecar support; needs a decision.

## C.  Supervision controls: stop, queue, steer

- **C1 — Stop and queue during a turn** (Landed twice, independently: #296 on the thread surface — the composer never closes and steers or queues — and #300 on the Chat tab composer: red stop cancels on the sidecar and drops the stream, typed text parks, parked text auto-sends on natural completion, a stopped turn keeps its park and takes its permission cards with it).
- **C2 — Steer** (Landed, #296 — the thread composer offers steer during a turn).  Open remainder: surface steer on the Chat tab composer the same way (#300 has stop and queue).
- **C3 — Silent no-ops become visible** (Open).  Send on a failed thread, send with no chat identity, and answering a permission before the turn started swallow the tap today (`SessionThreadView.swift:710-717`, `ChatView.swift:580`, `:559`).  #305 added turn-failure reporting — verify these three guards still hide before closing.
- **C4 — Gate degrades in place** (Open).  A 10-second health timeout must not replace the open thread and destroy its draft (`RootView.swift:136-151`, `HostGate.swift:56-77`).

## D.  Transcript and reading

- **D1 — Verbosity modes** (Open).  Summary / Normal / Verbose; Normal collapses consecutive tool calls into one row.  Rendering concern, not a protocol change.
- **D2 — Markdown and code blocks** (Open).  `AttributedString(markdown:)` for prose; fenced code in a monospaced block with copy.  Today raw text at a fixed size (`ChatViewMac.swift:2879-2889`).
- **D3 — Typed tool cards** (Open).  File read, edit-with-diff, shell with exit code, test with pass/fail; raw JSON behind Show raw.
- **D4 — Conditional auto-scroll** (Landed, #296 — follows only near the bottom, with a Latest pill).
- **D5 — Load earlier messages** (Open).  `hasMore` from the sidecar plus a Load-200-more row; today the transcript starts mid-conversation silently (`SessionsClient.swift:345-352`).
- **D6 — Find that navigates** (Open).  Match index, jump, per-character highlight, Esc, `⌘G`; search tool input and plan text (`SessionThreadView.swift:538-573`, `ChatViewMac.swift:837-850`).
- **D7 — Stop fabricating timestamps** (Partial, #304 made the visible timestamps readable — primary styling and a larger size).  The underlying bug remains: replayed Mac history is stamped `Date()`, so a three-week-old thread claims every message arrived today (`ChatViewMac.swift:429`, `:448`, `:464`).
- **D8 — Stable row identity** (Open).  Ids from tool-call ids, not array position (`ChatViewMac.swift:446`); open cards stop collapsing mid-stream.
- **D9 — Turn Cockpit** (Landed on iOS, #296 — plan panel on top of the thread, approval card in the flow, supervision in the composer; `SessionThreadView.swift:221`, `:296`).  Open: the Mac equivalent.
- **D10 — Session Deck on macOS** (Open).  Real `NavigationSplitView` (threads / transcript / inspector), unlocking a real toolbar, `.commands`, and a titlebar that names the thread.
- **D11 — Delete the Mac activity pane** (Open).  The answer streams into a 220 pt pane that appears mid-turn and teleports into the transcript at turn end (`ChatViewMac.swift:686`).
- **D12 — Readable width on iPad** (Open).  Cap transcript lines (~720 pt) instead of full-bleed.
- **D13 — New From Summary** (Proposed).  Fresh thread carrying a summary of the current one (Zed's pattern).

## E.  Composer and input

- **E1 — One shared composer** (Partial, #305 consolidated the three attach buttons into one paperclip with an Attach sheet — Choose Photo, Choose File, Paste — reclaiming composer space in `ChatView`, `SessionThreadView`, and `NewThreadSheet`).  Open: one component for order, hit targets, and stop/queue behaviour across surfaces.
- **E2 — Return-to-send honesty** (Open).  Implement Return-to-send or fix the footer that promises it; `submitLabel`, no autocorrection on prompts (`ChatView.swift:718-721`, `MacChatInputBar.swift:89-91,187`).
- **E3 — Working folder on new threads** (Landed, #296 — `RecentFolders.swift` remembers folders per host and New Thread names one before the first turn, so phone threads stop landing in `$HOME`).
- **E4 — Optimistic New Thread** (Open).  Create on `.started`, dismiss the sheet, continue in the real thread view (`SessionsView.swift:766-786`).
- **E5 — Attachments with previews** (Open).  Thumbnails, Quick Look, size (`MacChatInputBar.swift:33-58`).
- **E6 — Dictation affordances** (Open).  Listening banner on the thread surface, visible denied state (`SessionThreadView.swift:656-666`).
- **E7 — 44 pt targets everywhere** (Partial, #305 reclaimed composer space and #296 rebuilt the surfaces).  Open: the rail header buttons and any remaining ~20 pt icons (`ThreadSidebar.swift:274-341`).
- **E8 — Message-level actions** (Open).  Tap-to-copy, retry, edit-last on iOS.

## F.  Sessions and thread management

- **F1 — Thread management on the phone** (Partial, #296 rebuilt the list surface).  Open: swipe Pin/Rename/Archive and the long-press menu mirroring the Mac (`SessionsView.swift:354-364` vs `ThreadSidebar.swift:624-691`).
- **F2 — Persisted engine choice** (Partial, #304 made the picker readable — primary styling so the picked engine reads as the subject).  Open: remembering the choice per host; three hardcoded defaults remain (`SessionsView.swift:88`, `ChatView.swift:37`, `ChatViewMac.swift:164`).
- **F3 — List pagination** (Open).  Silent 100 cap (`SessionsClient.swift:77`).
- **F4 — Recency and running indicators** (Partial, #296 — Needs You and Running sections).  Open: unread dots on completed rows.
- **F5 — Rail refresh on activation** (Open).  The Mac rail never updates itself (`ChatViewMac.swift:606`, `:2062`).
- **F6 — One host store** (Open).  Two stores over one defaults key desync windows (`RootView.swift:5`, `MacThreadWindow.swift:7`).
- **F7 — Forget Host confirmation** (Open).  Destructive swipe with no confirm (`HostsSheet.swift:39-46`).
- **F8 — Live host health** (Open).  Re-probe on failure, activation, timer; grey when unknown (`ChatViewMac.swift:1408-1419`).

## G.  Mac platform-native

- **G1 — Menu bar, Settings scene, `⌘,`** (Open).  No `.commands`, no `Settings` scene today; `⌘N`/`⌘R` bound to buttons that disappear (`ClutchApp.swift:20-32`, `ThreadSidebar.swift:282,340`).  Named unchanged by #296 and still true after #303.
- **G2 — Shortcuts out of view-bound buttons** (Open).  Same evidence as G1.
- **G3 — `MacTranscriptModel` extraction** (Open).  The 3,050-line view owns 73 state properties, an HTTP client, and persistence, and re-derives history per keystroke (`ChatViewMac.swift:155-274`).
- **G4 — Unify the six error surfaces** (Open).
- **G5 — Quick Look, drag-out, Services** (Open).
- **G6 — Window defaults and restoration** (Open).  No default size; rail visibility and tab selection unpersisted.
- **G7 — Delete the dead dock-app AppKit** (Open).  1,252 lines of `ClutchWindow.swift` still cited as live in `AGENTS.md` and `docs/engine-plugins.md`.
- **G8 — Liquid Glass pass, mostly deletion** (Open).  Custom backgrounds off the bars; glass only where it earns its place; current SDK mandatory for App Store by April 2027.

## H.  Ambient surfaces

- **H1 — Live Activity: Agent Radar** (Open).  "2 waiting · 1 running", three sessions max, titles and status only, host-driven updates; the programme doc carries the honest tension (one tap can Deny or deep-link, never informed-Allow).  Needs a small push relay.
- **H2 — Widgets and Lock Screen accessories** (Open).  Needs-you count and top waiting thread.
- **H3 — Control Center action** (Open).  Approve-pending / start-session.
- **H4 — Handoff and send-to-phone** (Open).  `NSUserActivity` on the open thread; Mac menu push.
- **H5 — Share extension** (Open).  URL or file becomes a new turn.
- **H6 — StandBy attention board** (Open).  The home surface as a desk board.

## I.  Accessibility

- **I1 — Dynamic Type** (Partial).  Migrated files are semantic (#294); the ratchet from #303 stops new literals.  Open: the remaining allowlisted call sites.
- **I2 — Status contrast** (Partial).  Tuned tokens landed on tool card, plan panel, permission card (#294); host picker and hosts sheet remain.
- **I3 — Reduce Motion everywhere** (Partial).  Gated on migrated surfaces (#294); remaining sites Open.
- **I4 — VoiceOver fixes** (Partial).  Tool-card labels name tool and status (#298); #303 made accessibility honest per its title.  Open: bubble role labels, host-picker status speech.
- **I5 — Colour-only status removed** (Open).  `HostSwitcher.swift:64-70`, `ChatViewMac.swift:1166-1168`.
- **I6 — Haptics** (Open).  Send, stop, permission arrival, turn complete, thread select.
- **I7 — Focus rings for plain buttons** (Open).  34 `.buttonStyle(.plain)` sites.

## J.  Design system

- **J1 — `ClutchTheme` token layer** (Landed, #294).
- **J2 — Migrate the remaining high-reuse files** (Partial).  Tool card, permission card, plan panel done (#294); #296's reworked surfaces carry tokens where they touched.  Open: sidebar row, session and transcript views, `ChatViewMac` last.
- **J3 — CI literal ratchet** (Landed, #303 — `tests/design-literal-guard.test.ts` fails on new `.system(size:)` / `cornerRadius:` literals outside `ClutchTheme.swift` and on stale allowlist entries).
- **J4 — Delete the dead components** (Open).  `ToolCallCard` and `ReasoningBlockView` compile into iOS, referenced nowhere.
- **J5 — One card, one chip, one radius** (Open).  `clutchCard()` replaces six hand-rolled variants.
- **J6 — CometChat theme override** (Open).  Stock CometChat palette on the Chat surface (`AgentMessagesVC.swift:62`).
- **J7 — Loading skeletons** (Open).  29 spinners, 0 skeletons.
- **J8 — One empty-state and header treatment** (Open).

## K.  Brand, launch, app icon

- **K1 — Icon from the wordmark** (Open).  Dark and tinted variants, full macOS size set.
- **K2 — Wire the accent colour** (Open).  The catalog colour is referenced by no build setting.
- **K3 — Real launch screen** (Open).  Blank white flash for dark-mode users today (`project.yml:83`).
- **K4 — Screenshot pipeline** (Open).  Specified folders empty; captures without assertions.

## L.  Verification guardrails

- **L1 — Mac UI test target** (Landed first pass, #303 — a Mac UI test exists with honest ground; #306 is OPEN making it reach the Mac surface and land, and is the one open peer PR).
- **L2 — Golden-image tests for the token layer** (Open).
- **L3 — `MacTranscriptModel`** — see G3.

## M.  Reliability surfaces the peer threads added

- **M1 — Turn failures reported in the surface** (Landed, #305 — the composer reports a failed turn instead of dropping it silently).
- **M2 — Rate limits named** (Landed, #305 — limit responses name themselves instead of reading as generic errors).
- **M3 — Turn activity as a model** (Landed, #296 — `TurnActivity.swift` drives Needs You and Running without per-view re-derivation).
- **M4 — Folder-scoped Files browsing from the home surface** (Landed, #296 — `FilesView` and `FilesClient` gained folder browse, with tests).

## Non-goals (decided)

A diff viewer, an integrated terminal, an in-app browser, custom illustration, gradients, and skeletons-before-tokens.  The engines already serve depth better; the phone routes to it.

## Where to go next

The live sequencing belongs to `native-ui-capability-program.md` (C-137) and its pass documents; this catalogue is the inventory behind it.  The biggest open clusters, by impact: the Mac structural fixes (D7, D11, G1-G3 — the Mac is untouched by #296), the approval-evidence remainder (B3), ambient surfaces (H1-H4), and the accessibility remainders (I1-I5).  One peer PR is open: #306, the Mac UI test reaching the Mac surface.
