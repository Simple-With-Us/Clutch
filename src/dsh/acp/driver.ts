/**
 * DSH driver support — pure engine logic.
 *
 * This module owns every DSH-specific knob: model catalog, version gate,
 * error classification, credential candidates, model-id round-trip, env
 * contract, install instructions, prompt composition.  Anything DSH-shaped
 * that doesn't depend on the ACP runtime lives here.
 *
 * The ACP runtime primitives — the ACP JSON-RPC client, the spawn
 * wrapper, the MCP mount assembler — stay in BotFleet (`acp/core.ts`,
 * `acp/dsh-mcp.ts`).  BotFleet imports this module and composes the two:
 *
 *     import { dshSupport, DSH_MINIMUM_ACP_VERSION } from "clutch/dsh/acp/driver";
 *     import { createAcpDriver } from "../acp/core";
 *     export const DshAgentDriver = createAcpDriver(dshSupport);
 *
 * That keeps the ACP runtime in one place (BotFleet) and the DSH engine
 * shape in one place (Clutch).  See
 * `docs/decisions/0002-acp-core-stays-in-botfleet.md` for the long-term
 * plan to lift the ACP core too.
 */
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

import type { EffortLevel, ModelCatalog, ProviderErrorCode } from "../../shared/contracts.ts";
import type { AcpSupport } from "../../shared/acp-core.ts";
import { isDshEngineCli } from "./mcp-patch.ts";
import { DshModelNotOfferedError, dshCanonicalWireModelId, resolveDshModelOption } from "./model-options.ts";

export { isDshEngineCli } from "./mcp-patch.ts";
export {
  DshModelNotOfferedError,
  dshCanonicalWireModelId,
  dshSameModel,
  matchAdvertisedDshModel,
  parseAdvertisedDshModels,
  resolveDshModelOption,
} from "./model-options.ts";
export type { DshAdvertisedModel, DshModelMatch, DshResolvedModel } from "./model-options.ts";

/** Current DSH exposes its standard ACP v1 server as a profile.  Core still
 * puts BotFleet mounts in session/new.mcpServers.  Stock dsh-acp rejects a
 * non-empty list, so wrapSpawn delivers the same stdio servers through
 * dsh-mcp-client (`dsh --patch`) and a stdio bridge that zeros the wire list. */
export function dshSpawnArgs(
  _config?: { readonly cli?: string },
  _turn?: { readonly integrations?: unknown },
): string[] {
  return ["--profile", "acp"];
}

export const DSH_MINIMUM_ACP_VERSION = "0.1.5-rc.1";

type ParsedVersion = { core: [number, number, number]; prerelease: Array<number | string> };

function parseVersion(value: string): ParsedVersion | null {
  const match = value.match(/(?:^|[^0-9])(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?/u);
  if (!match) return null;
  return {
    core: [Number(match[1]), Number(match[2]), Number(match[3])],
    prerelease: match[4]?.split(".").map((part) => (/^\d+$/u.test(part) ? Number(part) : part)) ?? [],
  };
}

function compareVersions(left: ParsedVersion, right: ParsedVersion): number {
  for (let index = 0; index < left.core.length; index += 1) {
    const l = left.core[index];
    const r = right.core[index];
    if (l === undefined || r === undefined) return l === r ? 0 : (l === undefined ? -1 : 1);
    if (l !== r) return l - r;
  }
  if (!left.prerelease.length || !right.prerelease.length) {
    return left.prerelease.length === right.prerelease.length ? 0 : left.prerelease.length ? -1 : 1;
  }
  const length = Math.max(left.prerelease.length, right.prerelease.length);
  for (let index = 0; index < length; index += 1) {
    const a = left.prerelease[index];
    const b = right.prerelease[index];
    if (a === undefined || b === undefined) return a === b ? 0 : a === undefined ? -1 : 1;
    if (a === b) continue;
    if (typeof a === "number" && typeof b === "number") return a - b;
    if (typeof a === "number") return -1;
    if (typeof b === "number") return 1;
    return a.localeCompare(b);
  }
  return 0;
}

/** The native ACP profile first shipped in 0.1.5-rc.1.
 *
 *  The gate follows the *engine*, not the binary's name, so it keeps firing
 *  when a wrapper is configured.  Matching on the literal `dsh` instead meant
 *  that pointing an instance at a wrapper — including the one this repo
 *  ships — silently disabled the check, which is the one guard standing
 *  between an outdated CLI and a paid turn.  A CLI that is genuinely some
 *  other engine is still exempt, because a DSH version floor is meaningless
 *  for it. */
export function dshVersionCompatibilityReason(version: string, cli = "dsh"): string | null {
  if (!isDshEngineCli(cli)) return null;
  const current = parseVersion(version);
  const minimum = parseVersion(DSH_MINIMUM_ACP_VERSION)!;
  if (current && compareVersions(current, minimum) >= 0) return null;
  return `DeepSeek Harness ${DSH_MINIMUM_ACP_VERSION} or newer is required for native ACP; update with npm install -g @deepseek-ai/dsh@latest`;
}

const DSH_EFFORT_LEVELS = ["none", "high", "max"] as const satisfies readonly EffortLevel[];

/** Per-model reasoning-effort levels, keyed by picker id.  A row listed here
 *  gets its own levels instead of the engine-wide `DSH_EFFORT_LEVELS`; every
 *  other row keeps the engine-wide list.
 *
 *  MiniMax-M3.1-Flash-Preview is newer than the pi-ai catalog dsh installs,
 *  so dsh only knows it from the `llm-pi-ai.providers.minimax.models` entry in
 *  `settings.yaml`.  That entry declares `reasoningEfforts` low through max
 *  and `compat.forceAdaptiveThinking: true`, which makes pi-ai send
 *  `thinking: {type: "adaptive"}` plus `output_config.effort` to MiniMax's
 *  Anthropic-compatible endpoint.  dsh then advertises exactly these five
 *  `reasoning_effort` ids plus the provider-default value, and no `off`, so
 *  `none` is deliberately absent: dsh would refuse the `off` it maps to.  An
 *  install whose settings entry lacks `reasoningEfforts` refuses every level
 *  here, and one that lacks the adaptive flag accepts them but collapses
 *  xhigh and max into high, so a consumer that can read the install's
 *  settings.yaml should use `dshInstalledEffortLevels`, which narrows this map
 *  to what the file declares. */
export const DSH_PER_MODEL_EFFORT_LEVELS: Readonly<Record<string, readonly EffortLevel[]>> = {
  "MiniMax-M3.1-Flash-Preview": ["low", "medium", "high", "xhigh", "max"],
};

/** dsh-acp's `reasoning_effort` value for "the provider's own default".  It
 *  clears an effort an earlier turn left on a resumed session, and dsh only
 *  accepts it for a model whose route sets no default effort of its own. */
export const DSH_PROVIDER_DEFAULT_EFFORT = "";

/** The per-model levels for a picker id (exact id first, then ignoring case),
 *  or `undefined` when the row has none and falls back to the engine-wide
 *  list. */
export function dshPerModelEffortLevels(model: string | undefined): readonly EffortLevel[] | undefined {
  if (!model) return undefined;
  const exact = DSH_PER_MODEL_EFFORT_LEVELS[model];
  if (exact) return exact;
  const lower = model.toLowerCase();
  const key = Object.keys(DSH_PER_MODEL_EFFORT_LEVELS).find((id) => id.toLowerCase() === lower);
  return key === undefined ? undefined : DSH_PER_MODEL_EFFORT_LEVELS[key];
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** The settings.yaml model entry dsh serves a picker id from: the entry under
 *  the provider route the driver sends it to (`dshProviderForModel`), at
 *  `llm-pi-ai.providers` or a top-level `providers`, matched ignoring case. */
function installedModelEntry(settings: unknown, model: string): Record<string, unknown> | undefined {
  if (!isPlainRecord(settings)) return undefined;
  const route = dshProviderForModel(model);
  const piAi = settings["llm-pi-ai"];
  const maps = [isPlainRecord(piAi) ? piAi.providers : undefined, settings.providers];
  const lower = model.toLowerCase();
  for (const providers of maps) {
    if (!isPlainRecord(providers)) continue;
    const block = providers[route];
    if (!isPlainRecord(block) || !Array.isArray(block.models)) continue;
    const entry = block.models.find(
      (candidate) => isPlainRecord(candidate) && typeof candidate.id === "string" && candidate.id.toLowerCase() === lower,
    );
    if (isPlainRecord(entry)) return entry;
  }
  return undefined;
}

/** The per-model levels this install can actually take, from its parsed
 *  settings.yaml (pass `undefined` when the file is missing or unreadable).
 *
 *  `DSH_PER_MODEL_EFFORT_LEVELS` says what a row offers when it is configured
 *  as documented; this narrows it to what the installed settings declare, so
 *  a consumer that reads the file never offers a level dsh would refuse.  A
 *  row keeps a level only when its entry under the row's provider route maps
 *  that level in `reasoningEfforts` to a wire value, and only when the entry
 *  also sets `compat.forceAdaptiveThinking: true`.  Without that flag pi-ai
 *  falls back to fixed thinking budgets, clamps xhigh and max to high, and
 *  sends no `output_config.effort`, so most of the offered levels would run
 *  the identical request.  A row with no entry, `reasoningEfforts: false`, no
 *  `reasoningEfforts`, or a missing or non-true adaptive flag gets `[]`: stock
 *  dsh does not catalog M3.1, so the entry is the only thing that makes the
 *  levels exist.  Every row of `DSH_PER_MODEL_EFFORT_LEVELS` is present in the
 *  result, so an explicit `[]` can win over the static map. */
export function dshInstalledEffortLevels(settings: unknown): Record<string, readonly EffortLevel[]> {
  const installed: Record<string, readonly EffortLevel[]> = {};
  for (const [model, levels] of Object.entries(DSH_PER_MODEL_EFFORT_LEVELS)) {
    const entry = installedModelEntry(settings, model);
    const declared = entry?.reasoningEfforts;
    const compat = entry?.compat;
    const adaptive = isPlainRecord(compat) && compat.forceAdaptiveThinking === true;
    installed[model] = isPlainRecord(declared) && adaptive
      ? levels.filter((level) => {
          if (level === "none") {
            // dsh's `off` may map to null, which means "omit the thinking field".
            const off = declared.off;
            return off === null || (typeof off === "string" && off.length > 0);
          }
          const wire = declared[level];
          return typeof wire === "string" && wire.length > 0;
        })
      : [];
  }
  return installed;
}

/** JSON-RPC "invalid params" (-32602), which dsh-acp answers when it refuses
 *  a `reasoning_effort` value the route does not offer.  The ACP core copies
 *  the wire error's `code` onto the Error it rejects with. */
const ACP_INVALID_PARAMS = -32602;

function isInvalidParamsRefusal(error: unknown): boolean {
  return typeof error === "object" && error !== null && (error as { code?: unknown }).code === ACP_INVALID_PARAMS;
}

/** Effective effort levels for a picker id: its per-model entry when it has
 *  one, otherwise the engine-wide list. */
export function dshEffortLevelsForModel(model: string): readonly EffortLevel[] {
  return dshPerModelEffortLevels(model) ?? DSH_EFFORT_LEVELS;
}

/** The `reasoning_effort` value a turn sends, or `undefined` to leave the
 *  session's current level alone.
 *
 *  An explicit effort sends its level (`none` becomes dsh's `off`).  A turn
 *  with no effort (the picker's Default) sends the provider-default value only
 *  for a row with per-model levels, so a level a previous turn pinned on a
 *  resumed session does not silently stick.  Other rows keep the old
 *  behavior of sending nothing: DeepSeek routes carry a default effort of
 *  their own, and dsh refuses the provider-default value for those. */
export function dshReasoningEffortValue(turn: { readonly effort?: EffortLevel; readonly model?: string }): string | undefined {
  if (turn.effort) return turn.effort === "none" ? "off" : turn.effort;
  return dshPerModelEffortLevels(turn.model) ? DSH_PROVIDER_DEFAULT_EFFORT : undefined;
}

export const DSH_PROVIDER_ID = "deepseek-official";
export const DSH_MINIMAX_PROVIDER_ID = "minimax";

/** Resolve the ACP provider namespace for a model exposed through DSH. */
export function dshProviderForModel(model: string): string {
  if (model.toLowerCase().startsWith("minimax")) {
    return DSH_MINIMAX_PROVIDER_ID;
  }
  return DSH_PROVIDER_ID;
}

/** DSH deliberately makes model values opaque because one catalog may expose
 * the same model id through several providers.
 *
 * `advertised` is the session's `configOptions` from `session/new`.  With it,
 * the picker model resolves against the options the installed dsh actually
 * declares (by id, then display name, then a known alias) and the *declared*
 * value is returned, because dsh refuses any value it did not advertise.  The
 * ids a catalog or a saved selection carries are not reliably the ids a given
 * install declares: stock dsh names its Flash model `deepseek-flash` while the
 * picker says `DeepSeek-V4.1-Flash`, and an owner's settings can declare
 * another spelling again.  See `./model-options.ts`.
 *
 * Without `advertised`, or when it lists no model, the value is built from the
 * preferred stock wire id via {@link dshCanonicalWireModelId} (picker display
 * ids such as `DeepSeek-V4.1-Flash` become `deepseek-flash`; MiniMax and other
 * non-DeepSeek models pass through unchanged).  A session that offers models
 * but not this one throws {@link DshModelNotOfferedError}, classified as a
 * model-catalog outage. */
export function dshModelOptionValue(model: string, advertised?: unknown): string {
  const provider = dshProviderForModel(model);
  return (
    resolveDshModelOption(model, provider, advertised)?.value ??
    JSON.stringify([provider, dshCanonicalWireModelId(model)])
  );
}

export function dshModelIdFromOptionValue(value: unknown): string | null {
  if (typeof value !== "string") return null;
  try {
    const decoded: unknown = JSON.parse(value);
    if (
      Array.isArray(decoded) &&
      decoded.length === 2 &&
      (decoded[0] === DSH_PROVIDER_ID || decoded[0] === DSH_MINIMAX_PROVIDER_ID) &&
      typeof decoded[1] === "string" &&
      decoded[1].length > 0
    ) {
      return decoded[1];
    }
  } catch {
    // ACP config values are opaque; an unrecognized value is not a model id.
  }
  return null;
}

function currentConfigValue(result: unknown, configId: string): unknown {
  if (!result || typeof result !== "object") return undefined;
  const options = (result as { configOptions?: unknown }).configOptions;
  if (!Array.isArray(options)) return undefined;
  const option = options.find(
    (candidate) => candidate && typeof candidate === "object" && (candidate as { id?: unknown }).id === configId,
  );
  return option && typeof option === "object" ? (option as { currentValue?: unknown }).currentValue : undefined;
}

/** The engine's own current models.  These ids are *picker* ids: what a
 * catalog lists and a bot stores, not necessarily what the installed dsh
 * declares on the wire (stock dsh calls Flash `deepseek-flash`).  They stay
 * stable so saved selections keep working; `dshModelOptionValue` translates
 * each one to the session's advertised value at send time.
 *
 * The vision variant is deliberately
 * absent: `images: false` disables image attachment for the whole engine, so
 * shipping a vision model here offered a capability the composer refused.
 *
 * Each row's `images` agrees with the modality the route actually declares, so
 * a consumer that reads the catalog never offers an attachment the model would
 * refuse.  `deepseek-flash` declares `inputModalities: [text, image]` and the
 * three MiniMax rows on the `minimax` route are pinned by
 * {@link DSH_PER_MODEL_IMAGES}; `deepseek-v4-pro` and M2.7 are text-only. */
export const STATIC_DSH_MODELS: ModelCatalog = {
  default: "DeepSeek-V4.1-Flash",
  options: [
    { id: "DeepSeek-V4.1-Flash", label: "DeepSeek-V4.1-Flash", images: true },
    { id: "DeepSeek-V4.1-Pro", label: "DeepSeek-V4.1-Pro", images: false },
    { id: "MiniMax-M3.1-Flash-Preview", label: "MiniMax-M3.1-Flash-Preview", contextWindow: 1_000_000, images: true },
    { id: "MiniMax-M3", label: "MiniMax-M3", contextWindow: 1_048_576, images: true },
    { id: "MiniMax-M2.7-highspeed", label: "MiniMax-M2.7-highspeed", contextWindow: 204_800, images: false },
  ],
};

/** Per-model image support, keyed by picker id, for rows whose route-level
 *  `images` answer would be wrong.
 *
 *  These are facts about the provider, not preferences: the installed pi-ai
 *  catalog declares MiniMax-M3 and the M3.1 Flash preview as text+image and
 *  the M2.7 family as text-only, and DeepSeek's own catalog declares Flash
 *  text+image and Pro text-only.  A consumer that resolves one model reads its
 *  own row here rather than the engine-wide {@link dshSupport.images} gate,
 *  which stays closed until that consumer lands. */
export const DSH_PER_MODEL_IMAGES: Readonly<Record<string, boolean>> = {
  "DeepSeek-V4.1-Flash": true,
  "DeepSeek-V4.1-Pro": false,
  "MiniMax-M3.1-Flash-Preview": true,
  "MiniMax-M3": true,
  "MiniMax-M2.7-highspeed": false,
};

/** Which state home a configured engine CLI uses: `clutch` (the Clutch
 * wrapper, engine home $CLUTCH_HOME/dsh) or `dsh` (vanilla, $DSH_HOME or
 * ~/.dsh).  Anything else is treated as vanilla `dsh`. */
export function dshEngineStem(cli: string): "clutch" | "dsh" {
  const stem = basename(cli).toLowerCase().replace(/\.(sh|bash|js|mjs|cjs|ts)$/u, "");
  return stem === "clutch" ? "clutch" : "dsh";
}

function clutchEngineHome(env: Record<string, string | undefined>, home: string): string {
  return join(env.CLUTCH_HOME || join(home, ".clutch"), "dsh");
}

/** Candidate credential files for the engine.
 *
 * The answer follows the CLI stem: `clutch` always reads
 * $CLUTCH_HOME/dsh/.credentials.yaml (the Clutch wrapper forces DSH_HOME
 * there), and vanilla `dsh` honours the same DSH_HOME / HOME precedence the
 * upstream engine uses.  The CLI defaults to `dsh`, matching
 * `dshSupport.defaultCli`, so the store checked is always the one the spawned
 * process reads.  Other DeepSeek clients have separate stores that do not
 * authenticate this engine. */
export function dshCredentialCandidates(env: Record<string, string | undefined>, cli = "dsh"): string[] {
  const home = env.HOME || env.USERPROFILE || homedir();
  if (dshEngineStem(cli) === "clutch") return [join(clutchEngineHome(env, home), ".credentials.yaml")];
  return [join(env.DSH_HOME || join(home, ".dsh"), ".credentials.yaml")];
}

/** The login hint for a configured engine CLI, naming the store it reads. */
export function dshLoginNote(cli: string): string {
  return dshEngineStem(cli) === "clutch"
    ? "Clutch CLI auth missing — add ~/.clutch/dsh/.credentials.yaml"
    : "dsh CLI auth missing — add ~/.dsh/.credentials.yaml";
}

/** Map DSH/DeepSeek failure text onto the canonical provider-error codes so the
 * fallback chain treats DSH quota and auth failures like every other engine
 * instead of as a generic rpc_error. */
export function classifyDshError(error: unknown): ProviderErrorCode | undefined {
  // Our own resolution failure names arbitrary model ids, so classify it by
  // type before any pattern below can misread an id as a quota or auth word.
  if (error instanceof DshModelNotOfferedError) return "model_catalog_outage";
  const message = error instanceof Error ? error.message : String(error ?? "");
  const code = error && typeof error === "object" ? (error as { code?: unknown }).code : undefined;
  const blob = `${code ?? ""} ${message}`.toLowerCase();
  if (/unauthoriz|unauthenticated|not signed in|not logged in|invalid api key|invalid_credentials|authentication required|auth.*(fail|missing|required)/.test(blob)) {
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

/** The DSH support shape.  Pure engine data — no ACP runtime coupling. */
export const dshSupport: AcpSupport = {
  driverKind: "dshAgent",
  displayName: "Clutch",
  // Keep the engine-wide gate closed until BotFleet consumes per-model image
  // support.  Its current composer reads only this flag, so opening it now
  // would accept attachments even for non-vision DeepSeek V4.1 Pro.  Flip to
  // true only after that consumer lands and deploys; the catalog retains
  // Flash's images: true and Pro's images: false for that future gate.
  images: false,
  models: STATIC_DSH_MODELS,
  resolveModels: () => STATIC_DSH_MODELS,
  perModelImages: DSH_PER_MODEL_IMAGES,
  effortLevels: DSH_EFFORT_LEVELS,
  perModelEffortLevels: DSH_PER_MODEL_EFFORT_LEVELS,
  mcpServers: true,
  // Vanilla `dsh` against ~/.dsh, by design.  BotFleet keeps spawning the
  // upstream engine with its own state; the `clutch` wrapper (state in
  // ~/.clutch/dsh) is a per-instance choice in BotFleet's Engines Settings,
  // and isDshEngineCli keeps MCP mounting and the version gate attached to it.
  defaultCli: "dsh",
  nativeSource: "dsh.acp",
  // Matches defaultCli.  A consumer that spawns `clutch` should show
  // dshLoginNote(cli) instead, which names the Clutch store.
  loginNote: dshLoginNote("dsh"),

  install: {
    command: {
      darwin: "npm install -g @deepseek-ai/dsh@latest",
      linux: "npm install -g @deepseek-ai/dsh@latest",
      win32: "npm install -g @deepseek-ai/dsh@latest",
    },
    docsUrl: "https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/bundle/acp-app",
    needsNode: true,
  },

  spawnArgs: dshSpawnArgs,
  resumeMethod: "session/resume",
  selectModel: {
    configId: "model",
    valueForModel: dshModelOptionValue,
    modelForValue: dshModelIdFromOptionValue,
  },
  versionCompatibilityReason: (version, config) => dshVersionCompatibilityReason(version, config.cli),

  configureSession: async ({ request, sessionId, turn }) => {
    const requested = dshReasoningEffortValue(turn);
    if (requested === undefined) return;
    if (requested === DSH_PROVIDER_DEFAULT_EFFORT) {
      // Default is best effort: a route that declares its own default effort
      // refuses this value (dsh answers invalid params), and then the session
      // keeps whatever level it had, which is exactly what Default did before.
      // Only that refusal is swallowed.  A timeout or an internal error means
      // the session is in a state nobody has looked at, so it still surfaces.
      try {
        await request("session/set_config_option", {
          sessionId,
          configId: "reasoning_effort",
          value: requested,
        });
      } catch (error) {
        if (!isInvalidParamsRefusal(error)) throw error;
      }
      return;
    }
    const result = await request("session/set_config_option", {
      sessionId,
      configId: "reasoning_effort",
      value: requested,
    });
    const confirmed = currentConfigValue(result, "reasoning_effort");
    // Only a reported mismatch means the setting did not take.  A reply that
    // carries no option state (stock `dsh` answered `{}`) reports nothing to
    // compare, and failing on that refused every effort-pinned turn (BotFleet #486).
    if (confirmed !== undefined && confirmed !== requested) {
      throw new Error(
        `Engine did not switch reasoning effort to ${requested} (still ${String(confirmed ?? "unknown")})`,
      );
    }
  },

  transformEnv: (_env) => {},

  classifyError: (error: unknown) => classifyDshError(error) as string | undefined,

  credentialEnv: [
    "DEEPSEEK_API_KEY",
    "MINIMAX_API_KEY",
    "DSH_HOME",
    "CLUTCH_HOME",
    "CLUTCH_RUNTIME_ROOT",
    // Upstream-read: the shipped dsh-base cordis.patch.yml evaluates it.
    "DSH_PERMISSION_MODE",
  ],

  pickAuthMethod: () => null,
  authFailure: "continue",
  isAuthenticated: (env) =>
    dshCredentialCandidates(env).some(existsSync) ||
    Boolean(env.DEEPSEEK_API_KEY) ||
    Boolean(env.MINIMAX_API_KEY),

  buildPromptText: (turn) => (turn.system ? `${turn.system}\n\n${turn.text}` : turn.text),
};
