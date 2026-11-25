# Shipped engine plugins

Every file in this directory is an engine Clutch ships.  They are discovered at
runtime by `src/shared/engines/discover.ts`; adding one needs no code change
anywhere else in the repo.

Per-machine drop-ins go in `$CLUTCH_HOME/engines` instead, and override
anything here that claims the same `id`.  Check what resolved with:

```sh
clutch-engines list
```

## minimax

MiniMax reaches Clutch as a coding engine, not as a chat wrapper:
`scripts/minimax-acp.sh` → `bridges/minimax/minimax-acp.py` → `dsh --profile
minimax-headless`, which is the same cordis tool loop the DeepSeek phone path
uses with MiniMax as the model provider.  The bridge's own docstring records why
that replaced the earlier HTTP-only `chat/completions` adapter: the HTTP path had
no local tools and dropped image attachments, so it behaved like the MiniMax chat
web app rather than a coding agent.

Two layers are easy to confuse, so they are worth naming: **Clutch speaks ACP** to
the engine, and **the engine speaks HTTP** to MiniMax from inside its
`llm-pi-ai.providers.minimax` route.  That is why `nativeSource` is `minimax.acp` —
those are the frames on Clutch's side of the pipe.  (It used to read
`minimax.http`, which named the retired adapter and mislabelled native
transcripts.)

### Why this one is a module and not a JSON manifest

`minimax.engine.mjs` is the programmatic tier, which `docs/engine-plugins.md`
reserves for rules that are logic rather than data.  MiniMax has two:

- `CLUTCH_MINIMAX_API_KEY_NAME` is an **indirection** — it names the variable that
  actually holds the key, so one install can carry several providers' keys side by
  side.  `transformEnv` and `isAuthenticated` both have to follow it.  A
  manifest's `spawn.env` sets literal values, and `authenticatedWhen` can only
  test named variables, so neither can express it.
- The launcher already sets every `CLUTCH_MINIMAX_*` default before it execs the
  bridge, so the plugin repeats those defaults only so a *direct* spawn of the
  bridge gets them too.

### Two surfaces, one engine

`engines/minimax.engine.mjs` is what runtime discovery sees.
`src/minimax/acp/driver.ts` is the compiled surface BotFleet imports as
`clutch/minimax/acp/driver`, and it stays that way until it moves.  They describe
the same engine and must not drift, so `tests/minimax-plugin.test.ts` asserts they
agree field by field and behave identically on the env, auth and error paths.
**Change one, change both.**

### What is verified, and what is not

The plugin is a transcription of the compiled driver's behaviour, and the parity
test is what backs that claim — it is not a new live ACP handshake.  The engine
behind it is exercised on the real path by the DeepSeek-profile stack that
`minimax-headless` shares, and a live turn through `scripts/minimax-acp.sh` is
what a future revision should re-run before claiming more than this.

## muse-code

Muse Code is Meta's coding agent.  Current builds expose experimental ACP
v1 directly through `muse acp`; older builds expose MSP through `muse serve`
and need the community `@bex-co/muse-code-acp` adapter.  The Mac app's
saved-login route starts native ACP directly through its bundled desktop
helper and private Python broker.  It does not run Muse in a background
context first to check native support.  With that helper installed, older
Muse versions require `MUSE_CODE_ACP_BACKEND=adapter` explicitly.

```sh
npm install -g @bex-co/muse-code-acp   # fallback for older Muse builds
muse login                             # as the service user
```

Install Muse Code itself separately.  The launcher resolves the `muse`
launcher rather than a versioned `muse-bin-*` and accepts
`MUSE_CODE_ACP_BACKEND=auto|native|adapter` for an explicit compatibility
choice.  Linux, explicit API-key configurations and hosts without the helper
retain native support probing and automatic adapter fallback.

### What is verified, and what is not

Current desktop verification and its Keychain limitations are recorded in
the [desktop-session rollout](../docs/rollouts/2026-10-30-muse-desktop-session.md).  The
results below describe earlier compatibility checks.

Native ACP was verified against Muse Code 1.4.14.  ACP `initialize` and
`session/new` complete through the shipped launcher, the host advertises its
four current models, image prompts, HTTP MCP servers, and device-code login,
and Clutch consumes those options without an adapter.  That native build
explicitly reports no session loading and no reasoning-effort option, so the
host catalog reports both limitations instead of offering controls the agent
would reject.  No paid model turn was run during this compatibility check.

The compatibility route retains its earlier end-to-end evidence.  A real turn
was run through the compatibility backend against Muse Code
1.4.4-R5419.1 with adapter 0.7.0.  The whole Clutch-side path works: the
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

## zcode

Z Code joins `mcode` and `muse` as a code engine, and the engine keeps its own
resumable threads the way the other two do.  Unlike `mcode`, Z Code's CLI has
no ACP command:  `zcode acp` exits with `Unknown command: acp` on every release
(C-129).  The CLI speaks the ZCode Protocol through `zcode app-server --stdio`,
and ACP comes from the `zcode-acp-server` bridge
(<https://github.com/william0wang/zcode-acp>), the same bridge BotFleet's ZCode
ACP engine runs:

```
sidecar (ACP v1 stdio)  ->  zcode-acp-server  ->  zcode app-server --stdio
```

```sh
npm install -g zcode-acp-server   # Node 22 or later
```

The sidecar launches the bridge, not the CLI (`src/web/zcode-acp.ts`).  It
finds the bridge next to the Node it runs on, then in the usual npm prefixes,
then on PATH;  `CLUTCH_ZCODE_ACP_CLI` names one the search missed.  It also
resolves the Z Code CLI the bridge drives (`CLUTCH_ZCODE_CLI`, `~/.local/bin`,
`~/.zcode/bin`, PATH, then the desktop app bundle) and hands the bridge its
real path in `ZCODE_BIN`.  That matters on a Mac:  a CLI launched straight out
of `ZCode.app` cannot find its built-in provider table, the bridge supplies it
only when it can see the real `zcode.cjs`, and a `zcode` symlink on PATH hides
that path.  `CLUTCH_CHAT_LAUNCHER_ZCODE` still overrides the whole launcher.

### Sign-in

The bridge reads the Z Code app's own sign-in (`~/.zcode/v2/config.json`) or
an account saved with `zcode-acp setup --provider zai` (`~/.zcode/v2/acp-accounts.json`),
and never a key from the environment.  The sidecar strips `ANTHROPIC_API_KEY`
and the z.ai and GLM key variables from the bridge's environment, because the
bridge would otherwise let an inherited key override that sign-in and move the
turn off the Coding Plan.  An engine without a sign-in this check can see stays
in the picker with a note, because the app's newer sign-in keeps no key in that
file and the bridge settles it on the first turn.

### Why a manifest and not a module

Everything the plugin has to say about Z Code is data:  one declared model,
generic provider error patterns, the bridge's install line and the sign-in
note.  The launch logic that is not data (the bridge and CLI search, the
environment) lives in the sidecar, so there is no `zcode.engine.mjs`.

### The declared catalog is a placeholder by design

The manifest declares one model (`glm-5.3`) because a manifest must ship a
catalog.  The catalog probe (`src/web/engine-catalog.ts`) includes `zcode` in
its targets:  on the first host with a working bridge, a throwaway
`session/new` reads the engine's own `configOptions` and its list replaces the
declared one, exactly as MiniMax Code's does.  The probe starts the bridge in
the same environment a turn gets, and reads the thinking level from the
bridge's `thought` option (`low`, `high`, `max` for GLM-5.3).  `images` stays
`false` until a live session proves the attachment path.

### Where it runs

Local spawns first, and the remote story is the standard one:  a server host
runs the sidecar with the bridge and the Z Code CLI installed and signed in,
and the apps reach it over Tailscale HTTPS.  See `docs/zcode-server.md`.  There
is no SSH transport in Clutch and this engine adds none.

### What is verified, and what is not

The bridge's behaviour is read off its published source (0.94.0):  the
`zcode-acp-server` bin is the stdio server with no arguments, it launches
`zcode app-server --stdio`, it resolves the CLI from `ZCODE_BIN`, PATH and the
app bundles, and it injects the provider table only for a `.cjs` entry.  The
sidecar's launcher, availability check and spawn environment are covered by
`tests/zcode-acp.test.ts` and `tests/engine-availability.test.ts`.  **Not
verified:  a live turn.**  No host with the Z Code app ran a turn through
Clutch while this was written;  the first one confirms the fix end to end.
