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

The pairing command saves the pairing link to `$CLUTCH_HOME/server-pairing-link.txt` (mode 600) on a headless server.  Import it through Paste Pairing Link or the Mac's Add Host flow.  The link contains the sidecar token: do not print it, post it or place it in command arguments.  A bare host URL does not pair native chat.  See [Native Session Workspace](native-session-workspace.md) for previewing and resuming Muse threads.

To check the host the way a phone sees it:

Use an authorized host-side diagnostic client that reads the service user's private chat-token file into memory, sends the Bearer header and returns only allowlisted health or session-list metadata.  Check `/clutch/v1/health` and `/clutch/v1/sessions?engine=mcode&limit=5` through the paired host origin.  Do not put the token in curl arguments or shell tracing.

The health answer reports `mcode.available`, which is false when MiniMax Code is missing or not signed in on the server.  The apps surface that in the chat header instead of failing the first send.

## The Live Hetzner Host

- Unit: `clutch-chat-bridge.service`.  Verify its current service user, process directory and listeners before operating it; the original root-user setup is historical.
- Reachable at `https://jay-server.boa-roygbiv.ts.net:3181` on the tailnet only (`tailscale serve`, set up by `scripts/chat-bridge.sh` on every start).
- Engines include MiniMax Code and Muse Code.  Updated native Muse clients and sidecars offer only the three exact contributor model IDs documented in [Muse Contributor Models And Launch Options](muse-contributor-options.md).
- Pairing link: `$CLUTCH_HOME/server-pairing-link.txt` for the actual service user.  On the verified November 3 installation that user is `jay`, with Clutch home `/home/jay/.clutch`.  Preserve the existing link and token when they already pass authenticated health and session-list checks.
- Updating: the unit runs the checkout it was installed from, so pull it, run `npm ci`, then `systemctl restart clutch-chat-bridge`.  The live host pins the unit to a release instead; see [Pinning The Sidecar To A Release](#pinning-the-sidecar-to-a-release).

### Pinning The Sidecar To A Release

The unit that `scripts/install-server-bridge.sh` writes runs the checkout it was installed from, so on a fresh host `git pull`, `npm ci` and `systemctl restart clutch-chat-bridge` are the whole update.  The live host does not run that way: a drop-in pins the unit to one merged commit, so pulling the checkout changes nothing that is running.

The drop-in is `/etc/systemd/system/clutch-chat-bridge.service.d/20-clutch-release.conf`, and it overrides both the working directory and the command:

```ini
[Service]
WorkingDirectory=/mnt/fleet-extra/apps/runtime/Clutch/releases/<sha>
ExecStart=
ExecStart=/mnt/fleet-extra/apps/runtime/Clutch/releases/<sha>/scripts/chat-bridge.sh
```

The roll is one script, because every step depends on the one before it and a half-finished roll leaves the unit on the wrong release.  It pins the remote tip, exports that commit, carries the dependencies over only when the lockfile did not move, writes the drop-in and restarts the unit:

```bash
set -euo pipefail

REPO=/mnt/fleet-extra/Code/Clutch
RELEASES=/mnt/fleet-extra/apps/runtime/Clutch/releases
DROPIN_DIR=/etc/systemd/system/clutch-chat-bridge.service.d
DROPIN=$DROPIN_DIR/20-clutch-release.conf

git -C "$REPO" fetch origin main
SHA=$(git -C "$REPO" rev-parse origin/main)
NEW="$RELEASES/$SHA"

# The release that is running now, when there is one:  it holds the
# dependencies and it is where a failed roll goes back to.
PREVIOUS=$(systemctl show -p WorkingDirectory --value clutch-chat-bridge.service)
case "$PREVIOUS" in
  "$RELEASES"/*) OLD_SHA=$(basename "$PREVIOUS") ;;
  *) OLD_SHA="" ;;
esac

mkdir -p "$NEW"
git -C "$REPO" archive "$SHA" | tar -x -C "$NEW"
sudo chown -R jay:fleet "$NEW"

# The dependencies come from the release that is already running, so a roll is
# a copy and not a build.  A commit that moved the lockfile needs its own
# install, because the old tree would not hold what the new code imports and
# the unit would die at boot.
if [ -n "$OLD_SHA" ] && git -C "$REPO" diff --quiet "$OLD_SHA" "$SHA" -- package-lock.json; then
  cp -al "$RELEASES/$OLD_SHA/node_modules" "$NEW/node_modules"
else
  (cd "$NEW" && npm ci)
fi

# The drop-in is only written for a release that can actually run.
test -x "$NEW/scripts/chat-bridge.sh"
sudo mkdir -p "$DROPIN_DIR"
sudo tee "$DROPIN" >/dev/null <<EOF
[Service]
WorkingDirectory=$NEW
ExecStart=
ExecStart=$NEW/scripts/chat-bridge.sh
EOF
sudo systemctl daemon-reload
sudo systemctl restart clutch-chat-bridge.service
```

The last step is the one that says whether the roll worked.  Check the host the way a phone sees it, with an authorized host-side diagnostic client that reads the service user's chat token into memory and returns only allowlisted health or session-list metadata:  `/clutch/v1/health` and `/clutch/v1/sessions?engine=mcode&limit=5`.  A release that cannot boot crash-loops under `Restart=on-failure`, and the paired clients see a dead host with no signal, so this check is what tells a good roll from a bad one.

When the check fails, roll back to the release that was running before.  Point the drop-in back at it and restart:

```bash
set -euo pipefail
RELEASES=/mnt/fleet-extra/apps/runtime/Clutch/releases
PREVIOUS="$RELEASES/<the-sha-the-roll-replaced>"
sudo mkdir -p /etc/systemd/system/clutch-chat-bridge.service.d
sudo tee /etc/systemd/system/clutch-chat-bridge.service.d/20-clutch-release.conf >/dev/null <<EOF
[Service]
WorkingDirectory=$PREVIOUS
ExecStart=
ExecStart=$PREVIOUS/scripts/chat-bridge.sh
EOF
sudo systemctl daemon-reload
sudo systemctl restart clutch-chat-bridge.service
```

Deleting the drop-in is not a rollback.  It hands the unit back to the mutable checkout, which is the unpinned state this section exists to avoid.  Keep the previous release on disk until the roll has proved itself.

The roll does not prune what it replaces, so the releases directory grows by one tree per roll and every tree carries a dependency tree of its own.  Keep the running release and the one before it, and remove the rest:

```bash
ls -1 /mnt/fleet-extra/apps/runtime/Clutch/releases
sudo rm -rf /mnt/fleet-extra/apps/runtime/Clutch/releases/<sha-to-remove>
```

One trap is left in the export.  `git archive` keeps the executable bit on the tracked scripts, but a blanket `chmod` over the tree strips it and the unit then dies with status 203/EXEC.

### Muse Code On A Server

Current Muse Code builds expose experimental ACP v1 directly through `muse acp`.  The sidecar's `scripts/muse-code-acp.sh` launcher probes that command and prefers it, while keeping the community `@bex-co/muse-code-acp` MSP adapter as the fallback for older builds.

```bash
npm install -g @bex-co/muse-code-acp      # compatibility fallback for older Muse builds
muse login                                # as the service user
```

The launcher defaults to `MUSE_CODE_ACP_BACKEND=auto`, which prefers native ACP only after `MUSE_EXPERIMENTAL_ACP=on muse acp --help` succeeds.  `native` requires that route and `adapter` forces the compatibility adapter.  `MUSE_CODE_EXECUTABLE` pins the Muse binary, while `MUSE_CODE_ACP_BIN` and `MUSE_CODE_ACP_SEARCH_PATHS` control the fallback adapter.

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

The picker only *shows* the catalog's first row; it does not send it.  A thread keeps the model and effort it was created with unless the owner picks another one, so opening an old thread never silently switches its model.

### Attachments

Images ride a turn as base64 data — the phone has no shared filesystem with the server — and the sidecar forwards them as ACP image blocks to MiniMax Code and Muse Code, both of which accept them.  The dsh bridges take no image block, so the sidecar writes the bytes into a per-session directory under `$CLUTCH_HOME/attachments` and names that file in the prompt; the agent opens it with its own read tool.  The name comes from the client, so it is never trusted: only the last path segment survives, and the resolved path is checked against the attachment root before the write.  Attachments live outside the working directory on purpose — an attachment is not a project file, and writing it there would dirty the working tree.  Directories older than a day are pruned when the next attachment is written.

### The Mac App Reaching Another Machine

The Mac app pairs and switches hosts the way the phone does, so a code server on another machine is one click away: the chat surface has a host menu with every paired host plus **Add Host…**, and the same pairing link the phone uses works there.  A paired server host has no web canvas and no dsh host contract behind it, so the Mac shows the code surfaces only — the thread rail, the model and effort pickers, and the composer.

## Verifying The Client Surfaces

The hosted iOS build runs the thread surfaces, not just compiles them: `scripts/ios-ui-tests.sh` resolves a simulator, drives the app against a local stub sidecar (`ios/UITests/StubSidecar.swift`), and keeps a screenshot per state — the thread list, the open thread, and the find bar with a match highlighted.  The result bundle is published as the `ios-ui-screenshots` artifact, so a reviewer sees the surfaces rather than reading about them.  The script skips (exit 10) when the runner image has no simulator runtime, which is not the same as a failing test.

## Troubleshooting

- **`mcode` answers "Internal error" on every turn, but listing threads works:** MiniMax Code refuses to use an OAuth credential file that is not private.  Check `~/.minimax/auth/prod/en/mcode-public/auth.json` is mode 600 for the service user; a group-readable 660 passes silently until a token refresh trips the check.  Listing keeps working because it never touches the credential.
- **Health says `mcode.available: false`:** MiniMax Code is not installed for the service user, or `mcode login` has not been run as that user.
- **Phones get 401:** the pairing link predates the token, or the sidecar was paired from a different `$CLUTCH_HOME`.  Re-run the `--server` pairing and paste the fresh link.
