# Harness

Harness provides a web interface, coding profiles, and ACP bridges around the upstream `@deepseek-ai/dsh` package.  It includes configurations for DeepSeek and MiniMax; available tools and behavior depend on the selected profile, model, and provider.

[App overview on Simple With Us](https://simplewithus.com/harness/) · [Setup](#install) · [Package integration](docs/package.md)

## License

Apache 2.0.  See [`LICENSE`](./LICENSE) and [`NOTICE`](./NOTICE).

## Acknowledgements

This repository includes work derived from, and operates as a friendly
adaptation of, the following upstream and adjacent projects.  The full
attribution record is in [`NOTICE`](./NOTICE); the summary is below.

- **DeepSeek Harness (DSH)** — the upstream `@deepseek-ai/dsh` npm package
  and its source repository at <https://github.com/deepseek-ai/deepseek-harness>.
  Harness is not affiliated with, endorsed by, or sponsored by DeepSeek AI.
  The relationship is one of in-repo derivation: code in this repository
  reads, extends, and configures the upstream binary as a pinned dependency.
  Specific files derived from prior work that wrapped DSH are listed in
  `NOTICE` § "Derived Work — DeepSeek Harness".
- **BotFleet** — the prior host of the DSH ACP driver work.  Files in
  `src/dsh/acp/` were ported from `jaywedgeworth22/BotFleet` on
  2026-09-19; the cross-repo relationship is canonicalization, not
  forking.
- **MiniMax** — provides models and the API at <https://platform.minimax.io>
  used by the MiniMax profiles and HTTP client exports.  No third-party
  MiniMax code is included.

## What you get

- **`src/dsh/`** — DSH harness: full `@deepseek-ai/dsh` CLI + ACP bridge + cordis patch layer.
- **`src/mmh/`** — MMH harness: Shellular MiniMax rides the same `@deepseek-ai/dsh` coding stack as DSH, with MiniMax as the LLM (`mmh-headless` profile).  `bridges/mmh/mmh-acp.py` spawns `dsh --profile mmh-headless` (not a bare chat/completions HTTP call).
- **`src/web/`** — TypeScript web UI scripts (the `start-web.sh`, `serve-tailscale.sh`, `open-harness.sh`, `ensure-web.sh`, `install-dock-app.sh` set, ported from bash to TS).
- **`ios/`** — Native iOS companion app (SwiftUI, iOS 17.0+): multi-host computer connections (local Mac, Tailscale, Hetzner, AWS), full-parity embedded web experience, Composio tools, Fleet RAG integration, and model selection for DeepSeek and MiniMax.  See [`docs/ios-companion.md`](docs/ios-companion.md).
- **`src/profiles/`** — Tracked cordis profile defaults.  Each profile is an independent cordis tree (bundles + empty entry list + patch layer).  Four canonical profiles ship in this repo: `dsh-headless`, `dsh-web`, `mmh-headless`, `mmh-web`.  Profiles configure plugins, tool permissions, thinking effort, turn budgets, and model selection.
- **`bridges/`** — Python stdio JSON-RPC bridges for Shellular, ACP callers, and other agents.  Bridges stay Python intentionally — see `docs/decisions/0001-bridges-stay-python.md`.

## Install

Requires Node.js 22 or later and credentials for the provider you intend to use.

```bash
git clone https://github.com/jaywedgeworth22/Harness.git
cd Harness
npm install
npm run sync      # copy tracked profiles to ~/.dsh/profiles/
bash scripts/harness.sh web --no-open --host 127.0.0.1 --port 3080
npm run typecheck
npm test
```

The command above binds the web interface to your own machine.  The managed `npm run web` entry point in `src/web/` also attempts to configure Tailscale Serve for remote access; review its host settings before using it.  Shell wrappers remain under `scripts/` for existing installations.

## Icons

The public catalog uses the plain [Harness wordmark](assets/harness-wordmark.svg), without a provider logo.  Older MiniMax and DeepSeek variants remain in `assets/` for existing installations; those variants identify provider-specific artwork rather than the public app identity.

## Package

BotFleet and other TypeScript consumers install this repo as an npm git
dependency.  Full export table: [`docs/package.md`](./docs/package.md).

```json
"harness": "github:jaywedgeworth22/Harness#main"
```

```ts
import { dshSupport } from "harness/dsh/acp";
import { writeDshMcpPatch } from "harness/dsh/mcp-patch";
import { mmhSupport } from "harness/mmh/acp";
```

## Consumers

This repository maintains the DSH ACP driver and MMH ACP bridge consumed by BotFleet.  Other TypeScript applications can use the package exports above.

## Product page

The [Harness page on Simple With Us](https://simplewithus.com/harness/) describes current access and links to the source.

Driver and bridge changes belong in this repository.  BotFleet and other consumers import the package exports listed above.

## Provider configurations

The MiniMax headless bridge launches `dsh --profile mmh-headless`, using MiniMax as the model provider within the upstream coding stack.  DeepSeek and MiniMax profiles share parts of that stack, but model responses, provider features, and tool support can differ.

## Why Python for the bridges

The Python bridges handle stdio JSON-RPC, subprocess cleanup, and progress heartbeats.  Keeping those implementations together avoids maintaining a second translation of their process-handling behavior.  See `docs/decisions/0001-bridges-stay-python.md`.

## Per-profile feature depth

Each profile in `src/profiles/<name>/` is fully independent:

- `cordis.yml` — the empty entry list the cordis patch loader applies bundles and patches to
- `cordis.patch.yml` — the patch layer (plugin disables, config overrides, `!!js` expressions)
- `package.json` — the bundle set this profile pulls in (`dsh-base` always; `dsh-web-app` for web profiles; `dsh-headless` for headless profiles)
- `local.patch.yml.example` — a per-machine override template (the operator's lever)

Per-use-case feature depth is open-ended: any profile may independently disable plugins, set thinking effort, set turn budgets, set tool allowlists, override cordis config.  The Harness repo ships the framework and four canonical examples; the operator tunes the matrix on each machine.
