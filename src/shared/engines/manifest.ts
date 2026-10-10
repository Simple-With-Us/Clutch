/**
 * Declarative engine-plugin manifests — the drop-in file format that produces
 * an {@link AcpSupport} with no TypeScript and no code execution.
 *
 * Why this exists: before it, every new engine was a code change spread across
 * five loosely-coupled places (an `AcpSupport` const in `src/<engine>/acp/`,
 * a `src/profiles/<name>/` dir, a `bridges/<name>/` + `scripts/<name>-acp.sh`
 * pair, two managed-key lists, and hardcoded strings in tests, docs and the
 * iOS app).  A plugin is instead one JSON file discovered at runtime.
 *
 * Two tiers exist:
 *   - **declarative** — `engines/<id>.engine.json`, described here.  Parsed,
 *     validated, and mapped onto `AcpSupport`.  Executes nothing.
 *   - **programmatic** — `engines/<id>.engine.mjs`, which exports an
 *     `AcpSupport` (or a partial) directly.  Same discovery, full power.
 *
 * See `docs/engine-plugins.md` for the authoring guide and
 * `docs/decisions/0006-engines-are-drop-in-files.md` for why.
 */

import type { AcpInstallInstructions, AcpSupport } from "../acp-core.ts";
import type { EffortLevel, ModelCatalog, ProviderErrorCode } from "../contracts.ts";

/** Schema tag carried by every declarative manifest.  Unknown versions are a
 * validation error rather than a best-effort load, so a stale plugin fails
 * loudly instead of half-working. */
export const ENGINE_MANIFEST_SCHEMA = "clutch.engine/v1";

/** File suffixes that make a file an engine plugin, in the order they are
 * parsed when the same id appears as both. */
export const ENGINE_MANIFEST_SUFFIX = ".engine.json";
export const ENGINE_MODULE_SUFFIX = ".engine.mjs";

export interface EngineManifestSpawn {
  /** Arguments passed to the ACP CLI.  The CLI path itself comes from
   * `AcpConfig.cli`, which the consumer resolves. */
  readonly args?: readonly string[];
  /** Environment variables to set on the spawned process.  Applied through
   * `transformEnv`, so an explicit value in the manifest wins over the
   * ambient one. */
  readonly env?: Readonly<Record<string, string>>;
}

export interface EngineManifestInstall {
  readonly command: { readonly darwin: string; readonly linux: string; readonly win32: string };
  readonly docsUrl?: string;
  readonly needsNode?: boolean;
}

export interface EngineManifestSelectModel {
  /** ACP `configId` that carries the model choice. */
  readonly configId: string;
  /**
   * Send the value the agent itself advertised on `session/new` instead of
   * constructing one.  Engines that refuse undeclared values (dsh, Muse) want
   * this; engines that accept a bare model id do not.
   */
  readonly advertised?: boolean;
  /** Exact model-id -> wire-value pairs for engines that do not map 1:1. */
  readonly values?: Readonly<Record<string, string>>;
  /** Applied to any model with no `values` entry, with `%model%` standing in
   * for the model id.  Ignored when `advertised` is set. */
  readonly template?: string;
}

export interface EngineManifestErrorRule {
  /** Regular-expression source, matched case-insensitively against the error
   * message and code.  First match wins, so order matters. */
  readonly pattern: string;
  readonly code: ProviderErrorCode;
}

export interface EngineManifestAuthenticated {
  /** Authenticated when any one of these env vars carries a value. */
  readonly anyEnv?: readonly string[];
  /** Authenticated when all of these carry values. */
  readonly allEnv?: readonly string[];
}

/** How a turn becomes prompt text.  `system-then-text` is the house default
 * (`dshSupport` and `minimaxSupport` both prepend the system prompt). */
export type EnginePromptText = "text-only" | "system-then-text";

export interface EngineManifest {
  readonly $schema?: string;
  readonly id: string;
  readonly driverKind: string;
  readonly displayName: string;
  readonly defaultCli: string;
  readonly nativeSource: string;
  readonly models: ModelCatalog;
  readonly images?: boolean;
  readonly perModelImages?: Readonly<Record<string, boolean>>;
  readonly effortLevels?: readonly EffortLevel[];
  readonly perModelEffortLevels?: Readonly<Record<string, readonly EffortLevel[]>>;
  readonly mcpServers?: boolean;
  readonly loginNote?: string;
  readonly install?: EngineManifestInstall;
  readonly spawn?: EngineManifestSpawn;
  readonly resumeMethod?: string;
  readonly selectModel?: EngineManifestSelectModel;
  readonly errorRules?: readonly EngineManifestErrorRule[];
  readonly credentialEnv?: readonly string[];
  readonly authFailure?: "continue" | "abort";
  readonly authenticatedWhen?: EngineManifestAuthenticated;
  /**
   * The engine publishes no ACP `authMethods`, so auth negotiation always
   * returns nothing.  Engines that *do* publish methods (Muse publishes an
   * `env_var` one) should leave this off and let the consumer pick.
   */
  readonly noAuthNegotiation?: boolean;
  readonly promptText?: EnginePromptText;
}

const PROVIDER_ERROR_CODES: ReadonlySet<string> = new Set<ProviderErrorCode>([
  "invalid_credentials",
  "inactive_subscription",
  "quota_or_region_restriction",
  "upstream_outage",
  "model_catalog_outage",
  "unknown",
]);

const EFFORT_LEVELS: ReadonlySet<string> = new Set<EffortLevel>([
  "none",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

/**
 * Validate a parsed manifest against the schema.
 *
 * Returns every problem rather than the first, so an author fixing a plugin
 * sees the whole list at once.  A manifest with any problem is never mapped —
 * a half-valid engine is worse than a missing one.
 */
export function validateEngineManifest(value: unknown): string[] {
  const problems: string[] = [];
  if (!isRecord(value)) return ["manifest is not a JSON object"];

  const schema = value["$schema"];
  if (schema !== undefined && schema !== ENGINE_MANIFEST_SCHEMA) {
    problems.push(`$schema is ${JSON.stringify(schema)}, expected ${JSON.stringify(ENGINE_MANIFEST_SCHEMA)}`);
  }

  for (const field of ["id", "driverKind", "displayName", "defaultCli", "nativeSource"] as const) {
    if (!nonEmptyString(value[field])) problems.push(`${field} is required and must be a non-empty string`);
  }

  // The id has to be a safe filename fragment: it names the plugin, keys the
  // registry, and shows up in `clutch-engines list` output.
  const id = value["id"];
  if (nonEmptyString(id) && !/^[a-z0-9][a-z0-9._-]*$/i.test(id)) {
    problems.push(`id ${JSON.stringify(id)} must match /^[a-z0-9][a-z0-9._-]*$/`);
  }

  const models = value["models"];
  if (!isRecord(models)) {
    problems.push("models is required and must be an object");
  } else {
    if (!nonEmptyString(models["default"])) problems.push("models.default is required and must be a non-empty string");
    if (!Array.isArray(models["options"])) {
      problems.push("models.options is required and must be an array");
    } else {
      const ids = new Set<string>();
      models["options"].forEach((option, index) => {
        if (!isRecord(option) || !nonEmptyString(option["id"]) || !nonEmptyString(option["label"])) {
          problems.push(`models.options[${index}] needs a non-empty id and label`);
          return;
        }
        const optionId = option["id"];
        if (ids.has(optionId)) problems.push(`models.options[${index}] repeats model id ${JSON.stringify(optionId)}`);
        ids.add(optionId);
      });
      // A default outside the catalog is the classic silent bug: the picker
      // cannot offer a model the engine would then be sent by default.
      if (nonEmptyString(models["default"]) && Array.isArray(models["options"]) && !ids.has(models["default"])) {
        problems.push(`models.default ${JSON.stringify(models["default"])} is not in models.options`);
      }
    }
  }

  for (const field of ["effortLevels", "perModelEffortLevels"] as const) {
    const value_ = value[field];
    if (value_ === undefined) continue;
    const levels = field === "effortLevels" ? value_ : Object.values((value_ as Record<string, unknown>) ?? {});
    const flat = (Array.isArray(levels) ? levels : []).flat();
    for (const level of flat) {
      if (typeof level === "string" && !EFFORT_LEVELS.has(level)) {
        problems.push(`${field} has unknown effort level ${JSON.stringify(level)}`);
      }
    }
  }

  const rules = value["errorRules"];
  if (rules !== undefined) {
    if (!Array.isArray(rules)) {
      problems.push("errorRules must be an array");
    } else {
      rules.forEach((rule, index) => {
        if (!isRecord(rule) || !nonEmptyString(rule["pattern"])) {
          problems.push(`errorRules[${index}] needs a pattern`);
          return;
        }
        try {
          new RegExp(rule["pattern"] as string, "i");
        } catch {
          problems.push(`errorRules[${index}].pattern is not a valid regular expression`);
        }
        if (!PROVIDER_ERROR_CODES.has(String(rule["code"]))) {
          problems.push(`errorRules[${index}].code is not a ProviderErrorCode`);
        }
      });
    }
  }

  const auth = value["authenticatedWhen"];
  if (auth !== undefined && !isRecord(auth)) {
    problems.push("authenticatedWhen must be an object");
  }

  const select = value["selectModel"];
  if (select !== undefined) {
    if (!isRecord(select) || !nonEmptyString(select["configId"])) {
      problems.push("selectModel needs a configId");
    } else if (select["advertised"] !== true && select["values"] === undefined && select["template"] === undefined) {
      problems.push("selectModel needs one of advertised, values, or template");
    }
  }

  const authFailure = value["authFailure"];
  if (authFailure !== undefined && authFailure !== "continue" && authFailure !== "abort") {
    problems.push('authFailure must be "continue" or "abort"');
  }

  return problems;
}

/** Split a `%model%` template into the constant text before and after the
 * placeholder, so `modelForValue` can reverse it. */
function splitTemplate(template: string): [string, string] {
  const at = template.indexOf("%model%");
  if (at === -1) return [template, ""];
  return [template.slice(0, at), template.slice(at + "%model%".length)];
}

/** Build the `selectModel` translator a manifest describes, or `undefined`
 * when the manifest does not describe one. */
function manifestSelectModel(
  select: EngineManifestSelectModel | undefined,
): AcpSupport["selectModel"] | undefined {
  if (!select) return undefined;
  const { configId, advertised, values, template } = select;
  const exact = values ? new Map(Object.entries(values)) : new Map<string, string>();
  const applyTemplate = (model: string): string | null =>
    template ? template.replaceAll("%model%", model) : null;

  return {
    configId,
    valueForModel: (model: string, advertisedValue?: unknown) => {
      // Prefer whatever the host advertised, because it is the only value
      // guaranteed to be one it will accept.  Fall back to the manifest's own
      // map when it advertised nothing, which is common before a first turn.
      if (advertised === true && typeof advertisedValue === "string") return advertisedValue;
      return exact.get(model) ?? applyTemplate(model);
    },
    modelForValue: (value: unknown) => {
      if (typeof value !== "string") return null;
      for (const [model, wire] of exact) {
        if (wire === value) return model;
      }
      // Reverse the template: whatever sat around `%model%` is the constant
      // framing, so the middle of a matching value is the model id back.
      if (template) {
        const [prefix, suffix] = splitTemplate(template);
        const end = value.length - suffix.length;
        if (end >= prefix.length && value.startsWith(prefix) && value.endsWith(suffix)) {
          return value.slice(prefix.length, end);
        }
      }
      return null;
    },
  };
}

/** Compile `errorRules` into the `classifyError` the runtime expects. */
function manifestClassifyError(
  rules: readonly EngineManifestErrorRule[] | undefined,
): AcpSupport["classifyError"] | undefined {
  if (!rules || rules.length === 0) return undefined;
  const compiled = rules.map((rule) => ({ re: new RegExp(rule.pattern, "i"), code: rule.code }));
  return (error: unknown): string | undefined => {
    // ACP transports reject with a plain `{ code, message }` object rather
    // than an Error, and String() on one of those yields "[object Object]",
    // silently losing the only text worth matching.  Read `message` off any
    // object that has one.
    const message =
      error instanceof Error
        ? error.message
        : typeof error === "object" && error !== null && typeof (error as { message?: unknown }).message === "string"
          ? (error as { message: string }).message
          : String(error ?? "");
    const code = error && typeof error === "object" ? (error as { code?: unknown }).code : undefined;
    const blob = `${code ?? ""} ${message}`.toLowerCase();
    return compiled.find((rule) => rule.re.test(blob))?.code;
  };
}

/** Compile `authenticatedWhen` into the `isAuthenticated` predicate. */
function manifestIsAuthenticated(
  when: EngineManifestAuthenticated | undefined,
): AcpSupport["isAuthenticated"] | undefined {
  if (!when) return undefined;
  const any = when.anyEnv ?? [];
  const all = when.allEnv ?? [];
  if (any.length === 0 && all.length === 0) return undefined;
  return (env: Record<string, string | undefined>) => {
    const anyHit = any.length === 0 || any.some((name) => Boolean(env[name]));
    const allHit = all.every((name) => Boolean(env[name]));
    return anyHit && allHit;
  };
}

/**
 * Map a validated manifest onto an {@link AcpSupport}.
 *
 * Throws on an invalid manifest: callers discover through
 * {@link import("./discover.ts").loadEnginePlugins}, which catches per file so
 * one broken plugin cannot take the others down.
 */
export function engineSupportFromManifest(manifest: EngineManifest): AcpSupport {
  const problems = validateEngineManifest(manifest);
  if (problems.length > 0) {
    throw new Error(`invalid engine manifest ${manifest?.id ?? "<unknown>"}: ${problems.join("; ")}`);
  }

  const spawn = manifest.spawn;
  const install: AcpInstallInstructions | undefined = manifest.install
    ? {
        command: {
          darwin: manifest.install.command.darwin,
          linux: manifest.install.command.linux,
          win32: manifest.install.command.win32,
        },
        ...(manifest.install.docsUrl === undefined ? {} : { docsUrl: manifest.install.docsUrl }),
        ...(manifest.install.needsNode === undefined ? {} : { needsNode: manifest.install.needsNode }),
      }
    : undefined;

  // `AcpSupport` is readonly by design; the mapper needs to fill optional keys
  // in only when the manifest declares them, so build through a mutable view of
  // the same shape and hand back the readonly one.
  type MutableSupport = { -readonly [K in keyof AcpSupport]: AcpSupport[K] };

  const support: MutableSupport = {
    driverKind: manifest.driverKind,
    displayName: manifest.displayName,
    models: manifest.models,
    defaultCli: manifest.defaultCli,
    nativeSource: manifest.nativeSource,
    spawnArgs: () => [...(spawn?.args ?? [])],
  };

  // Assigned one at a time so `exactOptionalPropertyTypes` stays honest: an
  // absent manifest key leaves the key absent on the support record rather
  // than present-and-undefined.
  if (manifest.images !== undefined) support.images = manifest.images;
  if (manifest.perModelImages !== undefined) support.perModelImages = manifest.perModelImages;
  if (manifest.effortLevels !== undefined) support.effortLevels = manifest.effortLevels;
  if (manifest.perModelEffortLevels !== undefined) support.perModelEffortLevels = manifest.perModelEffortLevels;
  if (manifest.mcpServers !== undefined) support.mcpServers = manifest.mcpServers;
  if (manifest.loginNote !== undefined) support.loginNote = manifest.loginNote;
  if (install !== undefined) support.install = install;
  if (manifest.resumeMethod !== undefined) support.resumeMethod = manifest.resumeMethod;
  if (manifest.credentialEnv !== undefined) support.credentialEnv = manifest.credentialEnv;
  if (manifest.authFailure !== undefined) support.authFailure = manifest.authFailure;

  const selectModel = manifestSelectModel(manifest.selectModel);
  if (selectModel !== undefined) support.selectModel = selectModel;

  const classifyError = manifestClassifyError(manifest.errorRules);
  if (classifyError !== undefined) support.classifyError = classifyError;

  const isAuthenticated = manifestIsAuthenticated(manifest.authenticatedWhen);
  if (isAuthenticated !== undefined) support.isAuthenticated = isAuthenticated;

  // Engines whose ACP adapter never publishes auth methods get a null pick.
  if (spawn?.env && Object.keys(spawn.env).length > 0) {
    const overrides = { ...spawn.env };
    support.transformEnv = (env: Record<string, string | undefined>) => {
      for (const [name, value] of Object.entries(overrides)) env[name] = value;
    };
  }

  if (manifest.noAuthNegotiation === true) {
    support.pickAuthMethod = () => null;
  }

  support.buildPromptText = (turn) =>
    manifest.promptText === "text-only" || !turn.system ? turn.text : `${turn.system}\n\n${turn.text}`;

  return support;
}