/**
 * DSH driver support — pure engine logic.
 *
 * This module owns every DSH-specific knob: model catalog, version gate,
 * error classification, credential candidates, model-id round-trip, env
 * contract, install instructions, prompt composition.  Anything DSH-shaped
 * that doesn't depend on the harness runtime lives here.
 *
 * The harness runtime primitives — the ACP JSON-RPC client, the spawn
 * wrapper, the MCP mount assembler — stay in BotFleet (`acp/core.ts`,
 * `acp/dsh-mcp.ts`).  BotFleet imports this module and composes the two:
 *
 *     import { dshSupport, DSH_MINIMUM_ACP_VERSION } from "harness/dsh/acp/driver";
 *     import { createAcpDriver } from "../acp/core";
 *     export const DshAgentDriver = createAcpDriver(dshSupport);
 *
 * That keeps the ACP runtime in one place (BotFleet) and the DSH engine
 * shape in one place (Harness).  See
 * `docs/decisions/0002-acp-core-stays-in-botfleet.md` for the long-term
 * plan to lift the ACP core too.
 */
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { EffortLevel, ModelCatalog, ProviderErrorCode } from "../../shared/contracts.ts";
import type { AcpSupport } from "../../shared/acp-core.ts";

export { isStockDshCli } from "./mcp-patch.ts";

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

/** The native ACP profile first shipped in 0.1.5-rc.1.  Custom wrappers are
 * deliberately outside this stock-binary gate. */
export function dshVersionCompatibilityReason(version: string, cli = "dsh"): string | null {
  if (cli !== "dsh") return null;
  const current = parseVersion(version);
  const minimum = parseVersion(DSH_MINIMUM_ACP_VERSION)!;
  if (current && compareVersions(current, minimum) >= 0) return null;
  return `DeepSeek Harness ${DSH_MINIMUM_ACP_VERSION} or newer is required for native ACP; update with npm install -g @deepseek-ai/dsh@latest`;
}

const DSH_EFFORT_LEVELS = ["none", "high", "max"] as const satisfies readonly EffortLevel[];

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
 * the same model id through several providers. */
export function dshModelOptionValue(model: string): string {
  return JSON.stringify([dshProviderForModel(model), model]);
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

/** The harness's own current models.  The vision variant is deliberately
 * absent: `images: false` disables image attachment for the whole engine, so
 * shipping a vision model here offered a capability the composer refused. */
export const STATIC_DSH_MODELS: ModelCatalog = {
  default: "DeepSeek-V4.1-Flash",
  options: [
    { id: "DeepSeek-V4.1-Flash", label: "DeepSeek-V4.1-Flash" },
    { id: "DeepSeek-V4.1-Pro", label: "DeepSeek-V4.1-Pro" },
    { id: "MiniMax-M3.1-Flash-Preview", label: "MiniMax-M3.1-Flash-Preview", contextWindow: 1_000_000 },
    { id: "MiniMax-M3", label: "MiniMax-M3", contextWindow: 1_000_000 },
    { id: "MiniMax-M2.7-highspeed", label: "MiniMax-M2.7-highspeed", contextWindow: 204_800 },
  ],
};

/** Candidate credential file, honoring the same DSH_HOME / HOME precedence the
 * published `dsh` harness uses.  Other DeepSeek clients have separate stores
 * that do not authenticate this CLI. */
export function dshCredentialCandidates(env: Record<string, string | undefined>): string[] {
  const home = env.HOME || env.USERPROFILE || homedir();
  const dshHome = env.DSH_HOME || join(home, ".dsh");
  return [join(dshHome, ".credentials.yaml")];
}

/** Map DSH/DeepSeek failure text onto the canonical provider-error codes so the
 * fallback chain treats DSH quota and auth failures like every other engine
 * instead of as a generic rpc_error. */
export function classifyDshError(error: unknown): ProviderErrorCode | undefined {
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

/** The DSH support shape.  Pure engine data — no harness runtime coupling. */
export const dshSupport: AcpSupport = {
  driverKind: "dshAgent",
  displayName: "Harness",
  // the vision model below is the one option that CAN take an image, and the
  // flag gates the composer for the whole engine — so it stays off until the
  // catalog can answer per model rather than per engine
  images: false,
  models: STATIC_DSH_MODELS,
  resolveModels: () => STATIC_DSH_MODELS,
  effortLevels: DSH_EFFORT_LEVELS,
  mcpServers: true,
  defaultCli: "dsh",
  nativeSource: "dsh.acp",
  loginNote: "DSH CLI auth missing — add ~/.dsh/.credentials.yaml",

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
    if (!turn.effort) return;
    const requested = turn.effort === "none" ? "off" : turn.effort;
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
        `DeepSeek Harness did not switch reasoning effort to ${requested} (still ${String(confirmed ?? "unknown")})`,
      );
    }
  },

  transformEnv: (_env) => {},

  classifyError: (error: unknown) => classifyDshError(error) as string | undefined,

  credentialEnv: [
    "DEEPSEEK_API_KEY",
    "MINIMAX_API_KEY",
    "DSH_HOME",
    "DSH_RUNTIME_ROOT",
    "HARNESS_RUNTIME_ROOT",
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
