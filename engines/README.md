# Shipped engine plugins

Every file in this directory is an engine Clutch ships.  They are discovered at
runtime by `src/shared/engines/discover.ts`; adding one needs no code change
anywhere else in the repo.

Per-machine drop-ins go in `$CLUTCH_HOME/engines` instead, and override
anything here that claims the same `id`.  Check what resolved with:

```sh
clutch-engines list
```

## muse-code

Muse Code is Meta's coding agent.  It is **not** an ACP agent: `muse serve`
speaks MSP (the Muse Session Protocol) over stdio.  The community adapter
`@bex-co/muse-code-acp` translates MSP to ACP, and `scripts/muse-code-acp.sh`
execs that adapter — so this engine needs no Python bridge, the first in the
repo whose launcher is pure pass-through.

```sh
npm install -g @bex-co/muse-code-acp   # the adapter
muse login                             # or set META_API_KEY for headless use
```

Install Muse Code itself separately.  The launcher resolves the `muse` launcher
rather than a versioned `muse-bin-*`, because the adapter's own documentation
notes that pinning an old launcher cache does not survive its update-and-prune
cycle.

### What is verified, and what is not

Captured from a live `initialize` / `session/new` handshake against Muse Code
1.4.4-R5419.1 with adapter 0.7.0:

- `promptCapabilities.image` and `mcpCapabilities.http` are true, which is why
  the plugin sets `images` and `mcpServers`.
- `loadSession` is true, so `resumeMethod` is `session/load`.
- The adapter publishes exactly one auth method, an `env_var` one for
  `META_API_KEY`, so the plugin leaves `pickAuthMethod` alone and reports
  authentication from the environment.
- The model option id is `model`, and its wire value is URL-encoded JSON —
  `muse-model:%5B%22meta%22%2Cnull%2C%22muse-spark-1.3-contributor%22%5D` —
  which is why the plugin maps model values exactly instead of by template.

**Not verified:** this Mac has no Meta account, so the only model reachable is
`muse-spark-1.3-contributor` and no real turn has been run.  The static catalog
is a floor, not the truth — Muse Code serves its real catalog over ACP (`/models`
refreshes it before a turn), and an authenticated account gets a larger one.  The
model option therefore carries an `Unverified` badge rather than pretending.

The reasoning-effort config offers `minimal` and `ultra`, which have no
equivalent in Clutch's shared `EffortLevel` union (`none`, `low`, `medium`,
`high`, `xhigh`, `max`); `max` is not offered at all.  The plugin advertises the
intersection and leaves the rest unmapped.