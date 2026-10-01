# Package Surface

Clutch is an npm package BotFleet and ai-fleet-coordinator consume.  The
GitHub repo is `jaywedgeworth22/Clutch`.  Pin it; do not `npx`.

## BotFleet

```json
"dependencies": {
  "clutch": "github:jaywedgeworth22/Clutch#main"
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

Edit engine shape here (`src/dsh/acp/`, `src/minimax/acp/`).  Do not edit
it in BotFleet.

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

Python bridges are not TypeScript exports.  Invoke them through
`dsh-acp.sh` / `minimax-acp.sh`.
