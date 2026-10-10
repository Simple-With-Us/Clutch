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

A real turn was run through `scripts/muse-code-acp.sh` against Muse Code
1.4.4-R5419.1 with adapter 0.7.0.  The whole Clutch-side path works: the
launcher resolves the adapter and the host, ACP `initialize` and `session/new`
succeed, a prompt is accepted and submitted, streamed updates arrive, and the
provider is reached.

Captured from `initialize` / `session/new`:

- `promptCapabilities.image` and `mcpCapabilities.http` are true, which is why
  the plugin sets `images` and `mcpServers`.
- `loadSession` is true, so `resumeMethod` is `session/load`.
- The adapter publishes exactly one auth method, an `env_var` one for
  `META_API_KEY`, so the plugin leaves `pickAuthMethod` alone and reports
  authentication from the environment.
- The model option id is `model`, and its wire value is URL-encoded JSON —
  `muse-model:%5B%22meta%22%2Cnull%2C%22muse-spark-1.3-contributor%22%5D` —
  which is why the plugin maps model values exactly instead of by template.
- The catalog is **one model, and that does not change with a login**: it was
  observed identically signed-out and with an authenticated account on this
  Mac.  An earlier draft of this file claimed an account would get a larger
  catalog; that was wrong, and the claim is gone.

**Not verified: a completed model turn.**  The provider rejected the turn with
`not logged in`, because the credential on this Mac is OAuth held in the login
keychain (`~/.config/muse/auth.json` → `mechanism: oauth`, `storage: keychain`)
and the `muse serve` child a GUI-spawned client starts cannot read it.  That is
macOS keychain behaviour, not a Clutch or adapter fault: an interactive
terminal can, a spawned child cannot.  The adapter's own documentation
prescribes the fix — pass `META_API_KEY` for headless use, or store an API key
with `muse auth set --provider meta --api-key-stdin`.

The plugin classifies that exact rejection as `invalid_credentials`, including
when ACP delivers it as a plain `{ code, message }` object rather than an
`Error`.

### Operational notes from the live run

- **Host startup is slow.**  Roughly 27 s to finish initializing and another 10 s
  to prepare before the turn is submitted.  Anything driving this engine needs a
  startup deadline well above the usual ACP defaults.
- **The adapter pins an older host schema.**  It logs a `host schema fingerprint
  differs from the fingerprint this SDK pins` warning and proceeds under
  additive-optional evolution.  It is advisory, and it did not stop the turn.

The reasoning-effort config offers `minimal` and `ultra`, which have no
equivalent in Clutch's shared `EffortLevel` union (`none`, `low`, `medium`,
`high`, `xhigh`, `max`); `max` is not offered at all.  The plugin advertises the
intersection and leaves the rest unmapped.