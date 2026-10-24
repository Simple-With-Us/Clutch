# MiniMax Code Server Hosts

A MiniMax Code server host is a machine that runs only the Clutch chat sidecar in front of a local `mcode acp` process, so the Clutch apps on iPhone and Mac can list, resume, and drive that machine's MiniMax Code threads over Tailscale.  It needs no `dsh web`, no DeepSeek or MiniMax provider profile, and no clutch web pairing — the sidecar is the whole backend.

The first live host is the Hetzner server `jay-server.boa-roygbiv.ts.net`.  This page is the setup for putting another one up, and the record of how that one runs.

## How It Works

```
iPhone / Mac (Clutch app)            Server
┌────────────────────────┐  HTTPS   ┌───────────────────────────────────┐
│ Code tab / Chat ▸      │ ───────▶ │ tailscale serve :3181 (tailnet)   │
│ MiniMax Code           │ tailnet  │        │ proxy                    │
│  • thread list         │          │        ▼                          │
│  • transcript + send   │          │ chat sidecar 127.0.0.1:3181       │
│  • stop button         │          │   src/web/chat-bridge.ts          │
└────────────────────────┘          │        │ mcode acp (stdio ACP)    │
                                    │        ▼                          │
                                    │ MiniMax Code threads on disk      │
                                    └───────────────────────────────────┘
```

- The sidecar binds loopback only and is published through `tailscale serve`, so it is reachable on the tailnet and nowhere else.  Every request also needs the sidecar's Bearer token (`$CLUTCH_HOME/chat-token`, mode 600), which the pairing link carries to the app once.
- The sidecar trusts loopback plus this machine's own Tailscale MagicDNS name.  It detects that name itself from `tailscale status` at startup (retrying briefly while tailscaled comes up); `CLUTCH_TAILNET_HOST` overrides it when set.
- Threads are MiniMax Code's own.  Listing uses ACP `session/list`, resuming replays through `session/load`, and a turn runs through `session/prompt` on the same `mcode acp` process the owner uses in a terminal, so a thread started on the server can be continued from the phone and vice versa.  Tool permission requests are answered `allow_once`, never `allow_always`.
- The Stop button calls `POST /clutch/v1/chat/cancel`; dropping the stream cancels the turn too.  Either way the thread stays resumable.

## Server Setup

Prerequisites on the server: Node 22 or later, Tailscale signed in, MiniMax Code installed and signed in as the user the service will run as (`mcode login`), and this repo checked out with `npm ci` run in it.

```bash
bash scripts/install-server-bridge.sh            # or: --user <name>
systemctl status clutch-chat-bridge
node_modules/.bin/tsx src/web/pair-ios.ts --server
```

The installer writes `/etc/systemd/system/clutch-chat-bridge.service` from `scripts/systemd/clutch-chat-bridge.service`, enables it, and starts it.  The unit runs `scripts/chat-bridge.sh` from the checkout it was installed from, so re-run the installer after moving the checkout.

The pairing command saves the pairing link to `$CLUTCH_HOME/server-pairing-link.txt` (mode 600) on a headless server instead of printing it — the link contains the sidecar token, so treat the file like a credential.  `--print` prints it when you really mean to.  Copy the file's contents into Clutch on the phone or Mac (Paste Pairing Link, or the Mac's Add Host flow); the app stores it as a MiniMax Code server host and opens on its threads.

To check the host the way a phone sees it:

```bash
curl -H "Authorization: Bearer $(cat ~/.clutch/chat-token)" \
  https://<magicdns>:3181/clutch/v1/health
curl -H "Authorization: Bearer $(cat ~/.clutch/chat-token)" \
  "https://<magicdns>:3181/clutch/v1/sessions?engine=mcode&limit=5"
```

The health answer reports `mcode.available`, which is false when MiniMax Code is missing or not signed in on the server.  The apps surface that in the chat header instead of failing the first send.

## The Live Hetzner Host

- Unit: `clutch-chat-bridge.service`, running as root from the fleet checkout, always-on with `Restart=on-failure`.  It is the only Clutch process on that box; there is no clutch web there.
- Reachable at `https://jay-server.boa-roygbiv.ts.net:3181` on the tailnet only (`tailscale serve`, set up by `scripts/chat-bridge.sh` on every start).
- Engines on that box: MiniMax Code (`mcode acp`) and Muse Code (`muse serve` behind the community `@bex-co/muse-code-acp` adapter, installed globally at `/usr/local/bin/muse-code-acp`).  The catalog route reports both, with Muse's models read from the Muse provider catalog — Muse Wonder (`muse-wonder-1.0`) among them.
- Pairing link: `/root/.clutch/server-pairing-link.txt` on the server (owner-only).  Re-mint it any time with the pairing command above; the token survives sidecar restarts, so existing pairings keep working.
- Updating: pull the checkout, run `npm ci`, then `systemctl restart clutch-chat-bridge`.  Re-run the installer if the checkout moved, because the unit points at it.

### Muse Code On A Server

Muse Code is not an ACP agent: `muse serve` speaks MSP, and the community adapter `@bex-co/muse-code-acp` translates MSP to ACP on stdio.  The sidecar launches that adapter through `scripts/muse-code-acp.sh`, exactly as the Shellular runtime does.

```bash
npm install -g @bex-co/muse-code-acp      # the adapter
muse login                                # as the service user
```

The launcher's `MUSE_CODE_ACP_BIN` pins the adapter path, and `MUSE_CODE_ACP_SEARCH_PATHS` replaces the whole search list (the fleet runtime keeps the adapter outside the global npm prefix).  `MUSE_CODE_EXECUTABLE` pins the `muse` host binary.

The Muse models come from two places, and the catalog merges them: what the ACP session advertises on `session/new`, and the provider catalog the Muse CLI writes to `~/.local/share/muse/model-catalog/`.  The provider catalog is what makes a model the session does not advertise — Muse Wonder — selectable from the phone and the Mac.

Muse Code's ACP session takes content blocks, not a bare string, so the sidecar sends the block form to both code engines.  Tool calls ride the same path as the other engines: `session_call` updates become `tool` SSE events and replay as one card per call.

## Client Surfaces

- **iPhone and iPad:** the Code tab is the MiniMax Code split view (thread sidebar plus transcript), and the Chat tab carries the same surface behind its Agent / MiniMax Code switch.  A server host also lands on the Code tab when selected, because it has no agent relay behind it.
- **Mac:** the native Chat surface has a DeepSeek / MiniMax / MiniMax Code engine picker.  MiniMax Code mode adds the thread rail (filter, Today / Yesterday / Previous 7 Days / Older groups, thread count, selected folder in the footer), a working-directory bar for the next new thread, sidecar health in the header, and a Stop button while a turn runs.
- **Browser:** the sidecar also serves the MiniMax Code remote shell at `/minimax-code/` on the sidecar origin, now with a thread filter.  `clutch-pair-ios --shell` mints its link.

On both native apps, threads can be pinned locally (per host, on-device only), tool calls stream as cards with running / completed / failed status and replay as one card per call, transcripts export as Markdown (share sheet on iOS, Copy and Save on Mac), a turn finishing in the background posts a local notification, Find searches the open thread, and the mic dictates into the composer through the system speech recognizer.

### The Model Picker

`GET /clutch/v1/engines` publishes what the host can run right now: each engine's models and reasoning-effort levels.  Both apps build their model and effort pickers from it, which is the web canvas's model picker reduced to what a native client can show — and, unlike a hardcoded list, a model the provider ships tomorrow appears without an app release.

The app asks for a model by id; the sidecar maps it onto the exact wire value the engine wants, because every engine spells its models differently (MiniMax Code uses `m:minimax:…:v:thinking`, Muse can use a provider-qualified `muse-model:[…]`).  The choice is applied as an ACP config option (`session/set_config_option`) on the model id and on the engine's own effort option: `reasoning_effort` on dsh, `thinkingEffort` on MiniMax Code, `reasoningEffort` on Muse Code.  A refusal is reported, never fatal: the turn still runs with the engine's default.

### The Mac App Reaching Another Machine

The Mac app pairs and switches hosts the way the phone does, so a code server on another machine is one click away: the chat surface has a host menu with every paired host plus **Add Host…**, and the same pairing link the phone uses works there.  A paired server host has no web canvas and no dsh host contract behind it, so the Mac shows the code surfaces only — the thread rail, the model and effort pickers, and the composer.

## Troubleshooting

- **`mcode` answers "Internal error" on every turn, but listing threads works:** MiniMax Code refuses to use an OAuth credential file that is not private.  Check `~/.minimax/auth/prod/en/mcode-public/auth.json` is mode 600 for the service user; a group-readable 660 passes silently until a token refresh trips the check.  Listing keeps working because it never touches the credential.
- **Health says `mcode.available: false`:** MiniMax Code is not installed for the service user, or `mcode login` has not been run as that user.
- **Phones get 401:** the pairing link predates the token, or the sidecar was paired from a different `$CLUTCH_HOME`.  Re-run the `--server` pairing and paste the fresh link.
