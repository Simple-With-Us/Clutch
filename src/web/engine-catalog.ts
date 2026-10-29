/**
 * The engine catalog the native apps read: which engines a host can run,
 * which models each engine offers right now, and which reasoning-effort
 * levels it accepts.
 *
 * The web canvas (upstream `dsh web`) shows a model picker with a per-model
 * effort control, and the native chat wanted the same thing.  Rather than
 * hardcode a list that goes stale the moment a provider ships a model, this
 * asks the engines themselves:
 *
 *   - **MiniMax Code** and **Muse Code** advertise their real choices on
 *     ACP `session/new` (`configOptions`), so a probe session reads the
 *     engine's own catalog.  The probe session is closed again right after.
 *   - **Muse Code** additionally publishes a provider catalog on disk
 *     (`~/.local/share/muse/model-catalog/*.json`), which is where a model
 *     the account can reach but the ACP session does not advertise (Muse
 *     Wonder, for one) shows up.  Reading it is what lets the picker offer
 *     Muse Wonder instead of the engine's built-in fallback list.
 *   - **DeepSeek** and **MiniMax** run through the dsh bridges, which do not
 *     advertise config options, so their catalog comes from the repo's
 *     tracked model lists.
 *
 * Everything here is read-only and cached for a few minutes: a catalog read
 * must never cost a model turn.
 */
import { spawn } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { Engine } from "../shared/engine-types.ts";
import { supportsThreads } from "../shared/engine-types.ts";

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

const CATALOG_TTL_MS = 5 * 60 * 1000;

interface CacheEntry {
  at: number;
  catalog: EngineCatalog;
}

let cache: CacheEntry | null = null;

/** Drop the cached catalog; the next read probes the engines again. */
export function resetEngineCatalogCache(): void {
  cache = null;
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
  muse: ["none", "minimal", "low", "medium", "high", "xhigh", "ultra"],
};

const EFFORT_CONFIG_IDS: Record<string, string> = {
  deepseek: "reasoning_effort",
  minimax: "reasoning_effort",
  mcode: "thinkingEffort",
  muse: "reasoningEffort",
};

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

/**
 * The Muse models published in the local provider catalog.
 *
 * `~/.local/share/muse/model-catalog/*.json` is written by the Muse CLI from
 * the provider's own catalog.  Hidden rows are skipped: they are not offered
 * to an account.
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
      if (!id) continue;
      if (row.visibility === "hidden") continue;
      const label = typeof row.display_label === "string" && row.display_label.length > 0 ? row.display_label : id;
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
          const result = message.result ?? {};
          sessionId = typeof result.sessionId === "string" ? result.sessionId : null;
          if (Array.isArray(result.configOptions)) options.push(...result.configOptions);
          if (sessionId) {
            // Close the probe session; the answer is in the options we read.
            send({ jsonrpc: "2.0", id: 3, method: "session/close", params: { sessionId } });
          } else {
            clearTimeout(timer);
            finish({
              models: modelsFromConfigOptions(options),
              efforts: effortsFromConfigOptions(options, effortConfigId),
              supportsThreads,
              initialized: true,
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
  const seen = new Set(advertised.map((model) => model.value));
  const merged = [...advertised];
  for (const model of provider) {
    if (seen.has(model.value)) continue;
    seen.add(model.value);
    merged.push(model);
  }
  return merged;
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
}

/**
 * The catalog for every engine this host can run.  Probes only the engines
 * that advertise models (MiniMax Code and Muse Code); the dsh bridges answer
 * from the tracked lists.
 */
export async function buildEngineCatalog(sources: CatalogSources): Promise<EngineCatalog> {
  const engines: EngineDescriptor[] = [];

  const probeTargets: Engine[] = ["mcode", "muse"];
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

  for (const engine of ["deepseek", "minimax", "mcode", "muse"] as Engine[]) {
    const available = sources.available[engine];
    const probed = probes.get(engine);
    let models: EngineModel[] = DSH_MODELS[engine] ?? [];
    let effortLevels = EFFORT_LEVELS[engine] ?? [];
    let note: string | undefined;

    if (engine === "muse") {
      const provider = (sources.readMuseCatalog ?? readMuseProviderCatalog)();
      models = mergeMuseModels(probed?.models ?? [], provider);
      effortLevels = probed?.initialized ? probed.efforts : effortLevels;
      if (!models.length) {
        note = "Muse Code did not advertise a model catalog on this host.";
      } else if (provider.length > 0 && probed && probed.models.length < provider.length) {
        note = "Includes models from the Muse provider catalog that this session does not advertise.";
      }
    } else if (engine === "mcode") {
      models = probed?.models ?? [];
      effortLevels = probed?.initialized ? probed.efforts : effortLevels;
      if (!models.length) note = "MiniMax Code did not advertise a model catalog on this host.";
    }

    const descriptor: EngineDescriptor = {
      id: engine,
      label: engine === "mcode" ? "MiniMax Code" : engine === "muse" ? "Muse Code" : engine === "minimax" ? "MiniMax" : "DeepSeek",
      available,
      supportsThreads: probed?.initialized ? probed.supportsThreads : supportsThreads(engine),
      models,
      effortLevels,
      effortConfigId: EFFORT_CONFIG_IDS[engine] ?? "reasoning_effort",
      modelConfigId: "model",
    };
    if (note) descriptor.note = note;
    engines.push(descriptor);
  }

  return { engines };
}

/** The catalog, cached for a few minutes. */
export async function engineCatalog(sources: CatalogSources): Promise<EngineCatalog> {
  const now = Date.now();
  if (cache && now - cache.at < CATALOG_TTL_MS) return cache.catalog;
  // One probe per engine, however many clients ask at once: two phones
  // opening the Code tab must not spawn four probe processes.
  if (!inflight) {
    inflight = buildEngineCatalog(sources)
      .then((catalog) => {
        cache = { at: Date.now(), catalog };
        return catalog;
      })
      .finally(() => {
        inflight = null;
      });
  }
  return inflight;
}

/** The probe currently running, so a second reader waits for it. */
let inflight: Promise<EngineCatalog> | null = null;

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
