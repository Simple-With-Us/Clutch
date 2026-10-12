/**
 * Clutch MiniMax — drop-in engine plugin (programmatic tier).
 *
 * MiniMax reaches Clutch as `scripts/minimax-acp.sh` → `bridges/minimax/minimax-acp.py`
 * → `dsh --profile minimax-headless`, so it is a real coding engine with the dsh
 * cordis tool loop and MiniMax as the model provider.  This file is the engine
 * shape: catalog, capability flags, effort levels, credentials and error
 * classification, in the form `createAcpDriver(support)` already consumes.
 *
 * **Why the programmatic tier and not `minimax.engine.json`.**  A declarative
 * manifest can express a catalog, wire values and error patterns, but two of
 * MiniMax's rules are not data:
 *
 *   - `CLUTCH_MINIMAX_API_KEY_NAME` is an indirection.  It names the variable
 *     that actually holds the key (`MINIMAX_API_KEY` unless the operator points
 *     it elsewhere), and both `transformEnv` and `isAuthenticated` have to
 *     follow it.  A manifest's `spawn.env` sets literal values and
 *     `authenticatedWhen` can only test named variables, so neither can
 *     reproduce the indirection.
 *   - `scripts/minimax-acp.sh` already sets every `CLUTCH_MINIMAX_*` default
 *     before it execs the bridge, so the plugin does not re-derive defaults the
 *     launcher owns.
 *
 * That is exactly the case `docs/engine-plugins.md` reserves this tier for.
 *
 * **This file and `src/minimax/acp/driver.ts` describe the same engine.**  The
 * driver is the compiled surface BotFleet imports (`clutch/minimax/acp/driver`)
 * and stays that way until it moves; this file is what runtime discovery sees.
 * They must not drift, so `tests/minimax-plugin.test.ts` asserts the two agree
 * field by field and behave identically.  Change one, change both.
 */

const MINIMAX_API_KEY_ENV = "MINIMAX_API_KEY";
const MINIMAX_API_KEY_NAME_ENV = "CLUTCH_MINIMAX_API_KEY_NAME";
const MINIMAX_DEFAULT_BASE_URL = "https://api.minimax.io/v1";
const MINIMAX_DEFAULT_MODEL = "MiniMax-M2.7-highspeed";

/** Engine-wide effort levels.  M3 overrides this with its own list; every other
 *  row keeps the driver default of `none` because the provider takes the level
 *  through `output_config.effort` and the M2.7 family has no extra budgets to
 *  offer. */
const EFFORT_LEVELS = ["none"];

/** Per-model effort overrides.  MiniMax-M3 advertises the full reasoning range;
 *  the M2.7 family stays on `none` by falling back to {@link EFFORT_LEVELS}. */
const PER_MODEL_EFFORT_LEVELS = {
  "MiniMax-M3": ["none", "low", "medium", "high", "max"],
};

/** Per-model image support.  These are provider facts, not preferences: the
 *  installed pi-ai catalog declares MiniMax-M3 as `input: [text, image]` and the
 *  whole M2.7 family as text-only.  M3.1 Flash is newer than that catalog, so it
 *  is absent from it; MiniMax ships it as a frontier multimodal model, so it is
 *  image-capable here. */
const PER_MODEL_IMAGES = {
  "MiniMax-M3.1-Flash-Preview": true,
  "MiniMax-M3": true,
  "MiniMax-M2.7-highspeed": false,
  "MiniMax-M2.7": false,
};

const MODELS = {
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

/**
 * The name of the variable that actually holds the key.  The operator can point
 * this at any variable — that is how one install can hold several providers'
 * keys side by side — so nothing here may assume it is `MINIMAX_API_KEY`.
 */
function credentialEnvName(env) {
  return env[MINIMAX_API_KEY_NAME_ENV] || MINIMAX_API_KEY_ENV;
}

/**
 * Authenticated when the key the operator named carries a value.  `MINIMAX_API_KEY`
 * is also accepted directly, so a plain install authenticates without having to
 * configure the indirection first.
 */
function isAuthenticated(env) {
  return Boolean(env[credentialEnvName(env)] || env[MINIMAX_API_KEY_ENV]);
}

/**
 * The env contract the Python bridge shares.  These are the defaults an operator
 * may override, not the launcher's: `scripts/minimax-acp.sh` sets the same keys
 * before it execs the bridge, so a direct spawn of the bridge gets them too.
 */
function transformEnv(env) {
  if (!env.CLUTCH_MINIMAX_BASE_URL) env.CLUTCH_MINIMAX_BASE_URL = MINIMAX_DEFAULT_BASE_URL;
  if (!env.CLUTCH_MINIMAX_MODEL) env.CLUTCH_MINIMAX_MODEL = MINIMAX_DEFAULT_MODEL;
  if (!env[MINIMAX_API_KEY_NAME_ENV]) env[MINIMAX_API_KEY_NAME_ENV] = MINIMAX_API_KEY_ENV;
}

/**
 * Read the text worth matching off whatever ACP rejected with.  A turn often
 * arrives as a plain `{ code, message }` object rather than an `Error`, and
 * `String()` on one of those is `"[object Object]"`, which silently loses the
 * only signal there is.
 */
function errorBlob(error) {
  const message =
    error instanceof Error
      ? error.message
      : typeof error === "object" && error !== null && typeof error.message === "string"
        ? error.message
        : String(error ?? "");
  const code = error && typeof error === "object" ? error.code : undefined;
  return `${code ?? ""} ${message}`.toLowerCase();
}

const INVALID_CREDENTIALS =
  /unauthoriz|unauthenticated|invalid api key|invalid_credentials|authentication required|auth.*(fail|missing|required)/;
const INACTIVE_SUBSCRIPTION = /inactive subscription|subscription.*(expired|inactive)|upgrade your (plan|subscription)/;
const QUOTA =
  /quota|rate.?limit|too many requests|insufficient.?balance|out of credits|credits? exhausted|\b429\b|\b402\b/;
const UPSTREAM = /overloaded|capacity|service unavailable|bad gateway|upstream|\b502\b|\b503\b|\b504\b/;
const MODEL_CATALOG = /unknown model|model not found|no such model|invalid model/;

/**
 * Map MiniMax failure text onto the canonical provider-error codes, so the
 * fallback chain treats a quota or auth failure like every other engine instead
 * of as a generic rpc_error.  First match wins, and credential and subscription
 * failures are tested before quota because their text overlaps.
 */
function classifyError(error) {
  const blob = errorBlob(error);
  if (INVALID_CREDENTIALS.test(blob)) return "invalid_credentials";
  if (INACTIVE_SUBSCRIPTION.test(blob)) return "inactive_subscription";
  if (QUOTA.test(blob)) return "quota_or_region_restriction";
  if (UPSTREAM.test(blob)) return "upstream_outage";
  if (MODEL_CATALOG.test(blob)) return "model_catalog_outage";
  return undefined;
}

export const support = {
  driverKind: "minimaxAgent",
  displayName: "Clutch (MiniMax)",
  // Closed at the engine level until a consumer folds perModelImages onto the
  // catalog: a consumer reading only this flag must not offer an attachment the
  // M2.7 family would refuse.
  images: false,
  perModelImages: PER_MODEL_IMAGES,
  models: MODELS,
  resolveModels: () => MODELS,
  effortLevels: EFFORT_LEVELS,
  perModelEffortLevels: PER_MODEL_EFFORT_LEVELS,
  mcpServers: true,
  defaultCli: "minimax-acp.sh",
  // ACP at the edge, HTTP underneath: these frames are JSON-RPC to
  // `dsh --profile minimax-headless`, and the engine reaches MiniMax's API from
  // inside its own pi-ai provider route rather than through Clutch.
  nativeSource: "minimax.acp",
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

  // The launcher script carries the whole spawn contract (profile selection,
  // permission mode, timeouts), so the ACP CLI takes no arguments of its own.
  spawnArgs: () => [],
  resumeMethod: "session/resume",
  transformEnv,
  classifyError,
  credentialEnv: [
    MINIMAX_API_KEY_ENV,
    "CLUTCH_MINIMAX_API_KEY_NAME",
    "CLUTCH_MINIMAX_BASE_URL",
    "CLUTCH_MINIMAX_MODEL",
    "CLUTCH_MINIMAX_PROFILE",
  ],
  // The bridge publishes no ACP authMethods, so negotiation always returns
  // nothing and the key comes from the environment instead.
  pickAuthMethod: () => null,
  authFailure: "continue",
  isAuthenticated,
  buildPromptText: (turn) => (turn.system ? `${turn.system}\n\n${turn.text}` : turn.text),
};

export default support;