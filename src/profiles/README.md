# Profiles

Tracked cordis profile defaults.  Each profile is a fully independent cordis
tree (bundles + empty entry list + patch layer).  Two profiles ship in this
repo, one per Shellular agent id:

| Profile | Bundles | Use case |
|---|---|---|
| `deepseek-headless/` | `dsh-base` + `dsh-headless` | DeepSeek on the dsh engine, headless (phone, Shellular id `deepseek`) |
| `minimax-headless/` | `dsh-base` + `dsh-headless` | MiniMax on the dsh engine, headless (phone, Shellular id `minimax`; MiniMax LLM + local tools) |

The web UI boots upstream's shipped `web` profile, so it has no tracked
profile here.

## Sync

`scripts/sync-profiles.ts` copies each profile directory to
`$CLUTCH_HOME/dsh/profiles/<name>/` (default `~/.clutch/dsh/profiles/`) and
writes the matching `$CLUTCH_HOME/dsh/settings-<name>.yaml` when present.  The
vanilla `~/.dsh` is never touched.  Tracked patch files refer to the engine
home as `__DSH_HOME__`, which the sync replaces with the real path, so no
tracked file is machine-specific.  Run via `npm run sync` after every
`npm ci` and every profile change.

A per-machine override file (`<engine home>/profiles/<name>/local.patch.yml`)
wins over the tracked default — the cordis patch loader applies the cascade
in order: bundles → tracked patch → local patch.

## Per-profile feature depth

The matrix is open-ended.  Any profile may independently:

- Disable plugins (`disabled: true`)
- Override plugin config (`thinking`, `reasoningEffort`, `model`)
- Set turn budgets (in the bridge file, not the cordis patch — bridges
  read env, profiles set up the engine)
- Set tool allowlists (in the registry, not the cordis patch — registry
  is the consumer-side gate)
- Pin a model for that profile only

The shipped profiles are starting points, not final configurations.
Operators tune the matrix on each machine.

## Adding a profile

```bash
mkdir -p src/profiles/<provider>-<use-case>
# Copy cordis.yml + cordis.patch.yml + package.json + pnpm-workspace.yaml
# from the closest existing profile
# Edit package.json to set the bundle list
# Edit cordis.patch.yml to set the patch layer
# Add settings-<name>.yaml if the profile needs a settings override
```

Then `npm run sync` to push it to `~/.clutch/dsh/profiles/`.  Restart any pm2
job that uses the new profile so the cordis patch loader picks it up.
