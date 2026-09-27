/**
 * MMH driver support — pure engine logic for the MiniMax harness.
 *
 * Shellular MiniMax now spawns `dsh --profile mmh-headless` (coding path
 * with MiniMax as the LLM) via `bridges/mmh/mmh-acp.py`.  This TypeScript
 * module remains the model catalog, error classifier, and env contract for
 * BotFleet / package consumers.  HTTP chat URL helpers in `../http-client`
 * stay for direct API callers; they are no longer the Shellular path.
 *
 * ACP runtime (JSON-RPC client, spawn) stays in BotFleet.  See
 * `docs/decisions/0002-acp-core-stays-in-botfleet.md`.
 */
import type { EffortLevel, ModelCatalog, ProviderErrorCode } from "../../shared/contracts.ts";
import type { AcpSupport } from "../../shared/acp-core.ts";
import {
  MMH_API_KEY_ENV,
  MMH_DEFAULT_MODEL,
  mmhIsAuthenticated,
  mmhTransformEnv,
} from "../http-client/index.ts";

export {
  MMH_API_KEY_ENV,
  MMH_API_KEY_NAME_ENV,
  MMH_CHAT_COMPLETIONS_PATH,
  MMH_DEFAULT_BASE_URL,
  MMH_DEFAULT_MODEL,
  mmhChatCompletionsUrl,
  mmhIsAuthenticated,
  mmhNormalizeBaseUrl,
  mmhTransformEnv,
} from "../http-client/index.ts";

const MMH_EFFORT_LEVELS = ["none"] as const satisfies readonly EffortLevel[];

/**
 * Per-model effort levels for MiniMax models.  MiniMax-M3 advertises the
 * full reasoning-effort range; the M2.7 family stays on the driver default
 * ("none") via fallback.  Adjust the M3 list if the provider documents a
 * different supported set.
 */
const MMH_PER_MODEL_EFFORT_LEVELS = {
  "MiniMax-M3": ["none", "low", "medium", "high", "max"],
} as const satisfies Readonly<Record<string, readonly EffortLevel[]>>;

export function mmhSpawnArgs(): string[] {
  return [];
}

/**
 * Effective effort levels for a MiniMax model id: the per-model override
 * when present, otherwise the driver-wide default.
 */
export function mmhEffortLevelsForModel(modelId: string): readonly EffortLevel[] {
  return MMH_PER_MODEL_EFFORT_LEVELS[modelId as keyof typeof MMH_PER_MODEL_EFFORT_LEVELS] ?? MMH_EFFORT_LEVELS;
}

export const STATIC_MMH_MODELS: ModelCatalog = {
  default: MMH_DEFAULT_MODEL,
  options: [
    { id: "MiniMax-M2.7-highspeed", label: "MiniMax M2.7 Highspeed" },
    { id: "MiniMax-M2.7", label: "MiniMax M2.7", contextWindow: 204_800 },
    { id: "MiniMax-M3", label: "MiniMax M3", contextWindow: 1_000_000 },
  ],
};

export function classifyMmhError(error: unknown): ProviderErrorCode | undefined {
  const message = error instanceof Error ? error.message : String(error ?? "");
  const code = error && typeof error === "object" ? (error as { code?: unknown }).code : undefined;
  const blob = `${code ?? ""} ${message}`.toLowerCase();
  if (/unauthoriz|unauthenticated|invalid api key|invalid_credentials|authentication required|auth.*(fail|missing|required)/.test(blob)) {
    return "invalid_credentials";
  }
  if (/inactive subscription|subscription.*(expired|inactive)|upgrade your (plan|subscription)/.test(blob)) {
    return "inactive_subscription";
  }
  if (/quota|rate.?limit|too many requests|insufficient.?balance|out of credits|credits? exhausted|\b429\b|\b402\b/.test(blob)) {
    return "quota_or_region_restriction";
  }
  if (/overloaded|capacity|service unavailable|bad gateway|upstream|\b502\b|\b503\b|\b504\b/.test(blob)) {
    return "upstream_outage";
  }
  if (/unknown model|model not found|no such model|invalid model/.test(blob)) {
    return "model_catalog_outage";
  }
  return undefined;
}

export const mmhSupport: AcpSupport = {
  driverKind: "mmhAgent",
  displayName: "MiniMax Harness",
  images: false,
  models: STATIC_MMH_MODELS,
  resolveModels: () => STATIC_MMH_MODELS,
  effortLevels: MMH_EFFORT_LEVELS,
  perModelEffortLevels: MMH_PER_MODEL_EFFORT_LEVELS,
  mcpServers: false,
  defaultCli: "mmh-acp.sh",
  nativeSource: "mmh.http",
  loginNote: "MiniMax API key missing — set MINIMAX_API_KEY or MMH_API_KEY_NAME",

  install: {
    command: {
      darwin: "python3 bridges/mmh/mmh-acp.py",
      linux: "python3 bridges/mmh/mmh-acp.py",
      win32: "python bridges/mmh/mmh-acp.py",
    },
    docsUrl: "https://platform.minimax.io",
    needsNode: false,
  },

  spawnArgs: mmhSpawnArgs as AcpSupport["spawnArgs"],
  resumeMethod: "session/resume",
  transformEnv: mmhTransformEnv,
  classifyError: (error: unknown) => classifyMmhError(error),
  credentialEnv: [MMH_API_KEY_ENV, "MMH_API_KEY_NAME", "MMH_BASE_URL", "MMH_MODEL", "MMH_PROFILE"],
  pickAuthMethod: () => null,
  authFailure: "continue",
  isAuthenticated: mmhIsAuthenticated,
  buildPromptText: (turn) => (turn.system ? `${turn.system}\n\n${turn.text}` : turn.text),
};
