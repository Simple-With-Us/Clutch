/**
 * Public package surface for `harness`.
 *
 * Consumers:
 *   import { dshSupport } from "harness/dsh/acp";
 *   import { writeDshMcpPatch } from "harness/dsh/mcp-patch";
 *   import { mmhSupport } from "harness/mmh/acp";
 */
export * from "./dsh/acp/index.ts";
export {
  DSH_MCP_PATCH_PREFIX,
  dshMcpPatchYaml,
  dshMcpServerName,
  isStockDshCli,
  writeDshMcpPatch,
  type DshSpawnRewrite,
  type DshStdioMcpServer,
} from "./dsh/acp/mcp-patch.ts";
export * from "./mmh/acp/index.ts";
export type { AcpSupport, AcpConfig, AcpTurn, AcpInstallInstructions } from "./shared/acp-core.ts";
export type { EffortLevel, ModelCatalog, ProviderErrorCode } from "./shared/contracts.ts";
export * from "./shared/sanitize-context.ts";
export * from "./shared/subagent-tool-profiles.ts";
