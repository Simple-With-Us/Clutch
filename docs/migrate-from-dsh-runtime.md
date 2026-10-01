# Migration: dsh-runtime → Harness

> **Forward Note (2026-09-30):**  This product is now named Clutch.  The repo is `jaywedgeworth22/Clutch`, the live install is the standalone clone `~/apps/clutch-runtime`, and engine state lives in `~/.clutch/dsh`.  See `docs/decisions/0005-rename-harness-to-clutch.md`.  The record below is kept as written.

The `~/apps/dsh-runtime/` install was the live DeepSeek Harness web UI on
this Mac.  On 2026-09-19 it was renamed to `~/apps/harness-runtime/` and
became a symlink to `~/Code/Harness/`.  This document is the migration
record.

## What moved

| Was | Is now |
|---|---|
| `~/apps/dsh-runtime/` (live install) | `~/apps/harness-runtime/` (symlink → `~/Code/Harness/`) |
| `~/apps/dsh-runtime/start-web.sh` | `~/apps/harness-runtime/scripts/start-web.sh` (root shim also) |
| `~/apps/dsh-runtime/serve-tailscale.sh` | `~/apps/harness-runtime/scripts/serve-tailscale.sh` |
| `~/apps/dsh-runtime/open-harness.sh` | `~/apps/harness-runtime/scripts/open-harness.sh` |
| `~/apps/dsh-runtime/ensure-web.sh` | `~/apps/harness-runtime/scripts/ensure-web.sh` |
| `~/apps/dsh-runtime/install-dock-app.sh` + `HarnessWindow.swift` | `scripts/install-dock-app.sh` + `src/web/dock-app/HarnessWindow.swift` |
| `~/apps/dsh-runtime/dsh-acp.sh` + `dsh-acp.py` | `dsh-acp.sh` + `bridges/dsh/dsh-acp.py` |
| `~/.dsh/profiles/headless/` | `~/.dsh/profiles/dsh-headless/` (renamed) |
| `~/.dsh/settings-headless.yaml` | `~/.dsh/settings-dsh-headless.yaml` |
| (new) | `~/.dsh/profiles/mmh-headless/` + `mmh-web/` |
| `~/apps/dsh-runtime/mmh-acp.sh` + `mmh-acp.py` | `~/apps/harness-runtime/mmh-acp.sh` + `bridges/mmh/mmh-acp.py` |

## What broke (and how it was fixed)

The live web UI at `https://macbook.boa-roygbiv.ts.net:3080` was failing
to boot with the message:

```
Harness
Failed to load plugins
client-modules: boot manifest batches must be an array
```

Root cause: the headless cordis patch (12 disabled plugin rows) was being
applied to the web profile too, via the cordis patch cascade loader.
Upstream `compose()` drops the `batches` array when activation fails on
enough entries (see `deepseek-harness/discussions/3472` and `#4955`).

Fix: rename `~/.dsh/profiles/headless/` to `~/.dsh/profiles/dsh-headless/`
and update the dsh-acp.py to pass `--profile dsh-headless`.  The patch is
now scoped to its own profile directory and does not leak into the web
profile.

After the rename + pm2 restart, the live `:3080` boot manifest reports
53 entries and 2 batches (bootstrap + application), matching a clean
profile's expected shape.

## What changed in Shellular

`~/.shellular/agents.json` gained a new entry:

```json
{
  "id": "minimax",
  "name": "MiniMax",
  "title": "MiniMax",
  "command": "/Users/jay/apps/harness-runtime/mmh-acp.sh",
  "args": [],
  "env": {
    "DSH_HOME": "/Users/jay/.dsh",
    "MMH_API_KEY_NAME": "MINIMAX_API_KEY",
    "MMH_PROFILE": "mmh-headless"
  },
  "cwd": "/Users/jay/Code"
}
```

The existing `deepseek` entry gained one line:

```json
"DSH_PROFILE": "dsh-headless"
```

## Rollback

If anything in the new install misbehaves:

```bash
# Restore the prior install
rm ~/apps/harness-runtime  # if it's a symlink
mv ~/apps/dsh-runtime.bak-2026-09-19 ~/apps/dsh-runtime
# Restore the prior profile directory
mv ~/.dsh/profiles/dsh-headless ~/.dsh/profiles/headless
mv ~/.dsh/settings-dsh-headless.yaml ~/.dsh/settings-headless.yaml
# Revert ~/.shellular/agents.json from git history
# Restart pm2 dsh-web
pm2 restart dsh-web
```

The `dsh-runtime.bak-2026-09-19/` directory contains the full prior install
(`node_modules/`, `package.json`, `package-lock.json`, all bridge files).
It is the recovery path until the new install is verified stable.
