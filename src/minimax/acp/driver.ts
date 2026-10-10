/**
 * MiniMax driver support — pure engine logic for the Clutch MiniMax bridge.
 *
 * Shellular MiniMax now spawns `dsh --profile minimax-headless` (coding path
 * with MiniMax as the LLM) via `bridges/minimax/minimax-acp.py`.  This TypeScript
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
  MINIMAX_API_KEY_ENV,
  MINIMAX_DEFAULT_MODEL,
  minimaxIsAuthenticated,
  minimaxTransformEnv,
} from "../http-client/index.ts";

export {
  MINIMAX_API_KEY_ENV,
  MINIMAX_API_KEY_NAME_ENV,
  MINIMAX_CHAT_COMPLETIONS_PATH,
  MINIMAX_DEFAULT_BASE_URL,
  MINIMAX_DEFAULT_MODEL,
  minimaxChatCompletionsUrl,
  minimaxIsAuthenticated,
  minimaxNormalizeBaseUrl,
  minimaxTransformEnv,
} from "../http-client/index.ts";

const MINIMAX_EFFORT_LEVELS = ["none"] as const satisfies readonly EffortLevel[];

/**
 * Per-model effort levels for MiniMax models.  MiniMax-M3 advertises the
 * full reasoning-effort range; the M2.7 family stays on the driver default
 * ("none") via fallback.  Adjust the M3 list if the provider documents a
 * different supported set.
 */
const MINIMAX_PER_MODEL_EFFORT_LEVELS = {
  "MiniMax-M3": ["none", "low", "medium", "high", "max"],
} as const satisfies Readonly<Record<string, readonly EffortLevel[]>>;

export function minimaxSpawnArgs(): string[] {
  return [];
}

/**
 * Effective effort levels for a MiniMax model id: the per-model override
 * when present, otherwise the driver-wide default.
 */
export function minimaxEffortLevelsForModel(modelId: string): readonly EffortLevel[] {
  return MINIMAX_PER_MODEL_EFFORT_LEVELS[modelId as keyof typeof MINIMAX_PER_MODEL_EFFORT_LEVELS] ?? MINIMAX_EFFORT_LEVELS;
}

/** Per-model image support, keyed by catalog id.
 *
 *  The installed pi-ai catalog is the authority: it declares MiniMax-M3 as
 *  `input: [text, image]` and the whole M2.7 family as `input: [text]`.  The
 *  M3.1 Flash preview is newer than that catalog, so it is absent from the
 *  installed list and the owner's `settings.yaml` entry is what declares its
 *  modalities; MiniMax ships it as a frontier multimodal model, so it is
 *  image-capable.  A row absent here inherits the engine-wide
 *  {@link minimaxSupport.images} answer. */
export const MINIMAX_PER_MODEL_IMAGES: Readonly<Record<string, boolean>> = {
  "MiniMax-M3.1-Flash-Preview": true,
  "MiniMax-M3": true,
  "MiniMax-M2.7-highspeed": false,
  "MiniMax-M2.7": false,
};

export const STATIC_MINIMAX_MODELS: ModelCatalog = {
  default: MINIMAX_DEFAULT_MODEL,
  options: [
    {
      id: "MiniMax-M3.1-Flash-Preview",
      label: "MiniMax M3.1 Flash Preview",
      contextWindow: 1_000_000,
      badge: "Preview",
      badgeTitle:
        "Frontier multimodal coding model with a 1M context window. MiniMax offers it through Token Plan and MiniMax Code, so it needs a Token Plan key.",
      images: true,
    },
    { id: "MiniMax-M3", label: "MiniMax M3", contextWindow: 1_048_576, images: true },
    {
      id: "MiniMax-M2.7-highspeed",
      label: "MiniMax M2.7 Highspeed",
      contextWindow: 204_800,
      badge: "2x the $",
      badgeTitle:
        "Same 204,800 context as M2.7 at $0.60 / M input and $2.40 / M output — exactly twice MiniMax M3's $0.30 / $1.20.",
      images: false,
    },
    { id: "MiniMax-M2.7", label: "MiniMax M2.7", contextWindow: 204_800, images: false },
  ],
};

export function classifyMinimaxError(error: unknown): ProviderErrorCode | undefined {
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

export const minimaxSupport: AcpSupport = {
  driverKind: "minimaxAgent",
  displayName: "Clutch (MiniMax)",
  images: false,
  models: STATIC_MINIMAX_MODELS,
  resolveModels: () => STATIC_MINIMAX_MODELS,
  effortLevels: MINIMAX_EFFORT_LEVELS,
  perModelEffortLevels: MINIMAX_PER_MODEL_EFFORT_LEVELS,
  perModelImages: MINIMAX_PER_MODEL_IMAGES,
  mcpServers: true,
  defaultCli: "minimax-acp.sh",
  nativeSource: "minimax.http",
  loginNote: "MiniMax API key missing — set MINIMAX_API_KEY or CLUTCH_MINIMAX_API_KEY_NAME",

  install: {
    command: {
      darwin: "python3 bridges/minimax/minimax-acp.py",
      linux: "python3 bridges/minimax/minimax-acp.py",
      win32: "python bridges/minimax/minimax-acp.py",
    },
    docsUrl: "https://platform.minimax.io",
    needsNode: false,
  },

  spawnArgs: minimaxSpawnArgs as AcpSupport["spawnArgs"],
  resumeMethod: "session/resume",
  transformEnv: minimaxTransformEnv,
  classifyError: (error: unknown) => classifyMinimaxError(error),
  credentialEnv: [MINIMAX_API_KEY_ENV, "CLUTCH_MINIMAX_API_KEY_NAME", "CLUTCH_MINIMAX_BASE_URL", "CLUTCH_MINIMAX_MODEL", "CLUTCH_MINIMAX_PROFILE"],
  pickAuthMethod: () => null,
  authFailure: "continue",
  isAuthenticated: minimaxIsAuthenticated,
  buildPromptText: (turn) => (turn.system ? `${turn.system}\n\n${turn.text}` : turn.text),
};
