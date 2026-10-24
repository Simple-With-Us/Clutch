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
- Pairing link: `/root/.clutch/server-pairing-link.txt` on the server (owner-only).  Re-mint it any time with the pairing command above; the token survives sidecar restarts, so existing pairings keep working.
- Updating: pull the checkout, run `npm ci`, then `systemctl restart clutch-chat-bridge`.  Re-run the installer if the checkout moved, because the unit points at it.

## Client Surfaces

- **iPhone and iPad:** the Code tab is the MiniMax Code split view (thread sidebar plus transcript), and the Chat tab carries the same surface behind its Agent / MiniMax Code switch.  A server host also lands on the Code tab when selected, because it has no agent relay behind it.
- **Mac:** the native Chat surface has a DeepSeek / MiniMax / MiniMax Code engine picker.  MiniMax Code mode adds the thread rail (filter, Today / Yesterday / Previous 7 Days / Older groups, thread count, selected folder in the footer), a working-directory bar for the next new thread, sidecar health in the header, and a Stop button while a turn runs.
- **Browser:** the sidecar also serves the MiniMax Code remote shell at `/minimax-code/` on the sidecar origin, now with a thread filter.  `clutch-pair-ios --shell` mints its link.
