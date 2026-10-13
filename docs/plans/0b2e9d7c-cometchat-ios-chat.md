# iOS Chat Tab: CometChat UI Kit + Real Host Wiring

Board: `0b2e9d7c` (CK, P2, In Progress) · Branch: `clutch/0b2e9d7c-cometchat-ios-chat`
Zulip: `#agent-sync` › `Clutch 0b2e9d7c CometChat iOS chat`

## Decision

Try CometChat UI Kit v5 (Build plan, free, 100 users, region `us`) for the
native iOS Chat tab, and wire it to the real clutch host. Owner chose
CometChat over polish-ExyteChat and Stream Chat.

## Findings that shape the build

- Chat tab today is ExyteChat 3.3.7 and fully mock (`submitUserPrompt`
  appends a canned reply). The ugly part is the data path, not the
  framework — but we are trying CometChat per owner call.
- CometChat UI Kit v5 is UIKit-only (binary XCFramework 5.2.3, iOS 15.1+).
  No SwiftUI sample upstream: embed a MessagesVC-style assembly
  (header + message list + full composer) via `UIViewControllerRepresentable`.
  Init/login are plain static calls, so the pure-SwiftUI `App` stays.
- `dsh web` exposes no REST API (cordis `/api` is internal and versioned).
  Do not re-implement it in Swift. Do not call model clouds from the phone
  (loses tools/sessions, puts keys on device).
- Backend injection is CometChat REST (`POST /v3/messages` with `apikey`
  + `onBehalfOf` the agent user, or `POST /v3/bots/{uid}/messages`),
  region `us`. Tool-call cards map to `category: interactive, type: card`.
- Secrets: App ID + Auth Key (client login, dev) and REST API key
  (backend-only, never ships in the app) live in `~/.secrets/comet-chat.txt`
  (mode 600). Values never appear in code, logs, or chat.

## Build order

1. **Mac SSE endpoint.** DONE and proven with a live DeepSeek turn
   (`start` → `thought` → `message: bridge-ok` → `done/endTurn`).
   Loopback sidecar next to `dsh web` sharing the trusted-host list and
   Tailscale Serve mapping: `POST /clutch/v1/chat` as SSE
   (`message` / `thought` / `done`), backed by the existing Python ACP
   bridges. Boot-minted Bearer token delivered via the pairing link
   (`&chat=`, `&chatPort=`). Engine `[stderr]` diagnostics ride `thought`
   events instead of answer bubbles. `GET /clutch/v1/health` and
   `GET /clutch/v1/chat-config` (CometChat app coordinates for the tab).
2. **CometChat relay (Mac side).** DONE (unit-tested, live app test
   blocked on dashboard values — see below). SSE stays primary; when the
   backend is configured and the caller names a target, each turn also
   streams into CometChat REST as the agent user: create on first chunk,
   throttled edits (1/s), flush on done, interactive cards for tool calls.
3. **iOS Chat tab.** DONE (simulator build green, tests pending):
   SPM `CometChatUIKitSwift` 5.2.3, agent thread (header + live list, no
   kit composer), native input bar posting to the sidecar, manager
   (chat-config → init once → device login → agent user), per-host chat
   token + port with pre-chat archive compat. Card taps surface as an
   alert. ExyteChat still linked; removal is the cutover commit.

## Owner gates (nothing else needs Jay)

- CometChat dashboard: stored App ID is not the numeric id and no region
  resolves — verify App ID + region, update the handoff file.
- Deploy: `COMETCHAT_APP_ID/REGION/REST_API_KEY/AGENT_UID` into Infisical
  (the sidecar reads env, never handoff files), then live-install update
  + TestFlight.

## Verify before merge

`pnpm typecheck && pnpm test`, simulator build, chat-turn screenshot,
then PR out of draft.
