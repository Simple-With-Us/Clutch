# Package Surface

Clutch is an npm package BotFleet and ai-fleet-coordinator consume.  The
GitHub repo is `Simple-With-Us/Clutch`.  Pin it; do not `npx`.

## BotFleet

```json
"dependencies": {
  "clutch": "github:Simple-With-Us/Clutch#main"
}
```

```ts
import { dshSupport, DSH_MINIMUM_ACP_VERSION } from "clutch/dsh/acp";
import { writeDshMcpPatch } from "clutch/dsh/mcp-patch";
import { createAcpDriver } from "./core.ts";
import { dshWrapSpawn } from "./dsh-mcp.ts";

export const DshAgentDriver = createAcpDriver({
  ...dshSupport,
  wrapSpawn: dshWrapSpawn,
});
```

ACP runtime (`createAcpDriver`, spawn, MCP mount assembly, the Node
`dsh-acp-bridge`) stays in BotFleet.  See
`docs/decisions/0002-acp-core-stays-in-botfleet.md`.  Never pass Clutch
`dshSupport` to `createAcpDriver` without composing `wrapSpawn` — stock
`dsh` rejects a non-empty `session/new.mcpServers` list.

Edit engine shape here (`src/dsh/acp/`, `src/minimax/acp/`), or as a drop-in
plugin in the `engines/` directory, loaded by `src/shared/engines/`.  Do not
edit it in BotFleet.

## ai-fleet-coordinator

AFC does not npm-install Clutch.  It registers the app in
`fleet-apps.json` (acronym `CK`), points pm2 `clutch-web` at
`~/apps/clutch-runtime/scripts/start-web.sh` (a standalone clone of this repo),
and keeps `scripts/dsh-runtime/` as a fallback copy of the live-install
scripts.  Canonical scripts live here.

## Exports

| Specifier | File |
|---|---|
| `clutch` | `src/index.ts` |
| `clutch/dsh/acp` | `src/dsh/acp/driver.ts` |
| `clutch/dsh/acp/driver` | same |
| `clutch/dsh/mcp-patch` | `src/dsh/acp/mcp-patch.ts` |
| `clutch/minimax/acp` | `src/minimax/acp/driver.ts` |
| `clutch/minimax/acp/driver` | same |
| `clutch/minimax/http-client` | `src/minimax/http-client/index.ts` |
| `clutch/shared/contracts` | `src/shared/contracts.ts` |
| `clutch/shared/acp-core` | `src/shared/acp-core.ts` |
| `clutch/shared/ports` | `src/shared/ports.ts` |
| `clutch/shared/sanitize-context` | `src/shared/sanitize-context.ts` |
| `clutch/shared/subagent-tool-profiles` | `src/shared/subagent-tool-profiles.ts` |
| `clutch/engines` | `src/shared/engines/index.ts` |
| `clutch/shared/engines` | same |

Python bridges are not TypeScript exports.  Invoke them through
`dsh-acp.sh` / `minimax-acp.sh`.

## Engine Plugins

An engine is a file, not a code change.  Clutch discovers engine plugins at
runtime in two tiers:

- `engines/<id>.engine.json` — declarative.  Maps onto the shared
  `AcpSupport` shape and executes nothing.
- `engines/<id>.engine.mjs` — programmatic.  Exports an `AcpSupport` directly.

Search order, lowest precedence first: `engines/` in the package root (plugins
Clutch ships), then `$CLUTCH_HOME/engines` (per-machine drop-ins, normally
`~/.clutch/engines`).  A later directory overrides an earlier one by `id`; two
files with the same `id` inside the *same* directory are a conflict, not an
override.

`clutch-engines` (`list`, `list --json`, `list --dir DIR`, `paths`) reports what
was discovered.  It exits 1 when any plugin failed to load.
