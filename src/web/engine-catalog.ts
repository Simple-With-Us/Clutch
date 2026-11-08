/**
 * The engine catalog the native apps read: which engines a host can run,
 * which models each engine offers right now, and which reasoning-effort
 * levels it accepts.
 *
 * The web canvas (upstream `dsh web`) shows a model picker with a per-model
 * effort control, and the native chat wanted the same thing.  Rather than
 * hardcode a list that goes stale the moment a provider ships a model, this
 * reads the engine choices:
 *
 *   - **MiniMax Code** advertises its real choices on
 *     ACP `session/new` (`configOptions`), so a probe session reads the
 *     engine's own catalog.  The probe session is closed again right after.
 *   - **Muse Code** uses config options from the existing user session and
 *     publishes a provider catalog on disk
 *     (`~/.local/share/muse/model-catalog/*.json`), which is where a model
 *     the account can reach but the ACP session does not advertise (Muse
 *     Wonder, for one) shows up.  Reading it is what lets the picker offer
 *     Muse Wonder instead of the engine's built-in fallback list.
 *   - **DeepSeek** and **MiniMax** run through the dsh bridges, which do not
 *     advertise config options, so their catalog comes from the repo's
 *     tracked model lists.
 *
 * Muse catalog browsing never starts a process or creates a session.
 * Other engine catalogs are cached for a few minutes.
 *
 * The drop-in engine plugins (`engines/`, `$CLUTCH_HOME/engines`) reach the
 * catalog too: a plugin that maps to an engine Clutch already runs may add
 * models to it and say how to sign in, and a plugin that maps to no known
 * engine is reported instead of becoming a phantom entry in the picker.
 */
import { spawn } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { Engine } from "../shared/engine-types.ts";
import { ENGINE_LABELS, ENGINE_ORDER, isDshHostedEngine, supportsThreads } from "../shared/engine-types.ts";
import { loadEnginePlugins } from "../shared/engines/index.ts";
import { museContributorModelId } from "./muse-launch-options.ts";

/** One model an engine can run, with the exact value its config option takes. */
export interface EngineModel {
  /** Stable client-facing id (the model id itself). */
  id: string;
  /** Human label for a picker. */
  label: string;
  /** The exact wire value to send in `session/set_config_option`. */
  value: string;
  /**
   * A second form the engine may accept for the same model, tried when the
   * first is refused.  Muse Code spells a model two ways: the bare id
   * (`muse-wonder-1.0`) and a provider-qualified tuple
   * (`muse-model:["meta","tbh","muse-wonder-1.0"]`), and which one the
   * adapter accepts depends on its backend and on the account's catalog.
   */
  altValue?: string;
  /** Context window in tokens, when the engine publishes one. */
  contextWindow?: number;
  /** True when the engine says the model reads images. */
  images?: boolean;
}

/** One engine, with everything a client needs to drive it. */
export interface EngineDescriptor {
  id: Engine;
  label: string;
  /** False when the engine's launcher or host binary is missing here. */
  available: boolean;
  /**
   * True when this engine's threads can be listed and resumed.
   *
   * The catalog publishes the capability so a client does not hardcode which
   * engines those are: the code engines keep their own session log and the
   * dsh-hosted engines keep theirs in the dsh host, and the sidecar reads and
   * resumes both through the same endpoint.
   */
  supportsThreads: boolean;
  models: EngineModel[];
  /** Reasoning-effort levels the engine accepts, ascending. */
  effortLevels: string[];
  /** The ACP config id that carries the effort choice. */
  effortConfigId: string;
  /** The ACP config id that carries the model choice. */
  modelConfigId: string;
  /** A short note for the client (why a catalog is thin, for example). */
  note?: string;
}

export interface EngineCatalog {
  engines: EngineDescriptor[];
}

/**
 * Which engine a drop-in engine plugin contributes to.
 *
 * Why this exists: a plugin names itself after the product it drives
 * ("muse-code"), while the sidecar's engine ids are the closed set in
 * `src/shared/engine-types.ts` ("muse", "minimax").  The mapping is
 * explicit, so a plugin can enrich an engine Clutch already runs without
 * inventing a new one, and so a plugin that names no known engine is
 * reported rather than quietly dropped.
 */
export const ENGINE_PLUGIN_ID_MAP: Readonly<Record<string, Engine>> = {
  "muse-code": "muse",
  minimax: "minimax",
  zcode: "zcode",
};

/** What one plugin contributes to the engine it maps to. */
export interface EnginePluginContribution {
  /** The sidecar engine id this plugin contributes to. */
  engine: Engine;
  /** The plugin's own id. */
  pluginId: string;
  /** The file the plugin came from. */
  file: string;
  /** The name the plugin gives the engine. */
  displayName: string;
  /** The models the plugin declares, as catalog entries. */
  models: EngineModel[];
  /** The plugin's sign-in hint, used when the engine cannot run. */
  loginNote?: string;
}

/** What the plugin registry found, and what it could not use. */
export interface EnginePluginReport {
  /** Plugins that loaded and map to an engine Clutch runs. */
  contributions: EnginePluginContribution[];
  /** Plugins that loaded but name no engine Clutch runs. */
  unmapped: { id: string; file: string }[];
  /** Plugin files that failed to load; each one contributes nothing. */
  problems: { file: string; id?: string; problems: string[] }[];
}

/**
 * Discover the drop-in engine plugins and say what each one contributes.
 *
 * Discovery never throws: a plugin file that does not load is reported and
 * contributes nothing, so one broken drop-in cannot take the catalog down.
 * A plugin whose id maps to no known engine is reported as unmapped rather
 * than turned into a phantom engine the picker would offer.
 */
export async function loadEnginePluginReport(
  options: { dirs?: readonly string[]; env?: Record<string, string | undefined> } = {},
): Promise<EnginePluginReport> {
  const { plugins, problems } = await loadEnginePlugins({
    ...(options.dirs ? { dirs: options.dirs } : {}),
    ...(options.env ? { env: options.env } : {}),
  });
  const contributions: EnginePluginContribution[] = [];
  const unmapped: { id: string; file: string }[] = [];
  for (const plugin of plugins) {
    const engine = ENGINE_PLUGIN_ID_MAP[plugin.id];
    if (!engine) {
      unmapped.push({ id: plugin.id, file: plugin.file });
      continue;
    }
    const support = plugin.support;
    const contribution: EnginePluginContribution = {
      engine,
      pluginId: plugin.id,
      file: plugin.file,
      displayName: support.displayName,
      models: support.models.options.map((option) => ({
        id: option.id,
        label: option.label,
        value: option.id,
        ...(option.contextWindow === undefined ? {} : { contextWindow: option.contextWindow }),
        ...(option.images === undefined ? {} : { images: option.images }),
      })),
    };
    if (support.loginNote !== undefined) contribution.loginNote = support.loginNote;
    contributions.push(contribution);
  }
  return {
    contributions,
    unmapped,
    problems: problems.map((problem) => ({
      file: problem.file,
      ...(problem.id === undefined ? {} : { id: problem.id }),
      problems: [...problem.problems],
    })),
  };
}

/**
 * The models a plugin may add to an engine's own catalog.
 *
 * The engine's own catalog wins for every model id it lists, so a plugin
 * never overwrites what the engine or its provider published.  The dsh
 * engines take no plugin models at all: their cordis profile owns the model
 * list, and a plugin's curated list would offer models the profile does
 * not declare.
 */
function pluginModelsFor(sources: CatalogSources, engine: Engine): EngineModel[] {
  if (isDshHostedEngine(engine)) return [];
  const contributions = sources.plugins?.contributions.filter((entry) => entry.engine === engine) ?? [];
  return contributions.flatMap((entry) => entry.models);
}

/** The sign-in note a plugin offers for an engine. */
function pluginLoginNote(sources: CatalogSources, engine: Engine): string | undefined {
  return sources.plugins?.contributions.find((entry) => entry.engine === engine)?.loginNote;
}

/** Add the models a plugin knows and the engine does not, keeping the engine's own first. */
function mergePluginModels(own: EngineModel[], contributed: EngineModel[]): EngineModel[] {
  if (contributed.length === 0) return own;
  const known = new Set(own.map((model) => model.id));
  const extra = contributed.filter((model) => !known.has(model.id));
  return extra.length === 0 ? own : [...own, ...extra];
}

const CATALOG_TTL_MS = 5 * 60 * 1000;

interface CacheEntry {
  at: number;
  catalog: EngineCatalog;
  museProviderModels: EngineModel[];
}

export type CatalogProbeScope = "full" | "mcode" | "zcode" | "passive";
// Each probe scope keeps its own entry: the full scope probes every probed
// engine, a targeted scope only one, so they must never serve each other.
type CatalogCacheScope = CatalogProbeScope;

const cache = new Map<CatalogCacheScope, CacheEntry>();
const inflight = new Map<CatalogCacheScope, Promise<CacheEntry>>();
let cacheGeneration = 0;

/** Drop the cached catalog; the next read refreshes its sources. */
export function resetEngineCatalogCache(): void {
  cacheGeneration += 1;
  cache.clear();
  inflight.clear();
}

/** The dsh-side model lists, kept in step with the repo's tracked catalog. */
const DSH_MODELS: Record<string, EngineModel[]> = {
  deepseek: [
    { id: "DeepSeek-V4.1-Pro", label: "DeepSeek-V4.1-Pro", value: "DeepSeek-V4.1-Pro" },
    { id: "DeepSeek-V4.1-Flash", label: "DeepSeek-V4.1-Flash", value: "DeepSeek-V4.1-Flash", images: true },
  ],
  minimax: [
    { id: "MiniMax-M3.1-Flash", label: "MiniMax-M3.1-Flash", value: "MiniMax-M3.1-Flash" },
    { id: "MiniMax-M3", label: "MiniMax-M3", value: "MiniMax-M3" },
  ],
};

const EFFORT_LEVELS: Record<string, string[]> = {
  deepseek: ["none", "low", "medium", "high", "xhigh", "max"],
  minimax: ["none", "low", "medium", "high", "xhigh", "max"],
  mcode: ["default", "low", "medium", "high", "xhigh", "max"],
  // Same family as mcode until a live probe advertises Z Code's own list; an
  // effort the session does not offer is refused without failing the turn.
  zcode: ["default", "low", "medium", "high", "xhigh", "max"],
};

const EFFORT_CONFIG_IDS: Record<string, string> = {
  deepseek: "reasoning_effort",
  minimax: "reasoning_effort",
  mcode: "thinkingEffort",
  muse: "reasoningEffort",
  // Same config id family as mcode until a live Z Code session advertises
  // its own; a wrong guess costs the effort levels only, never the models.
  zcode: "thinkingEffort",
};
const MUSE_CONTRIBUTOR_EFFORT_LEVELS = ["minimal", "low", "medium", "high", "xhigh"];

/** One ACP `configOptions` entry, as the engines publish it. */
interface ConfigOption {
  id?: unknown;
  category?: unknown;
  currentValue?: unknown;
  options?: unknown;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** The models an ACP config option offers, in the engine's own order. */
export function modelsFromConfigOptions(options: unknown, configId = "model"): EngineModel[] {
  if (!Array.isArray(options)) return [];
  const entry = options.find((option) => isRecord(option) && option.id === configId);
  if (!isRecord(entry) || !Array.isArray(entry.options)) return [];
  const models: EngineModel[] = [];
  for (const option of entry.options) {
    if (!isRecord(option)) continue;
    const value = typeof option.value === "string" ? option.value : "";
    if (!value) continue;
    const id = typeof option.name === "string" && option.name.length > 0 ? option.name : value;
    models.push({ id, label: id, value });
  }
  return models;
}

/** The effort levels an ACP config option offers. */
export function effortsFromConfigOptions(options: unknown, configId: string): string[] {
  if (!Array.isArray(options)) return [];
  const entry = options.find((option) => isRecord(option) && option.id === configId);
  if (!isRecord(entry) || !Array.isArray(entry.options)) return [];
  const levels: string[] = [];
  for (const option of entry.options) {
    if (!isRecord(option)) continue;
    const value = typeof option.value === "string" ? option.value : "";
    if (value) levels.push(value);
  }
  return levels;
}

/**
 * One row of Muse's provider catalog: the models an account can reach,
 * including the ones the ACP session does not advertise.
 */
interface MuseCatalogRow {
  model_id?: unknown;
  display_label?: unknown;
  provider_id?: unknown;
  profile_id?: unknown;
  visibility?: unknown;
  context_limit?: unknown;
  output_limit?: unknown;
  reasoning_effort_variants?: unknown;
}

const MUSE_CONTRIBUTOR_MODEL_IDS = new Set([
  "muse-spark-1.3-contributor",
  "muse-wonder-1.0-contributor",
  "muse-wonder-full-1.0-contributor",
]);
const MUSE_CONTRIBUTOR_MODELS: EngineModel[] = [
  { id: "muse-spark-1.3-contributor", label: "Muse Spark 1.3 Contributor", value: "muse-spark-1.3-contributor" },
  { id: "muse-wonder-1.0-contributor", label: "Muse Wonder 1.0 Contributor", value: "muse-wonder-1.0-contributor" },
  { id: "muse-wonder-full-1.0-contributor", label: "Muse Wonder Full 1.0 Contributor", value: "muse-wonder-full-1.0-contributor" },
];

const MUSE_MODEL_LABELS: Record<string, string> = {
  "muse-spark-1.3-contributor": "Muse Spark 1.3 Contributor",
  "muse-wonder-1.0-contributor": "Muse Wonder 1.0 Contributor",
  "muse-wonder-full-1.0-contributor": "Muse Wonder Full 1.0 Contributor",
};

const MUSE_CONTRIBUTOR_ID_BY_LABEL = new Map(
  MUSE_CONTRIBUTOR_MODELS.map((model) => [model.label, model.id]),
);

function museModelLabel(id: string, providerLabel: unknown): string {
  const knownLabel = MUSE_MODEL_LABELS[id];
  if (knownLabel) return knownLabel;
  if (typeof providerLabel === "string" && providerLabel.length > 0 && providerLabel !== id) return providerLabel;
  return id.replace(/^muse-/, "Muse ").split("-").map((part) => part[0]?.toUpperCase() + part.slice(1)).join(" ");
}

/**
 * The supported Muse contributor models published in the local provider catalog.
 *
 * `~/.local/share/muse/model-catalog/*.json` is written by the Muse CLI from
 * the provider's own catalog.  Only the explicitly supported contributor
 * variants are exposed to Clutch.
 */
export function readMuseProviderCatalog(home: string = homedir()): EngineModel[] {
  const dir = join(home, ".local", "share", "muse", "model-catalog");
  if (!existsSync(dir)) return [];
  const models: EngineModel[] = [];
  let files: string[];
  try {
    files = readdirSync(dir).filter((name) => name.endsWith(".json"));
  } catch {
    return [];
  }
  for (const name of files) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(readFileSync(join(dir, name), "utf8"));
    } catch {
      continue;
    }
    if (!isRecord(parsed) || !Array.isArray(parsed.rows)) continue;
    for (const row of parsed.rows as MuseCatalogRow[]) {
      if (!isRecord(row)) continue;
      const id = typeof row.model_id === "string" ? row.model_id : "";
      if (!MUSE_CONTRIBUTOR_MODEL_IDS.has(id)) continue;
      const label = museModelLabel(id, row.display_label);
      const model: EngineModel = { id, label, value: id };
      // The provider-qualified form is the other spelling of the same model.
      // Which one the adapter accepts depends on its backend and on the
      // account's catalog, so both are offered and the sidecar tries the
      // second when the first is refused.
      const provider = typeof row.provider_id === "string" ? row.provider_id : null;
      const profile = typeof row.profile_id === "string" ? row.profile_id : null;
      if (provider || profile) {
        model.altValue = `muse-model:${JSON.stringify([provider, profile, id])}`;
      }
      if (typeof row.context_limit === "number" && row.context_limit > 0) model.contextWindow = row.context_limit;
      models.push(model);
    }
  }
  return models;
}

interface ProbeResult {
  models: EngineModel[];
  efforts: string[];
  supportsThreads: boolean;
  initialized: boolean;
}

/** Whether an ACP initialize result promises both thread listing and loading. */
export function threadSupportFromInitialize(result: unknown): boolean {
  if (!isRecord(result) || !isRecord(result.agentCapabilities)) return false;
  const capabilities = result.agentCapabilities;
  if (capabilities.loadSession !== true || !isRecord(capabilities.sessionCapabilities)) return false;
  return isRecord(capabilities.sessionCapabilities.list);
}

/**
 * One ACP JSON-RPC message, as the probe reads it.
 *
 * The engine is an external process, so every field is checked before it is
 * used: a malformed message is dropped, never believed.  (The repo has no
 * runtime schema library — zod is a devDependency — so this is a hand-written
 * parser rather than a schema.)
 */
interface AcpMessage {
  id?: number;
  method?: string;
  result?: Record<string, unknown>;
}

/** Parse one line of engine output into a message, or null when it is not one. */
export function parseAcpMessage(line: string): AcpMessage | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;
  const message: AcpMessage = {};
  if (typeof parsed.id === "number") message.id = parsed.id;
  if (typeof parsed.method === "string") message.method = parsed.method;
  if (isRecord(parsed.result)) message.result = parsed.result;
  return message;
}

/**
 * Ask an engine what it offers, by opening one throwaway ACP session and
 * reading the config options it advertises.  The session is closed
 * immediately; no model turn runs.
 */
export function probeEngineOptions(
  command: string,
  args: string[],
  cwd: string,
  effortConfigId = "reasoning_effort",
  timeoutMs = 60_000,
): Promise<ProbeResult> {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "ignore"],
      cwd,
      env: process.env,
    });
    let buffer = "";
    let settled = false;
    let sessionId: string | null = null;
    let supportsThreads = false;
    const options: unknown[] = [];

    const finish = (result: ProbeResult): void => {
      if (settled) return;
      settled = true;
      try {
        child.kill("SIGTERM");
      } catch {
        /* already gone */
      }
      resolvePromise(result);
    };

    const timer = setTimeout(() => {
      finish({ models: [], efforts: [], supportsThreads: false, initialized: false });
    }, timeoutMs);

    const send = (payload: Record<string, unknown>): void => {
      try {
        child.stdin?.write(`${JSON.stringify(payload)}\n`);
      } catch {
        /* the pipe closed under us */
      }
    };

    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      buffer += chunk;
      let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;
        // The engine is an external process: every field is validated
        // before it is believed.
        const message = parseAcpMessage(line);
        if (!message) continue;
        if (message.method === "session/request_permission" && message.id !== undefined) {
          // A probe never runs a turn, so any permission request means the
          // engine got somewhere unexpected: allow once and move on.
          send({ jsonrpc: "2.0", id: message.id, result: { outcome: { outcome: "cancelled" } } });
          continue;
        }
        if (message.id === 1) {
          if (!message.result) {
            clearTimeout(timer);
            finish({ models: [], efforts: [], supportsThreads: false, initialized: false });
            continue;
          }
          supportsThreads = threadSupportFromInitialize(message.result);
          send({
            jsonrpc: "2.0",
            id: 2,
            method: "session/new",
            params: { cwd, mcpServers: [] },
          });
          continue;
        }
        if (message.id === 2) {
          if (!message.result) {
            clearTimeout(timer);
            finish({ models: [], efforts: [], supportsThreads: false, initialized: false });
            continue;
          }
          const result = message.result ?? {};
          sessionId = typeof result.sessionId === "string" ? result.sessionId : null;
          if (Array.isArray(result.configOptions)) options.push(...result.configOptions);
          if (sessionId) {
            // Close the probe session; the answer is in the options we read.
            send({ jsonrpc: "2.0", id: 3, method: "session/close", params: { sessionId } });
          } else {
            clearTimeout(timer);
            finish({
              models: [],
              efforts: [],
              supportsThreads: false,
              initialized: false,
            });
          }
          continue;
        }
        if (message.id === 3) {
          clearTimeout(timer);
          finish({
            models: modelsFromConfigOptions(options),
            efforts: effortsFromConfigOptions(options, effortConfigId),
            supportsThreads,
            initialized: true,
          });
          continue;
        }
      }
    });

    child.on("error", () => {
      clearTimeout(timer);
      finish({ models: [], efforts: [], supportsThreads: false, initialized: false });
    });
    child.on("close", () => {
      clearTimeout(timer);
      finish({ models: [], efforts: [], supportsThreads: false, initialized: false });
    });

    send({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } } },
    });
  });
}

/** Merge Muse's advertised choices with the provider catalog, advertised first. */
export function mergeMuseModels(advertised: EngineModel[], provider: EngineModel[]): EngineModel[] {
  const byId = new Map<string, EngineModel>();
  const seenValues = new Set<string>();
  const merged: EngineModel[] = [];
  for (const model of [...advertised, ...provider]) {
    const existing = byId.get(model.id);
    if (existing) {
      // Keep the first wire value, but retain a distinct second spelling of
      // this same model when ACP or the provider publishes one.
      const alternate = [model.value, model.altValue].find((value) =>
        value && value !== existing.value && value !== existing.altValue,
      );
      if (!existing.altValue && alternate) {
        existing.altValue = alternate;
        seenValues.add(alternate);
      }
      continue;
    }
    if (seenValues.has(model.value)) continue;
    const copy = { ...model };
    byId.set(copy.id, copy);
    seenValues.add(copy.value);
    merged.push(copy);
  }
  return merged;
}

function withKnownMuseContributors(provider: EngineModel[]): EngineModel[] {
  const knownIds = new Set(provider.map((model) => model.id));
  return [
    ...provider,
    ...MUSE_CONTRIBUTOR_MODELS.filter((model) => !knownIds.has(model.id)).map((model) => ({ ...model })),
  ];
}

function museContributorModelsFromConfigOptions(options: unknown): EngineModel[] {
  return modelsFromConfigOptions(options).flatMap((model) => {
    const id = museContributorModelId(model.value)
      ?? MUSE_CONTRIBUTOR_ID_BY_LABEL.get(model.id)
      ?? (MUSE_CONTRIBUTOR_MODEL_IDS.has(model.id) ? model.id : null);
    if (!id) return [];
    return [{ id, label: MUSE_MODEL_LABELS[id]!, value: model.value }];
  });
}

export interface CatalogSources {
  /** The launcher for each engine, so the probe knows what to run. */
  launchers: Record<Engine, { command: string; args: string[] }>;
  /** Whether an engine's host binary is present on this machine. */
  available: Record<Engine, boolean>;
  /** A scratch directory the probe session may use. */
  probeCwd: string;
  /** Reads Muse's provider catalog; injectable for tests. */
  readMuseCatalog?: () => EngineModel[];
  /** Reads advertised options from an existing warm Muse bridge without starting it. */
  readMuseSessionOptions?: () => unknown;
  /** Limits ACP probe work to the selection, with legacy full discovery as the default. */
  probeScope?: CatalogProbeScope;
  /**
   * The drop-in engine plugins and what they contribute.
   *
   * The caller loads them (see {@link loadEnginePluginReport}) and hands the
   * result in, so the catalog never touches the plugin registry itself.
   */
  plugins?: EnginePluginReport;
  /**
   * Why an engine cannot run here, in the owner's words.
   *
   * The sidecar knows this: a missing launcher, a missing interpreter or an
   * unreachable credential.  It outranks any note the catalog would write
   * itself, because it names the one thing the owner has to fix.
   */
  notes?: Partial<Record<Engine, string>>;
}

function museDescriptor(sources: CatalogSources, provider: EngineModel[]): EngineDescriptor {
  const options = sources.readMuseSessionOptions?.();
  const advertised = museContributorModelsFromConfigOptions(options);
  const contributorProvider = provider.filter((model) => MUSE_CONTRIBUTOR_MODEL_IDS.has(model.id));
  const catalogModels = sources.available.muse ? withKnownMuseContributors(contributorProvider) : contributorProvider;
  const models = mergeMuseModels(advertised, catalogModels);
  // The note is written from the engine's own catalog, so a plugin's static
  // list never hides the fact that no session has been opened yet.
  const note = sources.notes?.muse
    ?? (!models.length ? "Start a Muse session to read its available models and effort choices."
      : provider.length > 0 && advertised.length < models.length
        ? "Includes models from the local Muse provider catalog."
        : undefined);
  return {
    id: "muse",
    label: "Muse Code",
    available: sources.available.muse,
    supportsThreads: supportsThreads("muse"),
    models: sources.available.muse ? mergePluginModels(models, pluginModelsFor(sources, "muse")) : models,
    effortLevels: MUSE_CONTRIBUTOR_EFFORT_LEVELS,
    effortConfigId: EFFORT_CONFIG_IDS.muse!,
    modelConfigId: "model",
    ...(note ? { note } : {}),
  };
}

/** Session choices and installation changes bypass the other engines' TTL. */
function withCurrentMuse(entry: CacheEntry, sources: CatalogSources): EngineCatalog {
  return { engines: entry.catalog.engines.map((engine) => engine.id === "muse" ? museDescriptor(sources, entry.museProviderModels) : engine) };
}

/**
 * The catalog for every engine this host can run.
 * Only MiniMax Code is probed; Muse uses passive local and warm-session data.
 */
export async function buildEngineCatalog(sources: CatalogSources): Promise<EngineCatalog> {
  return (await buildCatalogEntry(sources)).catalog;
}

async function buildCatalogEntry(sources: CatalogSources): Promise<Omit<CacheEntry, "at">> {
  const engines: EngineDescriptor[] = [];

  // A targeted scope probes just that engine; the full scope probes every
  // engine whose catalog is not passive.  Both are availability-guarded
  // below, so a host without the CLI pays nothing for the probe.
  const scope = scopeFor(sources);
  const probeTargets: Engine[] = scope === "passive" ? [] : scope === "full" ? ["mcode", "zcode"] : [scope];
  const probes = new Map<Engine, ProbeResult>();
  await Promise.all(
    probeTargets.map(async (engine) => {
      if (!sources.available[engine]) return;
      const launcher = sources.launchers[engine];
      const result = await probeEngineOptions(
        launcher.command,
        launcher.args,
        sources.probeCwd,
        EFFORT_CONFIG_IDS[engine] ?? "reasoning_effort",
      );
      probes.set(engine, result);
    }),
  );

  const museProviderModels = (sources.readMuseCatalog ?? readMuseProviderCatalog)();
  for (const engine of ENGINE_ORDER) {
    if (engine === "muse") {
      engines.push(museDescriptor(sources, museProviderModels));
      continue;
    }
    const available = sources.available[engine];
    const probed = probes.get(engine);
    let models: EngineModel[] = DSH_MODELS[engine] ?? [];
    let effortLevels = EFFORT_LEVELS[engine] ?? [];
    // The sidecar's own reason comes first: it names the one thing the owner
    // has to fix.  A plugin's sign-in note is the fallback.
    let note: string | undefined = sources.notes?.[engine]
      ?? (available ? undefined : pluginLoginNote(sources, engine));

    if (engine === "mcode") {
      models = probed?.models ?? [];
      effortLevels = probed?.initialized ? probed.efforts : effortLevels;
      if (!note && !models.length) note = "MiniMax Code did not advertise a model catalog on this host.";
    }

    // Z Code behaves like mcode: the probe's own catalog wins when the
    // session advertised one, and the plugin's declared catalog fills the
    // gap through mergePluginModels below.
    if (engine === "zcode") {
      models = probed?.models ?? models;
      effortLevels = probed?.initialized ? probed.efforts : effortLevels;
    }

    const mergedModels = mergePluginModels(models, pluginModelsFor(sources, engine));
    // Judged after the plugin merge, so a declared catalog never shows beside
    // a note saying there is none.
    if (engine === "zcode" && available && !note && !mergedModels.length) {
      note = "Z Code did not advertise a model catalog on this host.";
    }

    const descriptor: EngineDescriptor = {
      id: engine,
      label: ENGINE_LABELS[engine],
      available,
      supportsThreads: probed?.initialized ? probed.supportsThreads : supportsThreads(engine),
      models: mergedModels,
      effortLevels,
      effortConfigId: EFFORT_CONFIG_IDS[engine] ?? "reasoning_effort",
      modelConfigId: "model",
    };
    if (note) descriptor.note = note;
    engines.push(descriptor);
  }

  return { catalog: { engines }, museProviderModels };
}

/** The catalog, cached for a few minutes. */
export async function engineCatalog(sources: CatalogSources): Promise<EngineCatalog> {
  const probeScope = scopeFor(sources);
  const scope: CatalogCacheScope = probeScope;
  const now = Date.now();
  const cached = cache.get(scope);
  if (cached && now - cached.at < CATALOG_TTL_MS) return withCurrentMuse(cached, sources);
  // Concurrent readers share one build and one provider-catalog read.
  let pending = inflight.get(scope);
  if (!pending) {
    const generation = cacheGeneration;
    let building: Promise<CacheEntry>;
    building = buildCatalogEntry(sources)
      .then((entry) => {
        const completed = { at: Date.now(), ...entry };
        if (generation === cacheGeneration) cache.set(scope, completed);
        return completed;
      })
      .finally(() => {
        if (inflight.get(scope) === building) inflight.delete(scope);
      });
    inflight.set(scope, building);
    pending = building;
  }
  return withCurrentMuse(await pending, sources);
}

function scopeFor(sources: CatalogSources): CatalogProbeScope {
  return sources.probeScope ?? "full";
}

/**
 * The value to send for a requested model.
 *
 * A client asks for a model by id; the engine wants the exact wire value,
 * and the two differ for MiniMax Code (`m:minimax:…:v:`) and for Muse
 * (provider-qualified `muse-model:[…]`).  An unknown id is passed through
 * unchanged so a fresh model still works before the catalog catches up.
 */
export function resolveModelValue(catalog: EngineCatalog, engine: Engine, requested: string): string | null {
  const trimmed = requested.trim();
  if (!trimmed) return null;
  const descriptor = catalog.engines.find((entry) => entry.id === engine);
  if (!descriptor) return trimmed;
  const match = descriptor.models.find((model) => model.id === trimmed || model.value === trimmed);
  if (match) return match.value;
  const byLabel = descriptor.models.find((model) => model.label === trimmed);
  if (byLabel) return byLabel.value;
  return trimmed;
}

/**
 * The alternative spelling of a model, when the engine publishes one.
 *
 * Used when the first value was refused: Muse Code's adapter accepts the
 * bare id on some setups and the provider-qualified tuple on others, so
 * the second form gets its turn before the choice is given up on.
 */
export function resolveModelAltValue(catalog: EngineCatalog, engine: Engine, requested: string): string | null {
  const trimmed = requested.trim();
  if (!trimmed) return null;
  const descriptor = catalog.engines.find((entry) => entry.id === engine);
  if (!descriptor) return null;
  const match = descriptor.models.find((model) => model.id === trimmed || model.value === trimmed);
  return match?.altValue ?? null;
}
