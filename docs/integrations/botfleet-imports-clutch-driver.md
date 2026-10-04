# BotFleet Imports the DSH Driver from Clutch

**Lane:** `grok/clutch-package` (any seat; this doc is the contract)

**Status:** Ready once `Simple-With-Us/Clutch` is on GitHub and BotFleet
adds the git dependency.

## Goal

Make `Simple-With-Us/BotFleet`'s `server/drivers/acp/dsh.ts` a thin
re-export of this package's `src/dsh/acp/driver.ts`.  BotFleet keeps the
ACP runtime (`acp/core.ts`, `acp/dsh-mcp.ts` glue, the Node stdio bridge
`server/drivers/dsh-acp-bridge.ts`) and composes the Clutch support
shape into a per-engine driver.

## Why

`docs/decisions/0002-acp-core-stays-in-botfleet.md` lays out the
division of labor:

- BotFleet owns the ACP runtime (JSON-RPC client, spawn primitives,
  MCP mount assembler, Node stdio bridge).
- Clutch owns the DSH-specific engine shape (catalog, error
  classifier, version gate, model-id round-trip, credential candidates,
  env contract, install instructions).

## Changes (BotFleet side)

1. `package.json`: add `"clutch": "github:Simple-With-Us/Clutch#main"`.
2. `server/drivers/acp/dsh.ts`: re-export the pure functions from
   `clutch/dsh/acp` and compose `wrapSpawn` locally:

   ```ts
   import {
     dshSupport as clutchDshSupport,
     dshSpawnArgs,
     classifyDshError,
   } from "clutch/dsh/acp";
   import { createAcpDriver, type AcpSupport } from "./core.ts";
   import { dshWrapSpawn } from "./dsh-mcp.ts";

   export const dshSupport: AcpSupport = {
     ...clutchDshSupport,
     wrapSpawn: dshWrapSpawn,
     spawnArgs: dshSpawnArgs,
     classifyError: classifyDshError,
   };
   export const DshAgentDriver = createAcpDriver(dshSupport);
   ```

   Do **not** pass Clutch `dshSupport` straight into `createAcpDriver`.
   Without `wrapSpawn`, stock `dsh` rejects BotFleet MCP mounts.

3. `server/drivers/acp/dsh-mcp.ts`: keep `dshWrapSpawn` (needs
   `SPAWNED_PROXIES.dshAcpBridge`).  Re-export YAML helpers from
   `clutch/dsh/mcp-patch`.
4. Tests keep importing from `./dsh.ts` so the public BF surface does
   not change.  Pure-function assertions still pass because the shim
   re-exports them.
5. Callers of the removed `isStockDshCli` switch to `isDshEngineCli`, which recognises the `dsh` and `clutch` engine stems.
6. `pnpm typecheck && pnpm test`.
7. AGENTS.md: never edit DSH engine shape in BotFleet; edit Clutch.

## Risk

- npm git deps fail in CI when the remote is private.  Clutch is
  public Apache-2.0 so BotFleet CI can fetch it with the default token.
- Packaged BotFleet inlines bare specifiers (`scripts/bundle-server.mjs`);
  confirm the git dep is bundled, not left as `node_modules/clutch`.
