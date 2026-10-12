# Deploy checklist — CometChat iOS Chat tab (0b2e9d7c)

Run in order once the live CometChat proof passes. Key names only — values
live in Infisical and the handoff file, never here.

## 1. Live relay proof (needs Jay first)

- Jay adds numeric `COMETCHAT_APP_ID` and `COMETCHAT_REGION` (us|eu|in)
  to the comet-chat handoff file alongside the existing keys.
- Provision the agent user (`COMETCHAT_AGENT_UID`, default `clutch-agent`)
  and this device's login user in the CometChat app.
- Re-run the relay verification: send, streaming edits, tool card.
- Pair the sim build against the live sidecar, send one turn, screenshot
  the thread, attach to the lane.

## 2. Land

- `pnpm typecheck && pnpm test` (lane), simulator `BUILD SUCCEEDED`,
  `ClutchTests` 20/20, `ClutchChatTabUITests` green.
- Merge `clutch/0b2e9d7c-cometchat-ios-chat` to `main` with `Refs 0b2e9d7c`.
- Board `0b2e9d7c` → completed with the merge SHA; Zulip closeout post.

## 3. Mac live install

New always-on piece: the chat sidecar. Files that must reach
`~/apps/clutch-runtime` (same sync path as the last install):

- `src/web/chat-bridge.ts`, `src/web/cometchat-relay.ts`
- `src/web/pair-link.ts`, `src/web/pair-ios.ts`, `src/web/start-web.ts`
- `src/shared/ports.ts`, `scripts/chat-bridge.sh`, `scripts/start-web.sh`

Then:

- `COMETCHAT_APP_ID`, `COMETCHAT_REGION`, `COMETCHAT_REST_API_KEY`,
  `COMETCHAT_AGENT_UID` into Infisical (sidecar reads env, never handoff
  files). Auth Key stays out — backend-only REST key plus device login.
- Restart pm2 `clutch-web` (starts the sidecar on 3181, Tailscale-mapped).
- Verify: `chat-config` answers, pairing link carries `&chat=` + `&chatPort=`.
- Update `/Users/jay/apps/MAC-LOCAL-PROCESSES.md` plus the Apple Note
  (`apple-notes-coding.sh --update`) in the same change: the sidecar is
  always-on alongside `clutch-web`, on-demand otherwise.

## 4. iOS build

- `bash scripts/build-ios.sh --device --release` (already green in-lane).
- `ship-testflight.sh clutch`, attach the live-thread screenshot to
  What to Test, submit for beta review.
- On device: pair, open the Chat tab, confirm the agent thread streams.

## 5. Follow-ups (not this lane)

- Server-minted CometChat user tokens replacing the dev-grade Auth Key
  travel in `chat-config`.
- Hold-to-record on the native input bar (currently a placeholder).
- Interactive card actions beyond the confirmation alert.
