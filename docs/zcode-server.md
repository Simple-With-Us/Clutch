# Z Code Server Hosts

A Z Code server host is a machine that runs only the Clutch chat sidecar in front of a local `zcode acp` process, so the Clutch apps on iPhone and Mac can list, resume, and drive that machine's Z Code threads over Tailscale HTTPS.  It is the same shape as a [MiniMax Code server host](minimax-code-server.md) — the sidecar is the whole backend, and there is no `dsh web` and no clutch web pairing.  Clutch has no SSH transport for engines; the network path is Tailscale, end to end.

## How It Works

```
iPhone / Mac (Clutch app)            Server
┌────────────────────────┐  HTTPS   ┌───────────────────────────────────┐
│ Code tab / Chat ▸      │ ───────▶ │ tailscale serve :3181 (tailnet)   │
│ Z Code                 │ tailnet  │        │ proxy                    │
│  • thread list         │          │        ▼                          │
│  • transcript + send   │          │ chat sidecar 127.0.0.1:3181       │
│  • stop button         │          │   src/web/chat-bridge.ts          │
└────────────────────────┘          │        │ zcode acp (stdio ACP)    │
                                    │        ▼                          │
                                    │ Z Code threads on disk            │
                                    └───────────────────────────────────┘
```

- The sidecar binds loopback only and is published through `tailscale serve`, so it is reachable on the tailnet and nowhere else.  Every request also needs the sidecar's Bearer token (`$CLUTCH_HOME/chat-token`, mode 600), which the pairing link carries to the app once.
- Threads are Z Code's own.  A turn runs through `session/prompt` on the same `zcode acp` process the owner uses in a terminal, so a thread started on the server can be continued from the phone and vice versa.  Tool permission requests are answered `allow_once`, never `allow_always`.
- The launcher resolves the Z Code CLI from `~/.local/bin/zcode`, `~/.zcode/bin/zcode`, then PATH; `CLUTCH_ZCODE_CLI` names one elsewhere and `CLUTCH_CHAT_LAUNCHER_ZCODE` overrides the whole launcher.

## Server Setup

Prerequisites on the server: Node 22 or later, Tailscale signed in, the Z Code CLI installed and signed in as the user the service will run as (`zcode login`), and this repo checked out with `npm ci` run in it.  Then follow [MiniMax Code server setup](minimax-code-server.md) — the installer, the systemd unit and the pairing flow are the same.  Name the engine in the pairing link so the app opens on the right surface:

```bash
CLUTCH_SERVER_ENGINE=zcode node_modules/.bin/tsx src/web/pair-ios.ts --server
```

Without the variable the pairing command detects the engine from disk (Muse Code's adapter, then the Z Code CLI, then MiniMax Code).  The link contains the sidecar token: do not print it, post it or place it in command arguments.

## Health And Troubleshooting

- `/clutch/v1/health` reports `zcode.available`, which is false when the Z Code CLI is missing on the server.  The apps surface that in the chat header instead of failing the first send.
- `/clutch/v1/engines` is the catalog.  A host with the CLI installed shows Z Code with the models the engine itself advertised on the probe; a host without it shows the declared catalog from `engines/zcode.engine.json` with `available: false` and the sign-in note.
- **The picker says Z Code needs a sign-in:** `zcode login` has not run as the service user, or `ZAI_API_KEY` is not set.  The engine stays in the picker on purpose — the sign-in starts from there.
- **Turns fail with an auth error:** the CLI's credential is not readable by the service user.  Sign in as that user, or set `ZAI_API_KEY` in Clutch settings (see INFISICAL.md).
