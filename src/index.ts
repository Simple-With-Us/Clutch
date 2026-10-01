/**
 * Public package surface for `clutch`.
 *
 * Consumers:
 *   import { dshSupport } from "clutch/dsh/acp";
 *   import { writeDshMcpPatch } from "clutch/dsh/mcp-patch";
 *   import { minimaxSupport } from "clutch/minimax/acp";
 */
export * from "./dsh/acp/index.ts";
export {
  DSH_MCP_PATCH_PREFIX,
  dshMcpPatchYaml,
  dshMcpServerName,
  writeDshMcpPatch,
  type DshSpawnRewrite,
  type DshStdioMcpServer,
} from "./dsh/acp/mcp-patch.ts";
export * from "./minimax/acp/index.ts";
export type { AcpSupport, AcpConfig, AcpTurn, AcpInstallInstructions } from "./shared/acp-core.ts";
export type { EffortLevel, ModelCatalog, ProviderErrorCode } from "./shared/contracts.ts";
export { CLUTCH_WEB_PORT_DEFAULT, clutchWebPort } from "./shared/ports.ts";
export * from "./shared/sanitize-context.ts";
export * from "./shared/subagent-tool-profiles.ts";
