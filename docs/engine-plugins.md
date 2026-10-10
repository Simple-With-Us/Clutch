# Engine Plugins

An engine is a file, not a code change.

Clutch used to enumerate engines in five loosely-coupled places: an
`AcpSupport` const under `src/<engine>/acp/`, a `src/profiles/<name>/`
directory, a `bridges/<name>/` + `scripts/<name>-acp.sh` pair, two
managed-key lists, and hardcoded strings in tests, docs and the iOS app.
Adding an engine meant editing all of them.  A plugin is instead one file that
gets discovered at runtime.

## The two tiers

| Tier | File | Executes code? | Use it when |
| --- | --- | --- | --- |
| Declarative | `engines/<id>.engine.json` | No | The engine speaks ACP (or has an adapter that does) and you only need to describe its catalog, model wire values, error patterns and credentials.  This covers most engines. |
| Programmatic | `engines/<id>.engine.mjs` | Yes | You need real logic — a live model catalog, a bespoke error classifier, a `configureSession` hook.  The module exports an `AcpSupport`. |

Both produce the same thing: an `AcpSupport` record, which is exactly the
interface `createAcpDriver(support)` in BotFleet already consumes.  Nothing
downstream needs to know which tier you used.

## Where plugins live

Lowest precedence first:

1. `engines/` in the package root — plugins Clutch ships.
2. `$CLUTCH_HOME/engines` — per-machine drop-ins, `~/.clutch/engines` by
   default.  This is the directory you edit when you want an engine on this
   Mac without touching the repo.

A later directory overrides an earlier one by `id`, and `clutch-engines list`
prints the file it shadowed.  Two files claiming the same `id` *inside* one
directory is a conflict rather than an override: the first one in sorted order
keeps the id and the second is reported as a problem, because there is no
principled way to say which was meant.

## Checking what you have

```sh
clutch-engines list            # every discovered engine, where it came from
clutch-engines list --json     # machine-readable
clutch-engines paths           # the search path only
clutch-engines list --dir DIR  # also scan DIR, while authoring
```

It exits 1 when any plugin failed to load, so a broken drop-in shows up in a
script or CI instead of silently vanishing from the picker.

## Writing a declarative plugin

```json
{
  "$schema": "clutch.engine/v1",
  "id": "acme",
  "driverKind": "acmeAgent",
  "displayName": "Acme",
  "defaultCli": "acme-acp.sh",
  "nativeSource": "acme.serve",

  "models": {
    "default": "acme-1",
    "options": [{ "id": "acme-1", "label": "Acme 1", "contextWindow": 200000 }]
  },

  "images": true,
  "mcpServers": true,
  "resumeMethod": "session/load",

  "selectModel": { "configId": "model", "advertised": true },
  "errorRules": [{ "pattern": "unauthoriz", "code": "invalid_credentials" }],
  "credentialEnv": ["ACME_API_KEY"],
  "authenticatedWhen": { "anyEnv": ["ACME_API_KEY"] },
  "install": {
    "command": { "darwin": "npm i -g acme-acp", "linux": "npm i -g acme-acp", "win32": "npm i -g acme-acp" },
    "needsNode": true
  }
}
```

`id`, `driverKind`, `displayName`, `defaultCli`, `nativeSource` and `models`
are required.  Every optional key you omit stays *absent* on the resulting
`AcpSupport` rather than present-and-undefined, so a consumer's `if
("mcpServers" in support)` behaves the way it reads.

### The fields that carry a little logic

| Manifest key | Becomes | Notes |
| --- | --- | --- |
| `spawn.args` | `spawnArgs()` | A fresh array per call.  The CLI path itself comes from `AcpConfig.cli`. |
| `spawn.env` | `transformEnv()` | Values override the ambient environment.  Omitted entirely when you declare no env, so `transformEnv` stays undefined. |
| `selectModel.advertised` | `valueForModel()` | Prefer the value the host itself advertised.  Falls back to `values`, then `template`, when it advertised nothing. |
| `selectModel.values` | `valueForModel()` / `modelForValue()` | Exact model-id to wire-value pairs, for engines that do not map one to one. |
| `selectModel.template` | `valueForModel()` / `modelForValue()` | `%model%` stands in for the model id; `modelForValue` reverses it. |
| `errorRules[].pattern` | `classifyError()` | Regex source, matched case-insensitively against the message and code.  First match wins, so order matters. |
| `authenticatedWhen.anyEnv` / `.allEnv` | `isAuthenticated()` | Authenticated when any (or all) of these env vars carry a value. |
| `noAuthNegotiation` | `pickAuthMethod()` | Set it when the engine publishes no ACP `authMethods`.  Leave it off when it does, so the consumer can pick. |
| `promptText` | `buildPromptText()` | `system-then-text` (default) or `text-only`. |

### Write `errorRules` against the shape ACP actually delivers

Errors arrive as plain `{ code, message }` objects far more often than as
`Error` instances, and `String()` on one of those is `"[object Object]"` — the
message is silently lost, so a classifier that only unwraps `Error` matches
nothing and every failure looks unknown.  `classifyError` reads `message` off any
object that has one.  Worth writing a rule against the exact rejection text you
have actually seen from the engine; see `engines/README.md` for a worked
example taken from a live turn.

## Writing a programmatic plugin

```js
// engines/acme.engine.mjs
export default {
  driverKind: "acmeAgent",
  displayName: "Acme",
  defaultCli: "acme-acp.sh",
  nativeSource: "acme.serve",
  models: { default: "acme-1", options: [{ id: "acme-1", label: "Acme 1" }] },
  spawnArgs: (config) => ["--profile", config.cli],
  resolveModels: async (env) => fetchCatalog(env),
};
```

`export default support` and `export const support` both work.  A module is
only checked for the required shape — it hands back a real `AcpSupport`, so
TypeScript is not in the loop.  Put it in `$CLUTCH_HOME/engines` only if you
trust the file as much as you trust the repo.

## The launcher

`defaultCli` names a launcher script in `scripts/`, following the existing
`scripts/<id>-acp.sh` convention that Shellular and BotFleet already resolve.
Two rules the existing engines follow:

- **Stdout is JSON-RPC only.**  Every diagnostic goes to stderr.
- **Do not source `lib/clutch-env.sh`** unless the engine is dsh.  Sourcing it
  creates and forces `$CLUTCH_HOME/dsh`, an engine home a non-dsh engine never
  touches.  `grok-acp.sh` and `muse-code-acp.sh` both stay out of it, and
  `tests/clutch-cli-and-images.test.ts` holds that line.

## When you still need a profile

A plugin covers an engine reached over ACP.  If the engine has to run *inside*
dsh's cordis loop, you also need `src/profiles/<name>/` — the profile stays a
directory scan (`scripts/sync-profiles.ts` never had an enum), but
`tests/profiles.test.ts` asserts the exact list of profile names, so adding one
is still a code change.  Muse Code needs no profile: it is not a dsh profile
consumer at all.

## What a plugin does not cover

Being honest about the edges keeps a plugin from being blamed for something it
was never going to do:

- **The web UI model picker.**  The web surface is upstream dsh's own bundle
  inside a `WKWebView`; Clutch decorates it through injected JavaScript in
  `src/web/dock-app/ClutchWindow.swift`.  A new engine appears there only if a
  brand mark and picker branch are added by hand.
- **The iOS app.**  `ios/App/Views/ChatView.swift` holds a hardcoded model
  button list, and `ios/UITests/ClutchLiveUITests.swift` asserts on it.
- **Managed settings.**  If your engine needs a key in the Infisical schema, it
  has to be added to `src/shared/clutchSettings.ts` *and*
  `scripts/lib/clutch-infisical-env.sh`; no generator keeps those two in sync.
- **Token usage.**  `AcpSupport` has no usage hook, and the Muse adapter
  reports usage as unavailable.

## See also

- `docs/decisions/0006-engines-are-drop-in-files.md` — why this shape.
- `engines/README.md` — what ships today.
- `src/shared/engines/manifest.ts` — the full field list and validator.
- `tests/engine-plugins.test.ts` — the behaviour this document promises.