# Z Code Server Hosts

A Z Code server host is a machine that runs only the Clutch chat sidecar in front of a local Z Code engine, so the Clutch apps on iPhone and Mac can list, resume, and drive that machine's Z Code threads over Tailscale HTTPS.  It is the same shape as a [MiniMax Code server host](minimax-code-server.md) — the sidecar is the whole backend, and there is no `dsh web` and no clutch web pairing.  Clutch has no SSH transport for engines; the network path is Tailscale, end to end.

## How It Works

```
iPhone / Mac (Clutch app)            Server
┌────────────────────────┐  HTTPS   ┌───────────────────────────────────┐
│ Code tab / Chat ▸      │ ───────▶ │ tailscale serve :3181 (tailnet)   │
│ Z Code                 │ tailnet  │        │ proxy                    │
│  • thread list         │          │        ▼                          │
│  • transcript + send   │          │ chat sidecar 127.0.0.1:3181       │
│  • stop button         │          │   src/web/chat-bridge.ts          │
└────────────────────────┘          │        │ stdio ACP                │
                                    │        ▼                          │
                                    │ zcode-acp-server (ACP bridge)     │
                                    │        │ zcode app-server --stdio │
                                    │        ▼                          │
                                    │ Z Code threads on disk            │
                                    └───────────────────────────────────┘
```

- Z Code's own CLI has no ACP command.  The sidecar starts the `zcode-acp-server` bridge (npm `zcode-acp-server`, [source](https://github.com/william0wang/zcode-acp)), which drives `zcode app-server --stdio` and speaks ACP to the sidecar.  An earlier release launched `zcode acp`, which every Z Code release rejects with `Unknown command: acp` (C-129).
- The sidecar binds loopback only and is published through `tailscale serve`, so it is reachable on the tailnet and nowhere else.  Every request also needs the sidecar's Bearer token (`$CLUTCH_HOME/chat-token`, mode 600), which the pairing link carries to the app once.
- Threads are Z Code's own.  A turn runs through `session/prompt` on the bridge, which runs it on the Z Code app-server, so a thread started on the server can be continued from the phone and vice versa.  Tool permission requests are answered `allow_once`, never `allow_always`.
- The sidecar finds the bridge next to its own `node`, in the usual npm prefixes, then on PATH; `CLUTCH_ZCODE_ACP_CLI` names one elsewhere and `CLUTCH_CHAT_LAUNCHER_ZCODE` overrides the whole launcher.
- The sidecar finds the Z Code CLI in `~/.local/bin/zcode`, `~/.zcode/bin/zcode`, PATH, then the desktop app bundles, follows symlinks to the real `zcode.cjs`, and hands that path to the bridge as `ZCODE_BIN`.  `CLUTCH_ZCODE_CLI` or `ZCODE_BIN` names one elsewhere.  The real path matters: the bridge hands the app-server Z Code's built-in provider table only when it can see the bundle's `zcode.cjs`.
- API keys meant for other engines (`ANTHROPIC_API_KEY` and the z.ai and GLM key names) are removed from the bridge's environment, because the bridge would otherwise let them override the Z Code sign-in.

## Server Setup

Prerequisites on the server: Node 22 or later, Tailscale signed in, the Z Code app or CLI installed, the bridge installed with `npm install -g zcode-acp-server`, a Z Code sign-in for the user the service will run as (sign in through the Z Code app, or run `zcode-acp setup --provider zai`), and this repo checked out with `npm ci` run in it.  Then follow [MiniMax Code server setup](minimax-code-server.md) — the installer, the systemd unit and the pairing flow are the same.  Name the engine in the pairing link so the app opens on the right surface:

```bash
CLUTCH_SERVER_ENGINE=zcode node_modules/.bin/tsx src/web/pair-ios.ts --server
```

Without the variable the pairing command detects the engine from disk (Muse Code's adapter, then the Z Code CLI, then MiniMax Code).  The link contains the sidecar token: do not print it, post it or place it in command arguments.

## Health And Troubleshooting

- `/clutch/v1/health` reports `zcode.available`, which is false when the bridge or the Z Code CLI is missing on the server.  The apps surface that in the chat header instead of failing the first send.
- `/clutch/v1/engines` is the catalog.  A host with the bridge and the CLI shows Z Code with the models and thinking levels the engine itself advertised on the probe; a host without them shows the declared catalog from `engines/zcode.engine.json` with `available: false` and a note naming what is missing.
- **The picker says Z Code needs its ACP bridge:** run `npm install -g zcode-acp-server` with the same Node the service runs.
- **The picker says Z Code needs a sign-in:** neither the Z Code app's sign-in nor a `zcode-acp setup` account is on disk for the service user.  The engine stays in the picker on purpose, because the bridge may still find a sign-in the check cannot see.
- **Turns fail with an auth error:** the Z Code sign-in is not readable by the service user.  Sign in as that user, or run `zcode-acp setup --provider zai` as that user.  An API key in Clutch settings does not sign Z Code in.
