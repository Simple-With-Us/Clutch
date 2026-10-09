# Clutch

Clutch provides a web interface, coding profiles, and ACP bridges around the upstream `@deepseek-ai/dsh` package.  It includes configurations for DeepSeek, MiniMax, and Muse Code; available tools and behavior depend on the selected profile, model, and provider.  Engines beyond those can be dropped in as files under [`engines/`](./engines).

[Clutch.Codes](https://clutch.codes) · [Source](https://github.com/Simple-With-Us/Clutch) · [Setup](#install) · [Package integration](docs/package.md)

## License

Apache 2.0.  See [`LICENSE`](./LICENSE) and [`NOTICE`](./NOTICE).

## Acknowledgements

This repository includes work derived from, and operates as a friendly
adaptation of, the following upstream and adjacent projects.  The full
attribution record is in [`NOTICE`](./NOTICE); the summary is below.

- **DeepSeek Harness (DSH)** — the upstream `@deepseek-ai/dsh` npm package
  and its source repository at <https://github.com/deepseek-ai/deepseek-harness>.
  Clutch is not affiliated with, endorsed by, or sponsored by DeepSeek AI.
  The relationship is one of in-repo derivation: code in this repository
  reads, extends, and configures the upstream binary as a pinned dependency.
  Specific files derived from prior work that wrapped DSH are listed in
  `NOTICE` § "Derived Work — DeepSeek Harness".
- **BotFleet** — the prior host of the DSH ACP driver work.  Files in
  `src/dsh/acp/` were ported from `Simple-With-Us/BotFleet` on
  2026-09-19; the cross-repo relationship is canonicalization, not
  forking.
- **MiniMax** — provides models and the API at <https://platform.minimax.io>
  used by the MiniMax profiles and HTTP client exports.  No third-party
  MiniMax code is included.
- **Muse Code and Muse Spark** — Meta products, documented at
  <https://dev.meta.ai/docs/muse-code/>.  Clutch is not affiliated with,
  endorsed by, or supported by Meta.
- **`@bex-co/muse-code-acp`** — the unofficial community adapter the Muse Code
  engine plugin depends on, Apache 2.0 and maintained outside Meta.  Muse Code
  is not itself an ACP agent: `muse serve` speaks MSP (Muse Session Protocol)
  and this adapter translates MSP to ACP on stdio.  Clutch installs it at
  runtime and vendors none of its code.

## What You Get

- **`src/dsh/`** — DSH engine layer: full `@deepseek-ai/dsh` CLI + ACP bridge + cordis patch layer.
- **`src/minimax/`** — The Clutch MiniMax bridge: Shellular MiniMax rides the same `@deepseek-ai/dsh` coding stack as DSH, with MiniMax as the LLM (`minimax-headless` profile).  `bridges/minimax/minimax-acp.py` spawns `dsh --profile minimax-headless` (not a bare chat/completions HTTP call).
- **`src/web/`** — TypeScript web UI scripts (the `start-web.sh`, `serve-tailscale.sh`, `open-clutch.sh`, `ensure-web.sh`, `install-dock-app.sh` set, ported from bash to TS).
- **`ios/`** — Native iOS companion app (SwiftUI, iOS 17.0+): multi-host computer connections (local Mac, Tailscale, Hetzner, AWS), full-parity embedded web experience, Composio tools, Fleet RAG integration, and model selection for DeepSeek and MiniMax.  See [`docs/ios-companion.md`](docs/ios-companion.md).
- **`src/profiles/`** — Tracked cordis profile defaults.  Each profile is an independent cordis tree (bundles + empty entry list + patch layer).  Two profiles ship in this repo, one per Shellular agent id: `deepseek-headless` and `minimax-headless`.  Profiles configure plugins, tool permissions, thinking effort, turn budgets, and model selection.
- **`bridges/`** — Python stdio JSON-RPC bridges for Shellular, ACP callers, and other agents.  Bridges stay Python intentionally — see `docs/decisions/0001-bridges-stay-python.md`.
- **`engines/`** — Drop-in engine plugins, discovered at runtime: adding an engine is a file, not a code change.  Two tiers — `engines/<id>.engine.json` (declarative; maps onto the shared ACP support shape and executes nothing) and `engines/<id>.engine.mjs` (programmatic; exports the support shape directly).  Clutch searches the package `engines/` directory first, then `$CLUTCH_HOME/engines` (`~/.clutch/engines`), so a per-machine file can override a shipped one by `id`; two files claiming the same `id` in the same directory are a conflict, not an override.  `clutch-engines list` shows what loaded and what failed.  Muse Code ships as the first engine plugin.

## Install

Requires Node.js 22 or later and credentials for the provider you intend to use.

```bash
git clone https://github.com/Simple-With-Us/Clutch.git
cd Clutch
npm install
npm run sync      # copy tracked profiles to ~/.clutch/dsh/profiles/
bash scripts/clutch.sh web --no-open --host 127.0.0.1 --port 3180
npm run typecheck
npm test
```

The command above binds the web interface to your own machine.  The managed `npm run web` entry point in `src/web/` also attempts to configure Tailscale Serve for remote access; review its host settings before using it.  Shell wrappers live under `scripts/`.  Clutch keeps its engine state in `~/.clutch/dsh` and serves on port 3180, so vanilla `dsh` (state in `~/.dsh`, web on 3080) runs alongside it untouched.

## Icons

The public catalog uses the plain [Clutch wordmark](assets/clutch-wordmark.svg), without a provider logo.  Older MiniMax and DeepSeek variants remain in `assets/` for existing installations; those variants identify provider-specific artwork rather than the public app identity.

## Package

BotFleet and other TypeScript consumers install this repo as an npm git
dependency.  Full export table: [`docs/package.md`](./docs/package.md).

```json
"clutch": "github:Simple-With-Us/Clutch#main"
```

```ts
import { dshSupport } from "clutch/dsh/acp";
import { writeDshMcpPatch } from "clutch/dsh/mcp-patch";
import { minimaxSupport } from "clutch/minimax/acp";
import { loadEnginePlugins } from "clutch/engines";
```

## Consumers

This repository maintains the DSH ACP driver and MiniMax ACP bridge consumed by BotFleet.  Other TypeScript applications can use the package exports above.

## Product Page

The product site is [clutch.codes](https://clutch.codes), and the source lives at [github.com/Simple-With-Us/Clutch](https://github.com/Simple-With-Us/Clutch).

Driver and bridge changes belong in this repository.  BotFleet and other consumers import the package exports listed above.

## Provider Configurations

The MiniMax headless bridge launches `dsh --profile minimax-headless`, using MiniMax as the model provider within the upstream coding stack.  DeepSeek and MiniMax profiles share parts of that stack, but model responses, provider features, and tool support can differ.

Muse Code is a different shape of engine.  It is a Meta coding agent that is not part of the DeepSeek stack, and it has no Python bridge: `scripts/muse-code-acp.sh` execs the community `@bex-co/muse-code-acp` adapter directly, making it the first engine in this repo with zero bridge code.  It needs a Meta account — `muse login`, or `META_API_KEY` for headless use.

Two honest limits on the Muse Code plugin, both visible in `engines/muse-code.engine.json`:

- **The model catalog is a floor, not the truth.**  Muse Code serves its real catalog over ACP, so the static catalog in the manifest is a fallback.  The machine it was captured on had no Meta account, so only one model was reachable; that option carries an "Unverified" badge and should not be read as the complete list.
- **Effort tiers are the intersection, not the full Muse range.**  Muse offers `minimal` and `ultra` tiers that have no equivalent in Clutch's shared effort levels, so the plugin advertises only the tiers both sides have: `none`, `low`, `medium`, `high`, `xhigh`.

## Why Python for the Bridges

The Python bridges handle stdio JSON-RPC, subprocess cleanup, and progress heartbeats.  Keeping those implementations together avoids maintaining a second translation of their process-handling behavior.  See `docs/decisions/0001-bridges-stay-python.md`.  Not every engine needs one: Muse Code ships as an engine plugin with no bridge code at all.

## Per-Profile Feature Depth

Each profile in `src/profiles/<name>/` is fully independent:

- `cordis.yml` — the empty entry list the cordis patch loader applies bundles and patches to
- `cordis.patch.yml` — the patch layer (plugin disables, config overrides, `!!js` expressions)
- `package.json` — the bundle set this profile pulls in (`dsh-base` plus `dsh-headless` for the headless profiles)
- `local.patch.yml.example` — a per-machine override template (the operator's lever)

Per-use-case feature depth is open-ended: any profile may independently disable plugins, set thinking effort, set turn budgets, set tool allowlists, override cordis config.  The Clutch repo ships the framework and two canonical examples, `deepseek-headless` and `minimax-headless`; the operator tunes the matrix on each machine.
