/**
 * Engine-plugin discovery — find engine plugins on disk and turn them into
 * {@link AcpSupport} records, without a compile step.
 *
 * Search order, lowest precedence first:
 *   1. `engines/` in the package root  — plugins Clutch ships
 *   2. `$CLUTCH_HOME/engines`          — per-machine drop-ins (`~/.clutch/engines`)
 *
 * A later directory overrides an earlier one by `id`, and the overridden file
 * is reported in `superseded` so `clutch-engines list` can show that a local
 * file is shadowing a shipped one.  Two files with the same id *inside* one
 * directory are a conflict rather than an override: the first wins in sorted
 * order and the second becomes a problem, because within a directory there is
 * no principled way to say which was meant.
 *
 * Discovery never throws.  A malformed plugin is collected as a problem and
 * every other engine still loads: one bad file in a drop-in directory must not
 * take down the engines that work.
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import type { AcpSupport } from "../acp-core.ts";
import {
  ENGINE_MANIFEST_SUFFIX,
  ENGINE_MODULE_SUFFIX,
  engineSupportFromManifest,
  validateEngineManifest,
  type EngineManifest,
} from "./manifest.ts";

export type EnginePluginOrigin = "bundled" | "user";
export type EnginePluginKind = "manifest" | "module";

export interface EnginePlugin {
  readonly id: string;
  readonly kind: EnginePluginKind;
  readonly origin: EnginePluginOrigin;
  /** Absolute path of the file this plugin came from. */
  readonly file: string;
  readonly support: AcpSupport;
  /** The manifest, when the plugin is the declarative tier. */
  readonly manifest?: EngineManifest;
}

export interface EnginePluginProblem {
  readonly file: string;
  /** Present when the id could be read before validation failed. */
  readonly id?: string | undefined;
  readonly origin: EnginePluginOrigin;
  readonly problems: readonly string[];
}

export interface EnginePluginLoadResult {
  readonly plugins: readonly EnginePlugin[];
  readonly problems: readonly EnginePluginProblem[];
  /** Files that were overridden by a later directory, oldest first. */
  readonly superseded: readonly string[];
}

export interface EnginePluginOptions {
  /** Environment used to resolve `$CLUTCH_HOME`; injected in tests. */
  readonly env?: Record<string, string | undefined>;
  /** Override the search path entirely.  Defaults to bundled + user dirs. */
  readonly dirs?: readonly string[];
}

/** Package root, derived from this module's location.  Holds up both in the
 * repo (`src/shared/engines/` -> repo root) and installed under
 * `node_modules/clutch` (`src/shared/engines/` -> package root), because the
 * layout is the same in both. */
export function bundledEngineDir(env: Record<string, string | undefined> = process.env): string {
  return join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "engines");
}

/** `$CLUTCH_HOME/engines`, the per-machine drop-in directory. */
export function userEngineDir(env: Record<string, string | undefined> = process.env): string {
  const home = env["CLUTCH_HOME"] ?? join(env["HOME"] ?? homedir(), ".clutch");
  return join(home, "engines");
}

/** Default search path, lowest precedence first. */
export function enginePluginDirs(env: Record<string, string | undefined> = process.env): string[] {
  return [bundledEngineDir(env), userEngineDir(env)];
}

function isDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

/** The plugin files in one directory, sorted for a deterministic order. */
function pluginFiles(dir: string): string[] {
  if (!isDirectory(dir)) return [];
  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    // An unreadable directory (permissions, a dangling symlink) must not throw;
    // it is simply a directory with no plugins in it.
    return [];
  }
  return entries
    .filter((name) => name.endsWith(ENGINE_MANIFEST_SUFFIX) || name.endsWith(ENGINE_MODULE_SUFFIX))
    .sort()
    .map((name) => join(dir, name));
}

/**
 * The id a file claims, from its file name.  A file only reaches here by
 * matching a suffix, so its base name is never empty; the `file` fallback keeps
 * an id usable even if that ever stops being true.
 */
function idFromFile(file: string): string {
  const base = basename(file);
  const withoutSuffix = base.endsWith(ENGINE_MODULE_SUFFIX)
    ? base.slice(0, -ENGINE_MODULE_SUFFIX.length)
    : base.slice(0, -ENGINE_MANIFEST_SUFFIX.length);
  return withoutSuffix || file;
}

function parseJson(file: string): { value?: unknown; error?: string } {
  let text: string;
  try {
    text = readFileSync(file, "utf8");
  } catch (error) {
    return { error: `cannot read file: ${error instanceof Error ? error.message : String(error)}` };
  }
  try {
    return { value: JSON.parse(text) };
  } catch (error) {
    return { error: `invalid JSON: ${error instanceof Error ? error.message : String(error)}` };
  }
}

const SUPPORT_REQUIRED_FIELDS = ["driverKind", "displayName", "defaultCli", "nativeSource"] as const;

/** Minimal shape check for the programmatic tier, which does not go through
 * the manifest validator because it hands back a real `AcpSupport`. */
export function validateAcpSupport(value: unknown): string[] {
  const problems: string[] = [];
  if (typeof value !== "object" || value === null) return ["module does not export an AcpSupport object"];
  const support = value as Record<string, unknown>;
  for (const field of SUPPORT_REQUIRED_FIELDS) {
    if (typeof support[field] !== "string" || (support[field] as string).trim() === "") {
      problems.push(`${field} is required and must be a non-empty string`);
    }
  }
  const models = support["models"];
  if (typeof models !== "object" || models === null || !Array.isArray((models as { options?: unknown }).options)) {
    problems.push("models is required and must carry an options array");
  }
  if (typeof support["spawnArgs"] !== "function") {
    problems.push("spawnArgs is required and must be a function");
  }
  return problems;
}

type LoadedPlugin =
  | { plugin: EnginePlugin }
  | { problem: Omit<EnginePluginProblem, "file" | "origin"> };

async function loadManifestPlugin(
  file: string,
  origin: EnginePluginOrigin,
): Promise<LoadedPlugin> {
  const { value, error } = parseJson(file);
  if (error !== undefined) {
    return { problem: { id: idFromFile(file), problems: [error] } };
  }
  const problems = validateEngineManifest(value);
  const claimedId = (value as { id?: unknown } | undefined)?.id;
  const id = typeof claimedId === "string" && claimedId !== "" ? claimedId : idFromFile(file);
  if (problems.length > 0) {
    return { problem: { id, problems } };
  }
  try {
    const manifest = value as EngineManifest;
    return { plugin: { id, kind: "manifest", origin, file, support: engineSupportFromManifest(manifest), manifest } };
  } catch (error) {
    return {
      problem: {
        id,
        problems: [error instanceof Error ? error.message : String(error)],
      },
    };
  }
}

async function loadModulePlugin(file: string, origin: EnginePluginOrigin): Promise<LoadedPlugin> {
  const id = idFromFile(file);
  let module: Record<string, unknown>;
  try {
    module = (await import(pathToFileURL(file).href)) as Record<string, unknown>;
  } catch (error) {
    return { problem: { id, problems: [`import failed: ${error instanceof Error ? error.message : String(error)}`] } };
  }
  // Accept either `export default support` or `export const support`.
  const exported = module["default"] ?? module["support"];
  const unwrapped =
    typeof exported === "object" && exported !== null && "support" in (exported as Record<string, unknown>)
      ? (exported as Record<string, unknown>)["support"]
      : exported;
  const problems = validateAcpSupport(unwrapped);
  if (problems.length > 0) {
    return { problem: { id, problems } };
  }
  const support = unwrapped as AcpSupport;
  const declaredId = (support as unknown as { id?: unknown }).id;
  return {
    plugin: {
      id: typeof declaredId === "string" && declaredId !== "" ? declaredId : id,
      kind: "module",
      origin,
      file,
      support,
    },
  };
}

/**
 * Discover and load every engine plugin reachable from the search path.
 *
 * Never throws: unreadable directories, malformed JSON, invalid manifests and
 * modules that fail to import all land in `problems`.
 */
export async function loadEnginePlugins(options: EnginePluginOptions = {}): Promise<EnginePluginLoadResult> {
  const dirs = options.dirs ?? enginePluginDirs(options.env ?? process.env);
  const plugins = new Map<string, EnginePlugin>();
  const problems: EnginePluginProblem[] = [];
  const superseded: string[] = [];

  for (const [index, dir] of dirs.entries()) {
    // Position carries the precedence: the first directory is the base layer
    // (bundled plugins under the default search path) and every later
    // directory overrides it.
    const origin: EnginePluginOrigin = index === 0 ? "bundled" : "user";
    const files = pluginFiles(isAbsolute(dir) ? dir : resolve(dir));
    const claimedHere = new Set<string>();
    for (const file of files) {
      const loaded = file.endsWith(ENGINE_MODULE_SUFFIX)
        ? await loadModulePlugin(file, origin)
        : await loadManifestPlugin(file, origin);
      if ("problem" in loaded) {
        problems.push({ file, origin, ...loaded.problem });
        continue;
      }
      const { plugin } = loaded;
      if (claimedHere.has(plugin.id)) {
        // Same directory, same id: ambiguous, so the first (sorted) file keeps
        // the id and the other is reported rather than silently winning.
        problems.push({
          file,
          origin,
          id: plugin.id,
          problems: [`duplicate engine id ${JSON.stringify(plugin.id)} in the same directory; ${plugin.file} also declares it`],
        });
        continue;
      }
      const existing = plugins.get(plugin.id);
      if (existing) {
        superseded.push(existing.file);
        plugins.set(plugin.id, plugin);
      } else {
        plugins.set(plugin.id, plugin);
      }
      claimedHere.add(plugin.id);
    }
  }

  return {
    plugins: [...plugins.values()].sort((a, b) => a.id.localeCompare(b.id)),
    problems,
    superseded,
  };
}