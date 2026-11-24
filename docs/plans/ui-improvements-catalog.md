# Clutch UI Improvement Catalog

Date: Mon Nov 23 2026 (updated after pass 2 and the first slice of pass 3 landed)
Seat: OPENCODE
Status: Living document, companion to `docs/plans/ui-ux-overhaul.md` and `docs/plans/native-ui-capability-program.md`
Scope: every UI improvement brainstormed for the native apps, across all review and implementation sub-threads — the four-specialist review (iOS interaction and IA, macOS product design, design systems and accessibility, competitive benchmark), this seat's implementation PRs, and the parallel peer sub-threads (the AE OpenCode thread that landed the Attention Stack and Turn Cockpit in #296, and the MM thread whose program spec (#302), honest-ground pass (#303), readability pass (#304), composer pass (#305), and Mac-test follow-up (#306) are folded in below)

## How to read this

Each item carries an ID, the improvement, why it matters, the evidence, and a status.  Statuses: **Landed** (merged, with the PR), **Partial** (some of it landed, the rest queued), **Open** (agreed, not started), **Proposed** (needs a decision).  The programme now runs off `native-ui-capability-program.md` (Linear C-137) and its passes (C-138 is pass 1, honest ground); this catalogue is the complete brainstorm inventory behind both.

## A.  Structure and information architecture

- **A1 — Attention Stack home surface** (Landed on iOS, #296).  The tab bar is gone on iPhone: `SessionsView` is the one home surface with Agent Chat, Needs You, Running, Pinned, and one section per working folder, backed by a new `TurnActivity` model (`ios/App/Views/SessionsView.swift:292`, `ios/App/Models/TurnActivity.swift`).  Open: the same treatment as the Mac home surface, and deleting the residual tab logic on macOS.
- **A2 — Kill the Workspace/Chat split on iOS** (Landed, #296, for iPhone).  One list-to-thread flow.  Landed on the Mac in #309:  the rail is a resizable column and the panel on the right is the real macOS inspector, and the programme document records that deviation on purpose (D10).
- **A3 — Repo-first grouping option** (Proposed).  Folder as the organising axis across all sections; per-folder sections exist (#296), a full folder-first alternative does not.  Needs a decision against A1.
- **A4 — Host tab becomes a status screen** (Partial, #296 touched `DshHostView`).  Full version: health, last contact, sidecar version, engine inventory, restart guidance; the raw JSON-RPC console behind a Diagnostics disclosure (`DshHostView.swift:39-56`, `isBusy` always false `:121-126`).  Status: Open.
- **A5 — Fleet Recall becomes a verb** (Open).  `@recall` in the composer and a global search field; the tab disappears into settings or search.
- **A6 — iPad multi-scene** (Open).  Two threads side by side (one running, one to review); no scene manifest today (`project.yml:84-99`).
- **A7 — State restoration** (Open).  `@SceneStorage` for tab, thread, and draft; a relaunch loses all three (`RootView.swift:9`, `SessionsView.swift:90`, `SessionThreadView.swift:51`).

## B.  Trust surfaces: approvals and permissions

- **B1 — Approval wakes the owner** (Landed, #296 — `TurnNotifier.swift:18` now fires on a permission arrival; #316 gives the notification its actions and its deep link).  The notification is time-sensitive and carries one action, Deny, and no Allow:  the lock screen cannot show the command, the path or the diff an informed allow needs, so the owner unlocks, reads the evidence and allows there.  Its payload holds four identifiers and no request detail, so the lock screen shows the thread’s name only.  The tap opens the exact card through a `clutch://thread/<session id>?host=<host id>` link.  What is left is the host push relay, which is what would let the phone be reached when the app is not running.
- **B2 — Face ID before any allow from the phone** (Landed, #312 — the phone asks for the owner’s face or finger before an allow goes out, and a deny is never gated).  Deny always permitted from the phone; no "Always allow" from the phone, and the option the phone leaves to the Mac is named read-only with the reason rather than dropped without a word.  The gate is default-deny: every option but a known refusal waits for the owner, so a kind the build has never seen cannot go through unchecked, and the answer names the request it belongs to, so an allow for a request that turned over while the owner was confirming it is dropped rather than sent to whatever replaced it.  The programme doc names the tension honestly: one tap can Deny or deep-link, but an informed Allow needs the unlock and the evidence (B3) in front of the owner.
- **B3 — Approvals show evidence** (Landed for the evidence, #310 — the sidecar keeps the tool's own input in a known shape and the request carries the command, the path and a compact diff of the lines that change, and the phone and the Mac show them).  Open: "Always allow" behind a confirm naming its scope, and the default-weighted Deny.
- **B4 — Pending requests visible outside the thread** (Landed, #296 — Needs You section plus the queue count on the card).  Open remainder: tab-badge style surfacing on macOS.
- **B5 — Tiered approval modes** (Proposed).  Ask every time / Assisted / Approve all.  Needs sidecar support; needs a decision.

## C.  Supervision controls: stop, queue, steer

- **C1 — Stop and queue during a turn** (Landed twice, independently: #296 on the thread surface — the composer never closes and steers or queues — and #300 on the Chat tab composer: red stop cancels on the sidecar and drops the stream, typed text parks, parked text auto-sends on natural completion, a stopped turn keeps its park and takes its permission cards with it).
- **C2 — Steer** (Landed, #296 — the thread composer offers steer during a turn).  Open remainder: surface steer on the Chat tab composer the same way (#300 has stop and queue).
- **C3 — Silent no-ops become visible** (Open).  Send on a failed thread, send with no chat identity, and answering a permission before the turn started swallow the tap today (`SessionThreadView.swift:710-717`, `ChatView.swift:580`, `:559`).  #305 added turn-failure reporting — verify these three guards still hide before closing.
- **C4 — Gate degrades in place** (Open).  A 10-second health timeout must not replace the open thread and destroy its draft (`RootView.swift:136-151`, `HostGate.swift:56-77`).

## D.  Transcript and reading

- **D1 — Verbosity modes** (Landed, #309).  Summary / Normal / Verbose; Normal collapses a run of tool calls into one row that carries the calls it stands for and opens in place to show them.  The transcript model decides it, and the tests say what the reader is told.
- **D2 — Markdown and code blocks** (Landed, #309).  The inline syntax is read, and a fenced block is drawn as code in a monospaced block with a copy button.  The prose of a thread no longer arrives as raw text.
- **D3 — Typed tool cards** (Landed, #309).  File read, edit-with-diff, shell with exit code, test with pass/fail; the raw call and the raw answer behind Show raw.  Nothing is invented:  a call whose answer names no exit code has no exit code on its card.
- **D4 — Conditional auto-scroll** (Landed, #296 — follows only near the bottom, with a Latest pill).
- **D5 — Load earlier messages** (Open).  `hasMore` from the sidecar plus a Load-200-more row; today the transcript starts mid-conversation silently (`SessionsClient.swift:345-352`).
- **D6 — Find that navigates** (Open).  Match index, jump, per-character highlight, Esc, `⌘G`; search tool input and plan text (`SessionThreadView.swift:538-573`, `ChatViewMac.swift:837-850`).
- **D7 — Stop fabricating timestamps** (Landed, #309).  A replayed row carries the time the engine recorded, and a row with no recorded time carries none, because a three week old thread must not claim to have happened today.  #304 had made the visible timestamps readable.
- **D8 — Stable row identity** (Landed, #309).  A turn's identity comes from its first row and not from its number, so a turn keeps its identity when earlier history loads and the numbering moves under it.
- **D9 — Turn Cockpit** (Landed on iOS, #296 — plan panel on top of the thread, approval card in the flow, supervision in the composer; `SessionThreadView.swift:221`, `:296`).  Open: the Mac equivalent.
- **D10 — Session Deck on macOS** (Landed in substance, #309, with one deviation on purpose).  The threads rail, the transcript and the inspector are on screen, with a real toolbar, real `.commands`, and a titlebar that names the thread.  The rail is a resizable column with a drag handle and a saved width rather than a `NavigationSplitView`, because the rail has its own acceptance criteria, and the programme document records that.
- **D11 — Delete the Mac activity pane** (Landed, #309).  The answer streams inside the transcript, in the turn being built, so the text never moves panes and the window stops jumping twice per turn.
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

- **G1 — Menu bar, Settings scene, `⌘,`** (Landed, #309).  The menu bar carries New Thread and Refresh Thread, the comma key opens Settings, and the commands follow the window in front when two thread windows are open.
- **G2 — Shortcuts out of view-bound buttons** (Landed, #309).  The shortcuts are commands on the window rather than buttons that come and go.
- **G3 — `MacTranscriptModel` extraction** (Landed, #309).  The model derives the rows in `ios/App/Models`, where the phone's unit test target can reach it, and twenty-four tests say what the reader is told.  The derivation is linear:  the parent map and the turn headers are each built once.
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

- **L1 — Mac UI test target** (Landed, #303 and #306).  The Mac UI test target runs on the hosted runner against the synthetic stub sidecar, and it is behavioural rather than a picture comparison.
- **L2 — Golden-image tests for the token layer** (Open).
- **L3 — `MacTranscriptModel`** — landed with G3 in #309.

## M.  Reliability surfaces the peer threads added

- **M1 — Turn failures reported in the surface** (Landed, #305 — the composer reports a failed turn instead of dropping it silently).
- **M2 — Rate limits named** (Landed, #305 — limit responses name themselves instead of reading as generic errors).
- **M3 — Turn activity as a model** (Landed, #296 — `TurnActivity.swift` drives Needs You and Running without per-view re-derivation).
- **M4 — Folder-scoped Files browsing from the home surface** (Landed, #296 — `FilesView` and `FilesClient` gained folder browse, with tests).

## Non-goals (decided)

A diff viewer, an integrated terminal, an in-app browser, custom illustration, gradients, and skeletons-before-tokens.  The engines already serve depth better; the phone routes to it.

## Where to go next

The live sequencing belongs to `native-ui-capability-program.md` (C-137) and its pass documents; this catalogue is the inventory behind it.  The biggest open clusters, by impact: the rest of the approval evidence (B3), the ambient surfaces (H1-H4), and the accessibility remainders (I1-I5).  Pass 2 of the programme landed on main as #309, and Pass 3, the phone as the attention surface, has started with the approval evidence reaching the client (#310), the phone’s Face ID gate in front of an allow (#312) and the approval notification with its deny action and its deep link (#316).  What is left of the ambient surface is the host push relay, and then the Live Activity, the Lock Screen accessory and the Control Center action.
