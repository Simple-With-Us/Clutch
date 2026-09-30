export {
  STATIC_DSH_MODELS,
  DSH_MINIMUM_ACP_VERSION,
  DSH_PROVIDER_ID,
  DSH_MINIMAX_PROVIDER_ID,
  DshModelNotOfferedError,
  classifyDshError,
  dshCredentialCandidates,
  dshModelIdFromOptionValue,
  dshModelOptionValue,
  dshProviderForModel,
  dshSameModel,
  dshSpawnArgs,
  dshSupport,
  dshVersionCompatibilityReason,
  matchAdvertisedDshModel,
  parseAdvertisedDshModels,
  resolveDshModelOption,
} from "./driver.ts";
export type { DshAdvertisedModel, DshModelMatch, DshResolvedModel } from "./driver.ts";
export { isStockDshCli } from "./mcp-patch.ts";
