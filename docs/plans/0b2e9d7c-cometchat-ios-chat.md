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

1. **Mac SSE endpoint.** Loopback sidecar next to `dsh web` sharing the
   trusted-host list and Tailscale mapping: `POST /clutch/v1/chat` as SSE
   (`agent_message_chunk` / `agent_thought_chunk` / tool events → `done`),
   backed by the existing Python ACP bridges. Boot-minted Bearer token
   delivered via the pairing link. UI-agnostic.
2. **CometChat relay (Mac side).** Translate the ACP stream into CometChat
   REST as the agent user. Open point: progressive message edits vs
   local-echo with a persisted final card.
3. **iOS Chat tab.** SPM `CometChatUIKitSwift` (from 5.2.3), agent-thread
   VC bound to the agent user, render gated on init → login → render.
   Keep the model strip and Whisper voice UI. ExyteChat stays until
   cutover, then is removed.

## Verify before merge

`pnpm typecheck && pnpm test`, simulator build, chat-turn screenshot,
then PR out of draft.
