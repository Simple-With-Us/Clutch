# Clutch UI/UX Improvement Program — Linear Project Format

Date: 2026-11-23.  Source: eight-agent expert review (iOS, Mac, dsh-host contract, docs/plans, performance, critic, runtime gap follow-up, synthesis) of the app as built plus `docs/plans/ui-ux-overhaul.md`, `docs/plans/ui-improvements-catalog.md` (A1–M4), `docs/plans/native-ui-capability-program.md` (C-137), and the decision records.  The four owner asks that started it — Quick Chat rename and reorder, iOS folder navigation to server paths, Mac file open/edit reimagined, model/platform always visible in the composer — are Epics 1–4; Epics 5–6 carry the wider performance and usability program.

How to file: one Linear project ("Clutch UI/UX Program"), one milestone per epic, one issue per `###` item.  Each issue carries Problem, Proposal, Acceptance Criteria, Priority (P0–P3), Estimate (S/M/L), Files, and Refs.  Link catalog items, do not refile them (§0).

Sequencing (binding, from the capability program): Pass 1 honest-ground and test gates first; Mac structural work rides the Mac UI test target (open #306); transcript rendering (D1–D3) lands before the sidecar evidence widening; every UI issue needs automated visual verification (simctl/XCUITest/Playwright — the owner never screenshots).  `project.yml` is the Xcode source of truth, never hand-edit `project.pbxproj`.  Copy rules: sentence gap U+00A0 plus space, Title Case headings, America/Chicago times.  Icon art comes from the owner only, full-bleed square, never squircle.  Lock screen shows the thread title only, never tool name, command, path, or diff; locked actions are Deny plus open-app, never Allow.  No WebView/WebKit/Electron on device.  Decided non-goals stay out: diff viewer, terminal, in-app browser, skeletons and illustration until type/contrast/icon are right.  The web Settings dialog is upstream compiled `dsh` dist and is not extensible; Clutch's settings surface is the `clutch-settings` CLI, `GET`/`PUT /clutch/v1/infisical`, and the native sheet.

## Shipped In This Change

The first slice of Epics 1–4 is implemented alongside this plan: Quick Chat rename with "Without a Project" subtitle on iOS and Mac, Quick Chat moved below every project and folder section, Enter Path free-text on the iOS working-folder menu, recents seeded from thread working folders, an editable Browse From root in the folder picker (explicit `/mnt/...` roots reach server trees the home jail cannot), the engine/model/effort bar in the new-thread composer with the picked model sent on the first turn, `ClutchHost.isLocal` with the Mac working-folder menu rooted at the sidecar (This Mac panel only on loopback), Reveal in Finder gated on locality with copy-plus-deep-link on remote hosts, file preview actions (Copy Path, Copy Contents, Refresh, Open in Editor with a read-only-copy badge on remote), and a Files toolbar item.  Issues marked [Shipped] below are done; the rest are filed from this document.

## §0 Already Planned — Link, Do Not Duplicate

Attention Stack A1 landed; Session Deck D10, Turn Ledger, D1–D3 transcript, B1–B3 approvals, E-series composer (E3 picker landed), F-series sessions, G-series Mac-native, H-series ambient (needs push relay, owner question 1), I-series accessibility ratchet, J2 theme migration, L1/L2 verification — all open or partial in the catalog plus capability program C-137.  New issues below reference them in `Refs`.

## EPIC 1 — Home Truth: Quick Chat Plus Project Order

### 1.1 Rename Agent Chat to Quick Chat / Without a Project [Shipped]

Problem: `agentChatRow` (`SessionsView.swift`) hardcoded "Agent Chat" / "The always-there conversation", a name that promises an agent surface that does not exist.  Proposal: title `Quick Chat`, subtitle `Without a Project`; accessibility label and identifier, Mac `RootView` tab label, and Mac navigation title updated in sync; UI test identifier renamed.  AC: iOS row and VoiceOver read Quick Chat; no "Agent Chat" string remains in UI or accessibility; snapshot test updated.  Priority P1.  Estimate S.  Files: `ios/App/Views/SessionsView.swift`, `ios/App/Views/RootView.swift`, `ios/Mac/ChatViewMac.swift`, `ios/UITests/ClutchChatTabUITests.swift`.

### 1.2 Quick Chat Sits Last, Below Projects and Folders [Shipped]

Problem: `homeList` rendered the Quick Chat row first, above Needs You, Running, Pinned, and folder groups — backwards priority.  Proposal: move the row below `ForEach(folderGroups)`; keep Needs You and Running pinned at top per landed A1.  AC: with one or more folder groups, Quick Chat renders after the last group; empty state unchanged; list-order UI test.  Priority P1.  Estimate S.  Files: `SessionsView.swift` homeList.

### 1.3 iOS Project Sections via Session Meta (Needs A3 Decision)

Problem: iOS groups by working-folder leaf (`folderGroups`, zero Project references) while the Mac rail groups by `SessionsClient.Project` plus `ThreadSidebarGrouping`; Quick Chat has no project sections to sit below.  Proposal: fetch `GET /clutch/v1/session-meta` on iOS; reuse grouping semantics; folder working directory becomes the fallback bucket.  Refs catalog A3 (repo-first grouping, proposed-needs-decision).  AC: same host shows same project names on iOS and Mac; Quick Chat below last project; offline falls back to folder groups.  Priority P2.  Estimate M.  Files: `SessionsView.swift`, `SessionsClient.swift`, new `SessionMetaClient` or extension, `chat-bridge.ts` session-meta route.

## EPIC 2 — Working Folder Plus /mnt Plus Server Paths (iOS Plus Shared)

### 2.1 iOS Enter-Path Free-Text Row [Shipped]

Problem: Mac threads reached `/mnt` via free-text `codeCwd` (`ChatViewMac.swift` into `body.cwd`, bypassing the browse jail); the iOS `workingFolderRow` offered only Default, recents, and Browse — no escape from the home jail.  Proposal: `Enter Path…` row in the working-folder menu writing `workingFolder` directly, absolute-path validation, persisted to recents on use.  AC: typing `/mnt/fleet-extra/Code/Clutch` creates a thread with that working directory; invalid path shows an inline error, no crash.  Priority P1.  Estimate S.  Files: `SessionsView.swift` working-folder row, `NewThreadModel`, `RecentFolderStore`.

### 2.2 Seed Recents From Thread Working Folders Plus Server Project Paths [Shipped]

Problem: recents started empty; server-side project paths never surfaced on iOS.  Proposal: `RecentFolderStore.seed` from existing thread working directories (dedupe, cap 5), owner picks stay first; project default paths from session meta when 1.3 lands.  AC: fresh install with threads shows their working directories in the menu; duplicates collapsed.  Priority P1.  Estimate S.  Files: `RecentFolderStore`, `SessionsView.swift`, `SessionsClient.swift`.

### 2.3 Sidecar Allowed-Roots Escape Hatch (The Hard Wall)

Problem: `resolveInsideReal` (`files.ts`) plus `defaultCwd()=HOME` jail default-root browsing to home; explicit `?root=/mnt/...` would list (per-root jail, proven at runtime) but no client sent an explicit root.  The shipped client escape hatches (2.1 plus Browse From root) cover typing; this issue covers discovering.  Proposal: operator-configured allowed-roots list (Infisical, for example `/mnt/fleet-extra`) plus `GET /clutch/v1/roots`; picker offers a root switcher; default stays home; audit-log root escapes.  Alternative — `/` behind auth — rejected unless the owner approves.  AC: with the allowlist set, the picker reaches `/mnt` via explicit root; without it, behavior unchanged; escape outside allowed roots still refuses with `FileAccessError`; tests for prefix-share plus symlink cases extended.  Priority P2.  Estimate M.  Files: `src/web/files.ts`, `src/web/chat-bridge.ts` files routes, `FilesClient.swift`, `FilesView.swift`, `tests/files.test.ts`, Infisical schema.

### 2.4 Folder Browsing Performance: Cache Plus Paginate Plus Show-Hidden

Problem: `listDirectory` stats up to 20k dirents at 32-way concurrency per folder, sorts all then caps at 2000; zero server or client cache; `navigate()` constructs a new `FolderModel` per folder; dotfiles hidden with no toggle.  Proposal: server mtime-keyed directory cache (1–5s TTL); client folder cache; cursor pagination past 2000; preview size parameter; show-hidden toggle.  AC: re-entering a folder issues no network fetch within TTL; a 2000-plus-entry directory pages; hidden toggle persists per host.  Priority P2.  Estimate M.  Files: `files.ts`, `chat-bridge.ts`, `FilesView.swift` FolderModel and FolderPickerView.

## EPIC 3 — Mac File Open/Edit Reimagined Cross-Host

### 3.1 Kill Machine Confusion: ClutchHost.isLocal Plus Sidecar-Rooted Working Directory [Shipped]

Problem: `chooseCwd` stored a local Mac path and sent it as `root` to the sidecar's `resolveInsideReal` — meaningless on remote hosts (Tailscale Mac origin, Linux code server); `displayCwd` fell back to the local home.  Same bug class.  Proposal: `ClutchHost.isLocal` (loopback only — a Tailscale or LAN address is another machine); working-folder choice browses the sidecar tree via `FolderPickerView`; the Mac open panel stays only behind `isLocal` as `This Mac…`; the fallback label is the sidecar default, never a local path.  AC: remote host — choosing a folder browses the sidecar tree and returns a sidecar-absolute path; local host — `This Mac…` still works; no local path ever sent as root on remote.  Priority P0.  Estimate M.  Files: `ClutchHost.swift`, `HostStore.swift`, `ChatViewMac.swift`, `FilesView.swift`, `project.yml`.

### 3.2 Gate Reveal in Finder on Locality [Shipped]

Problem: `handle(.revealInFinder)` ran `NSWorkspace.activateFileViewerSelecting` on `session.cwd`, a sidecar-machine path — silently opening a wrong or nonexistent local path on remote hosts.  Proposal: gate on `isLocal`; remote offers Copy Path plus a deep link into the Files sheet at that path.  AC: remote — no Finder call, copy and deep link shown; local — unchanged.  Priority P1.  Estimate S.  Files: `ChatViewMac.swift`, `ThreadSidebar.swift`, `ClutchHost.swift`.

### 3.3 One Working Folder Menu Plus Files Toolbar Item [Shipped]

Problem: the `cwdBar` (tiny Files/Choose/Edit text buttons) duplicated the new-thread sheet's correct picker (recents plus Browse plus Default).  Proposal: merge Choose and Edit into one Working Folder menu mirroring the sheet, with recents, Browse, This Mac (local only), and Enter Path; Files promoted to an icon button plus a toolbar item with shortcut.  Refs G2 (shortcuts out of buttons).  AC: single menu with recents, Browse, Default, and Enter Path; shortcut opens Files; duplication removed; UI test.  Priority P1.  Estimate M.  Files: `ChatViewMac.swift`, `SessionsView.swift`, toolbar definition.

### 3.4 File Preview Actions, Phase 1 (Read-Only Remote-Safe) [Shipped]

Problem: `FilePreviewView` was read-only text with zero actions.  Proposal: toolbar with Open in Editor (local — `NSWorkspace.open`; remote — download-to-temp read-only copy with an "edits won't save" badge), Copy Path, Copy Contents, Refresh.  AC: each action works per locality; remote temp file badged; no silent no-op.  Priority P1.  Estimate M.  Files: `FilesView.swift`, `FilesClient.swift`.

### 3.5 Real Edit: Sidecar PUT /clutch/v1/file Plus Native Editor (Phase 2)

Problem: the sidecar exposes only list-plus-preview GET; Edit is unimplementable today.  Proposal: `PUT /clutch/v1/file` under the `resolveInsideReal` jail, size cap plus If-Match precondition (mtime/etag); native Edit affordance in preview; conflict dialog on stale write.  AC: round-trip edit persists; oversized, conflict, and jail-escape each produce distinct errors; no path outside root writable.  Priority P2.  Estimate L.  Files: `files.ts`, `chat-bridge.ts` (new route), `FilesClient.swift`, `FilesView.swift`.

## EPIC 4 — Composer Always Shows Model/Platform

### 4.1 New-Thread Sheet Model Bar [Shipped]

Problem: the sheet had folder plus draft only; `send` hardcoded `ChatSessionClient(model:"")` — nothing to display.  Every other composer shows engine and model.  Proposal: compact model bar above the field — engine chip, model menu via `EngineModel.displayLabel`, effort menu when advertised — fetched from `EngineCatalogClient(host).fetch(engine:)`; the pick rides the first turn; empty catalog shows `Not reported`, never fabricated.  AC: sheet always shows engine plus model before typing; selection survives folder changes; sent thread uses the selected model; empty catalog shows `Not reported`.  Priority P1.  Estimate M.  Files: `SessionsView.swift`, `EngineCatalogClient`, `SessionThreadView.swift` (semantics reference).

### 4.2 Per-Engine Last-Model Plus Effort Memory; Engine Switch Preserves Thread

Problem: `selectEngine` clears model and effort (`ChatView`) and drops the open thread (`SessionsView`).  Proposal: persist per-engine model and effort; restore on switch; never drop the open thread on engine change.  AC: switching engine A to B and back restores A's model and effort; open thread stays.  Priority P1.  Estimate S.  Files: `ChatView.swift`, `SessionsView.swift`, EngineCatalog store.  Refs catalog F2 (persisted engine choice, partial).

### 4.3 Reconcile Four Divergent Model Catalogs

Problem: sidecar engine catalog versus host modelCatalog versus ACP `dshModelOptionValue` versus display-identity-from-logs disagree (for example M2.7-highspeed default not in sidecar list; fuzzy provider match plus silent `models[0]` fallback).  Proposal: single resolution order exact, id, name, alias plus DeepSeek API-name guard everywhere; surface fallback in UI (`engine default` label); log divergence; pinned test locking catalog parity.  AC: same engine-plus-model id resolves identically on all four paths or shows its fallback label; parity test green.  Priority P2.  Estimate M.  Files: `engine-catalog.ts`, `dshHostSessions.ts`, `dshHostTurn.ts`, ACP option mapping, `tests/dsh-host-pinned.test.ts`.

## EPIC 5 — Speed/Performance (Static Bounds; Measure Before/After per BF-2612 Lesson)

### 5.1 Startup: Parallelize Plus Fast Paths

Serial `initClutchSettings`, tailnet 30s wait, `reclaimPort` (lsof plus ps plus curl plus 8x500ms), backfill python plus fetch per launcher, second 10s tailnet wait.  Proposal: parallel settings plus probe plus reclaim; skip backfill without token file; cache tailnet name; spawn serve-tailscale plus bridge concurrent.  AC: cold start p50/p95 measured plus improved; no behavior change when Infisical absent.  Priority P1.  Estimate M.  Files: `start-web.ts`, `chat-bridge.ts` tailnet detect, `clutch-env.sh`, `clutch-infisical-env.sh`.

### 5.2 Infisical: Cache Verify, Timeout Secrets GET

Two to three sequential round trips per op, secrets GET has no timeout, refresh re-verifies every 5 min.  Proposal: cache verify until 401; `AbortSignal.timeout` on secrets GET; skip verify on background refresh.  AC: steady-state refresh is 1 timed request; revocation still detected within 1 cycle.  Priority P1.  Estimate S.  Files: `src/shared/infisicalSettings.ts`.

### 5.3 Session List: Stop Overfetch Plus Single Inflate Plus Index TTL

`fetchLimit` 500/5000 then slice; host ignores cursor; per-row readdirSync plus full zstd inflate twice; muse 20k rescan per 500ms TTL expiry.  Proposal: server cursor pagination (needs host cursor check); single inflate shared by usage plus metadata; index TTL 30–60s plus mtime invalidation; cap fetchLimit.  AC: 50-row list halves shared inflate passes; list latency measured; explicit load-more past caps (no silent truncation, D5/F3).  Priority P0.  Estimate M.  Files: `chat-bridge.ts` sessions route, `dshHostSessions.ts`, `muse-session-log.ts`.

### 5.4 Native List: Memoize Plus Debounce Plus Stable Ids Plus Indexed Upsert

`visibleSessions`, `folderGroups`, and `groups()` recompute per body; 8-field lowercase filter per keystroke; `matchOrder` per keystroke; `upsert` firstIndex scan per SSE chunk O(n2); `hashValue` ids break diffing; per-frame re-encode.  Proposal: memoize sorted and filtered; 150–300ms search debounce; stable ids (toolCallId plus seq); id-to-index map; decode once.  AC: long-turn streaming stays 60fps-class (measured); find selection stable across launches.  Priority P1.  Estimate M.  Files: `SessionsView.swift`, `ThreadSidebar.swift`, `AcpSessionInfo`, `SessionThreadView.swift`, `DshHostStream`.

### 5.5 Probes Plus Catalog Timeouts: Parallel, Shared Session, Passive-First

Serial `refreshStatuses`, ephemeral session per probe, duplicate task storms on foreground, 15s readiness plus 10s backoff plus 30s cooldowns, 60–90s picker hang (probe 60s inside 90s client), serial catalog-then-chat connect.  Proposal: parallel probes over shared session; dedupe foreground tasks; passive-first catalog plus background refresh; 2/10/30s timeout ladder; parallel catalog plus connect.  AC: N hosts probe in about 1 host time; picker renders cached catalog under 300ms with background refresh badge.  Priority P1.  Estimate M.  Files: `HostStore.swift`, `HostProbe`, `RootView.swift`, `DshHostClient.swift`, `dshHostClient.ts`, `engine-catalog.ts`, `SessionsClient`, `ChatView.swift`.

### 5.6 Images: Raise /chat Body Cap, 413 Plus Client Precheck, No Silent Drops

1MB `readJsonBody` versus 6MB max image (about 8MB base64) yields generic invalid-JSON; oversized and unknown-MIME silently `continue`; 10x6MB paste through a 1MB gate.  Proposal: 10–25MB `/chat` cap; 413 naming image plus size; client pre-check of total bytes; oversized becomes an explicit error card.  AC: single 6MB image sends; oversize yields a named 413, never an imageless silent turn.  Priority P1.  Estimate S.  Files: `chat-bridge.ts`, `ChatAttachment.swift`, `AttachmentPaste.swift`.

### 5.7 Mux/SSE: Ring Buffers Plus Caps Plus Heartbeat

`pending.shift()` per item, unbounded `Buffer.concat`, 5-hop body resend, 200-event `removeFirst` shift with no readers, 600s stream no heartbeat, single-line SSE parser, maxMessages:1 still builds skipped snapshot, 250ms cleanup race.  Proposal: index queues and rings; 1–5MB body caps; SSE heartbeat plus idle timeout; no-snapshot follow flag (host permitting).  AC: 10k-frame turn has no quadratic behavior; idle stream detected under 60s.  Priority P2.  Estimate M.  Files: `dshHostClient.ts`, `DshHostClient.swift`, `dshHostTurn.ts`.

## EPIC 6 — Functioning, Intuitiveness, Customizability, Features

### 6.1 Settings: Batch PUT Plus Hot-Swap Plus No-Trim Plus CLI Fast Path

Single-key PUT, credential-plus-setting 409, restart two-step blocks writes, full 30-key inventory per read, `str()` trims secrets, CLI pays full load.  Proposal: batch settings PUT; hot-swap settings client on credential save; never trim secret values; `clutch-settings --local` fast path.  AC: multi-key save is 1 request; credential rotation without restart; edge-whitespace secret round-trips.  Priority P2.  Estimate M.  Files: `src/web/infisical-route.ts`, `InfisicalSettingsClient.swift`, `clutch-settings` CLI.  Note: native sheet plus CLI plus route only — upstream web dialog not extensible.

### 6.2 Preserve Draft Plus Scroll Across Selection

`SessionsView.detail` rebuilds `.id(id)` per selection — loses scroll and draft on reselect.  Proposal: per-thread draft plus scroll store; restore on return.  AC: draft plus position survive select-away-and-back.  Priority P2.  Estimate S.  Files: `SessionsView.swift`, `SessionThreadView.swift`.

### 6.3 Honest Gates: Busy Guards Plus 5xx Gating Plus Fallback Countdown

Muse toggles warn but allow mid-turn change; `HostGate.classify` treats any non-401/403 including 500 as ready; 120s permission auto-fallback surprises.  Proposal: disable toggles while busy; gate on 5xx with card; visible fallback countdown plus cancel.  AC: no mid-turn toggle; 500 shows gate card; countdown visible at least 10s before fallback.  Priority P1.  Estimate M.  Files: `HostsSheet`, `HostGate`, `chat-bridge.ts` permission timeout.

### 6.4 Field-Qualified Search With Hints

Eight-field filter with no syntax (`AcpSessionInfo.filtered`, sidebar filter).  Proposal: `from:`, `engine:`, and `project:` qualifiers plus inline hint row; keep plain-text default.  AC: `engine:muse foo` filters correctly; hint row visible on focus.  Priority P3.  Estimate S.  Files: `AcpSessionInfo`, `ThreadSidebar`, `SessionsView` search.

### 6.5 Customizability Backlog (Small, Gated by Program Non-Goals)

Per-project default working folder plus engine; folder-list density toggle; transcript verbosity shortcut (refs D1).  Each AC: persisted per host and project, survives restart.  Priority P3.  Estimate S/M.  Explicitly out: diff viewer, terminal, in-app browser (decided non-goals); skeletons and illustration until type and contrast are right; icon art (owner supplies, full-bleed square only).

## Appendix — Evidence Provenance

Sessions and files inspected by the review team: `SessionsView.swift` (agentChatRow, homeList, folderGroups, NewThreadSheet, workingFolderRow, NewThreadModel.send), `ThreadSidebar.swift` grouping, `RootView.swift` tabs, `FilesView.swift` picker and preview, `FilesClient.swift`, `ClutchHost.swift`, `HostStore.swift`, `PairingLink.swift` locality helpers, `chat-bridge.ts` files/session/chat routes, `files.ts` jail, `dshHostContract.ts`, `dshHostSessions.ts`, `dshHostTurn.ts`, `dshHostApprovals.ts`, `dshHostClient.ts`, `engine-catalog.ts`, `SessionThreadView.swift` modelBar, `ChatView.swift` and `ChatViewMac.swift` pickers, `RecentFolders.swift`, `ThreadSidebar.swift` hover metrics ("Not reported" copy), `ClutchTheme.swift` tokens, `tests/files.test.ts` (14/14 green at review time, including refuse-to-leave-root, prefix-share, and symlink-escape), and `tests/design-literal-guard.test.ts` (new Swift type must use `ClutchFont` tokens).  Runtime proofs: `resolveInside` refuses `/mnt` escapes from home roots; `listDirectory` throws `FileAccessError` outside root; explicit `?root=/mnt/...` lists outside home (per-root jail).  Unverified at review time: live-device behavior, sidecar home on the owner's Mac host, wall-clock profiling, upstream host cursor support, and CometChat plus full ChatViewMac plus FleetRecallClient deep audit.
