// =============================================================================
// clutchSettings — Clutch app settings on the Infisical sole-source-of-truth
// =============================================================================
//
// Clutch's app-level settings (secrets, env config, tunable knobs) live in
// the "Clutch" Infisical project (ID 077fd6f3-9f9b-438e-9b6f-5c69076cf36c).
// This module implements the fleet canonical pattern (see INFISICAL.md):
//
//   - initClutchSettings() loads the full settings set at startup into an
//     in-memory cache.  When universal-auth credentials are present it loads
//     from Infisical; otherwise it seeds the cache from process.env with a
//     loud warning (local dev / offline fallback — never silent).
//   - After a successful Infisical load, owned keys that are NOT already set
//     in process.env are backfilled from the cache.  Explicitly-set env vars
//     always win (local override).  Backfilling is the delivery mechanism:
//     every downstream reader (ACP driver env params, Python bridges, child
//     processes via env inheritance) sees Infisical values with zero code
//     churn, and no path ever fetches from Infisical per-request.
//   - get() reads the cache (falling back to the schema default); it never
//     touches the network.
//   - set() is write-through: Infisical FIRST, then cache + process.env.
//     In env-seed mode (no Infisical credentials) set() fails loudly — the
//     cache and Infisical are never allowed to diverge silently.
//   - refresh() re-reads Infisical and swaps the cache; failures log loudly
//     and keep the last-known-good cache.
//
// Admin gating: Clutch is a single-user local tool (web UI on loopback +
// Tailscale, CLI as the machine user).  The local user IS the admin, so the
// gate is a documented no-op — there is no multi-user role system to check
// against.  The admin write surface is the `clutch-settings` CLI and the
// Infisical UI itself.
//
// Per-user settings do NOT live here: the iOS companion keeps its per-host
// connection records in its own on-device store.  See INFISICAL.md.
//
// Bootstrap vars (CLUTCH_HOME, CLUTCH_RUNTIME_ROOT, DSH_HOME) are NOT managed
// here: the bash layer (scripts/lib/clutch-env.sh) needs them before Node
// starts.  See scripts/lib/clutch-infisical-env.sh, which backfills the
// managed keys from Infisical for the always-on bash path (pm2).

import {
  createInfisicalSettings,
  InfisicalWriteError,
  type InfisicalSettings,
} from "./infisicalSettings.ts";

export const CLUTCH_INFISICAL_PROJECT_ID = "077fd6f3-9f9b-438e-9b6f-5c69076cf36c";
export const CLUTCH_INFISICAL_ENV_VAR = "CLUTCH_INFISICAL_ENV";
export const CLUTCH_INFISICAL_DEFAULT_ENV = "prod";

export interface ClutchSettingDef {
  /** Setting key, as stored in Infisical and process.env. */
  key: string;
  /** secret | config | knob — secrets are never printed, echoed, or logged. */
  kind: "secret" | "config" | "knob";
  /** Default when neither Infisical nor process.env provides a value. */
  defaultValue: string;
  /** Human description for INFISICAL.md and `clutch-settings list`. */
  description: string;
}

/**
 * The managed key inventory.  Keep in sync with:
 *   - INFISICAL.md "Key inventory" section
 *   - scripts/lib/clutch-infisical-env.sh CLUTCH_MANAGED_KEYS
 */
export const CLUTCH_SETTINGS_SCHEMA: ClutchSettingDef[] = [
  { key: "MINIMAX_API_KEY", kind: "secret", defaultValue: "", description: "MiniMax API key (MiniMax provider auth)" },
  { key: "DEEPSEEK_API_KEY", kind: "secret", defaultValue: "", description: "DeepSeek API key (DeepSeek provider auth)" },
  { key: "META_API_KEY", kind: "secret", defaultValue: "", description: "Meta API key (Muse Code engine auth; the keychain credential is not readable by a spawned host)" },
  { key: "CLUTCH_MINIMAX_API_KEY_NAME", kind: "config", defaultValue: "MINIMAX_API_KEY", description: "Env var name holding the MiniMax key" },
  { key: "CLUTCH_MINIMAX_BASE_URL", kind: "config", defaultValue: "https://api.minimax.io/v1", description: "MiniMax API base URL" },
  { key: "CLUTCH_MINIMAX_MODEL", kind: "config", defaultValue: "MiniMax-M2.7-highspeed", description: "Default MiniMax model" },
  { key: "CLUTCH_MINIMAX_PROFILE", kind: "config", defaultValue: "minimax-headless", description: "Default MiniMax cordis profile" },
  { key: "CLUTCH_WEB_HOST", kind: "config", defaultValue: "127.0.0.1", description: "Clutch web bind host" },
  { key: "CLUTCH_WEB_PORT", kind: "config", defaultValue: "3180", description: "Clutch web port" },
  { key: "CLUTCH_TAILNET_HOST", kind: "config", defaultValue: "", description: "Override for the detected Tailscale MagicDNS name" },
  { key: "CLUTCH_TAILNET_IPV4", kind: "config", defaultValue: "", description: "Optional Tailscale IPv4 to trust for /api" },
  { key: "CLUTCH_TRUSTED_HOSTS", kind: "config", defaultValue: "", description: "Extra comma-separated trusted Host values for /api" },
  { key: "CLUTCH_SETTINGS_REFRESH_MS", kind: "knob", defaultValue: "300000", description: "Background settings refresh interval (ms)" },
  { key: "COMETCHAT_APP_ID", kind: "config", defaultValue: "", description: "CometChat App ID (native chat coordinates)" },
  { key: "COMETCHAT_REGION", kind: "config", defaultValue: "", description: "CometChat region (us, eu, or in)" },
  { key: "COMETCHAT_AUTH_KEY", kind: "secret", defaultValue: "", description: "CometChat Auth Key served to the paired phone (dev-grade; server-minted tokens are the follow-up)" },
  { key: "COMETCHAT_REST_API_KEY", kind: "secret", defaultValue: "", description: "CometChat REST key, backend-only (sidecar relay auth)" },
  { key: "COMETCHAT_AGENT_UID", kind: "config", defaultValue: "clutch-agent", description: "Agent user uid the relay speaks on behalf of" },
  { key: "CLUTCH_AGENT_PROXY_ENABLED", kind: "knob", defaultValue: "false", description: "Enable routing agent network requests through Infisical Agent Proxy" },
  { key: "CLUTCH_AGENT_PROXY_ADDRESS", kind: "config", defaultValue: "127.0.0.1:17322", description: "Address of the local Infisical Agent Proxy (host:port)" },
  { key: "CLUTCH_AGENT_PROXY_PROJECT_ID", kind: "config", defaultValue: "", description: "Infisical Project ID for Agent Proxy (defaults to Clutch project)" },
  { key: "CLUTCH_AGENT_PROXY_ENV", kind: "config", defaultValue: "prod", description: "Infisical environment for Agent Proxy secrets" },
  { key: "CLUTCH_AGENT_PROXY_PATH", kind: "config", defaultValue: "/", description: "Infisical secret path folder scope for Agent Proxy" },
  { key: "CLUTCH_AGENT_PROXY_CA_CERT_PATH", kind: "config", defaultValue: "", description: "Optional CA certificate file path for Infisical Agent Proxy TLS MITM" },
];

const SCHEMA_BY_KEY = new Map(CLUTCH_SETTINGS_SCHEMA.map((d) => [d.key, d]));

export type ClutchSettingsSource = "infisical" | "env-seed";

const LOG_PREFIX = "[clutch-settings]";

function isSecretKey(key: string): boolean {
  return SCHEMA_BY_KEY.get(key)?.kind === "secret";
}

function isAgentProxyKey(key: string): boolean {
  return key.startsWith("CLUTCH_AGENT_PROXY_");
}

/**
 * Agent proxy setting values Clutch itself wrote into process.env (from
 * Infisical or from set()), so a refresh can tell them apart from a value the
 * operator set and keep them current.
 */
const backfilledAgentProxySettings = new Map<string, string>();

/** Names only — never log values, especially secrets. */
function describeKeys(keys: Iterable<string>): string {
  return [...keys].join(", ");
}

export interface ClutchSettings {
  /** Where this instance's values came from. */
  readonly source: ClutchSettingsSource;
  /** Read a managed setting: Infisical/env value, else the schema default.  Never hits the network. */
  get(key: string): string;
  /** True when the setting has a non-empty value (cache or default). */
  has(key: string): boolean;
  /** Snapshot of all managed settings with defaults applied.  Never hits the network. */
  getAll(): Record<string, string>;
  /**
   * Write-through save: persists to Infisical FIRST, then updates the cache
   * and process.env.  Rejects when Infisical is not configured or the write
   * fails — the save fails instead of diverging.
   */
  set(key: string, value: string): Promise<void>;
  /** Re-read Infisical, swap the cache, re-backfill process.env.  No-op in env-seed mode. */
  refresh(): Promise<void>;
  /** Stop the background refresh timer. */
  stop(): void;
  /** The underlying Infisical client (undefined in env-seed mode). */
  readonly client: InfisicalSettings | undefined;
}

class ClutchSettingsImpl implements ClutchSettings {
  readonly source: ClutchSettingsSource;
  readonly client: InfisicalSettings | undefined;
  /** Values seeded from process.env at startup (env-seed mode only). */
  private readonly seed: Map<string, string>;

  constructor(client: InfisicalSettings | undefined, seed: Map<string, string>) {
    this.client = client;
    this.seed = seed;
    this.source = client === undefined ? "env-seed" : "infisical";
  }

  get(key: string): string {
    const def = SCHEMA_BY_KEY.get(key);
    // Explicitly-set env vars always win (local override) — this matches the
    // backfill rule, so get() and downstream process.env readers agree.
    const explicit = process.env[key];
    if (explicit !== undefined && explicit.length > 0) return explicit;
    if (this.client !== undefined) {
      const cached = this.client.get(key);
      if (cached !== undefined) return cached;
    } else {
      const seeded = this.seed.get(key);
      if (seeded !== undefined) return seeded;
    }
    return def?.defaultValue ?? "";
  }

  has(key: string): boolean {
    return this.get(key).length > 0;
  }

  getAll(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const def of CLUTCH_SETTINGS_SCHEMA) out[def.key] = this.get(def.key);
    return out;
  }

  async set(key: string, value: string): Promise<void> {
    if (SCHEMA_BY_KEY.get(key) === undefined) {
      throw new Error(`${LOG_PREFIX} refusing to manage unknown key "${key}" — add it to CLUTCH_SETTINGS_SCHEMA first`);
    }
    if (this.client === undefined) {
      throw new InfisicalWriteError(
        key,
        "Infisical is not configured (no universal-auth credentials); refusing to save to process.env only — configure Infisical or edit the Infisical UI directly",
      );
    }
    // Write-through: Infisical FIRST, then cache (inside client.set), then
    // the process backfill so child processes inherit the new value.
    await this.client.set(key, value);
    process.env[key] = value;
    if (isAgentProxyKey(key)) {
      backfilledAgentProxySettings.set(key, value);
      applyAgentProxyToProcessEnv();
    }
  }

  async refresh(): Promise<void> {
    if (this.client === undefined) return; // env-seed mode: nothing to refresh.
    await this.client.refresh();
    backfillProcessEnv(this.client);
  }

  stop(): void {
    this.client?.stop();
  }
}

/**
 * Proxy variables Clutch itself wrote into process.env (name -> value), so a
 * later disable or address change can undo exactly those and never touch a
 * value the operator set.
 */
const injectedProxyEnv = new Map<string, string>();

function removeInjectedProxyEnv(): void {
  for (const [name, value] of injectedProxyEnv) {
    // Only remove what we wrote: a value changed since then belongs to the operator.
    if (process.env[name] === value) delete process.env[name];
  }
  injectedProxyEnv.clear();
}

/** Fill `names` with `value` unless the operator already set any of them. */
function injectProxyEnv(names: readonly string[], value: string): void {
  if (!value || names.some((name) => process.env[name])) return;
  for (const name of names) {
    process.env[name] = value;
    injectedProxyEnv.set(name, value);
  }
}

/**
 * Reconciles the agent proxy variables in process.env with the current
 * CLUTCH_AGENT_PROXY_* settings: when CLUTCH_AGENT_PROXY_ENABLED is "true",
 * "1" or "yes" it injects them (only where unset), and otherwise it removes
 * the ones it injected earlier.  A changed address, project, environment,
 * path or CA path re-points the injected values the same way.
 * Downstream child processes (ACP drivers, engines, Python bridges)
 * inherit process.env directly.
 */
export function applyAgentProxyToProcessEnv(): void {
  // Undo our earlier injection first, so a disable or an address change never
  // leaves a stale value behind; operator-set variables are left alone.
  removeInjectedProxyEnv();
  const rawEnabled = process.env.CLUTCH_AGENT_PROXY_ENABLED ?? SCHEMA_BY_KEY.get("CLUTCH_AGENT_PROXY_ENABLED")?.defaultValue ?? "false";
  const enabled = rawEnabled.trim().toLowerCase();
  if (enabled !== "true" && enabled !== "1" && enabled !== "yes") {
    return;
  }
  const address = (process.env.CLUTCH_AGENT_PROXY_ADDRESS || SCHEMA_BY_KEY.get("CLUTCH_AGENT_PROXY_ADDRESS")?.defaultValue || "127.0.0.1:17322").trim();
  const proxyUrl = `http://${address}`;
  const projectId = (process.env.CLUTCH_AGENT_PROXY_PROJECT_ID || CLUTCH_INFISICAL_PROJECT_ID).trim();
  const env = (process.env.CLUTCH_AGENT_PROXY_ENV || SCHEMA_BY_KEY.get("CLUTCH_AGENT_PROXY_ENV")?.defaultValue || "prod").trim();
  const path = (process.env.CLUTCH_AGENT_PROXY_PATH || SCHEMA_BY_KEY.get("CLUTCH_AGENT_PROXY_PATH")?.defaultValue || "/").trim();
  const caCertPath = (process.env.CLUTCH_AGENT_PROXY_CA_CERT_PATH || "").trim();

  injectProxyEnv(["HTTP_PROXY", "http_proxy"], proxyUrl);
  injectProxyEnv(["HTTPS_PROXY", "https_proxy"], proxyUrl);
  injectProxyEnv(["ALL_PROXY", "all_proxy"], proxyUrl);
  injectProxyEnv(["NO_PROXY", "no_proxy"], "localhost,127.0.0.1");
  injectProxyEnv(["INFISICAL_AGENT_PROXY_ADDRESS"], address);
  injectProxyEnv(["INFISICAL_PROJECT_ID"], projectId);
  injectProxyEnv(["INFISICAL_ENVIRONMENT"], env);
  injectProxyEnv(["INFISICAL_SECRET_PATH"], path);
  injectProxyEnv(["SSL_CERT_FILE"], caCertPath);
  injectProxyEnv(["NODE_EXTRA_CA_CERTS"], caCertPath);
}

/**
 * Copy Infisical-sourced values into process.env for managed keys that are
 * not already set.  Explicitly-set env vars always win (local override).
 * This is the delivery mechanism: downstream readers — ACP driver env
 * params, Python bridges, spawned child processes — see Infisical values
 * with zero code churn, and nothing fetches per-request.
 *
 * The agent proxy keys are the exception to "fill once": a value Clutch
 * itself wrote follows later Infisical changes (and is removed when the key
 * is deleted there), so a refresh can re-point or switch off the proxy.  A
 * value the operator set is still left alone.
 */
function backfillProcessEnv(client: InfisicalSettings): void {
  const filled: string[] = [];
  const removed: string[] = [];
  for (const def of CLUTCH_SETTINGS_SCHEMA) {
    const current = process.env[def.key];
    const cached = client.get(def.key);
    const next = cached !== undefined && cached.length > 0 ? cached : undefined;
    if (current !== undefined && current.length > 0) {
      const wroteIt = isAgentProxyKey(def.key) && backfilledAgentProxySettings.get(def.key) === current;
      if (!wroteIt) continue; // explicit env wins
      if (next === current) continue;
      if (next === undefined) {
        delete process.env[def.key];
        backfilledAgentProxySettings.delete(def.key);
        removed.push(def.key);
        continue;
      }
    }
    if (next !== undefined) {
      process.env[def.key] = next;
      if (isAgentProxyKey(def.key)) backfilledAgentProxySettings.set(def.key, next);
      filled.push(def.key);
    }
  }
  // Names only — never values.
  if (filled.length > 0) {
    console.error(`${LOG_PREFIX} backfilled from Infisical: ${describeKeys(filled)}`);
  }
  if (removed.length > 0) {
    console.error(`${LOG_PREFIX} removed from process.env (deleted in Infisical): ${describeKeys(removed)}`);
  }
  applyAgentProxyToProcessEnv();
}

function seedFromProcessEnv(): Map<string, string> {
  const seed = new Map<string, string>();
  for (const def of CLUTCH_SETTINGS_SCHEMA) {
    const value = process.env[def.key];
    if (value !== undefined) seed.set(def.key, value);
  }
  return seed;
}

function refreshIntervalMs(): number {
  const raw = process.env.CLUTCH_SETTINGS_REFRESH_MS?.trim() ?? "";
  const parsed = Number.parseInt(raw, 10);
  if (raw.length > 0 && Number.isFinite(parsed) && parsed >= 0) return parsed;
  const def = SCHEMA_BY_KEY.get("CLUTCH_SETTINGS_REFRESH_MS")?.defaultValue ?? "300000";
  return Number.parseInt(def, 10);
}

/**
 * Infisical is read from prod only (owner, 2026-10-10: the dev and staging
 * environments are retired).  A `CLUTCH_INFISICAL_ENV` set to anything else is
 * ignored with a loud error and prod is used.  It does not throw, so a stale
 * variable cannot stop the always-on web server from restarting.
 */
function resolveInfisicalEnvironment(): string {
  const requested = (process.env[CLUTCH_INFISICAL_ENV_VAR] ?? "").trim();
  if (requested && requested !== CLUTCH_INFISICAL_DEFAULT_ENV) {
    console.error(
      `${LOG_PREFIX} ${CLUTCH_INFISICAL_ENV_VAR}="${requested}" ignored — Infisical is read from ` +
        `"${CLUTCH_INFISICAL_DEFAULT_ENV}" only (dev and staging are retired).`,
    );
  }
  return CLUTCH_INFISICAL_DEFAULT_ENV;
}

/**
 * Initialize Clutch settings at startup.  Call once (top-level await) before
 * reading any managed setting.  Safe to call in short-lived CLIs: the
 * refresh timer is unref'd and only starts after a successful Infisical
 * load.
 */
export async function initClutchSettings(): Promise<ClutchSettings> {
  const clientId = process.env.INFISICAL_CLIENT_ID;
  const clientSecret = process.env.INFISICAL_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    console.error(
      `${LOG_PREFIX} INFISICAL_CLIENT_ID/INFISICAL_CLIENT_SECRET not set — seeding settings from process.env. ` +
        `Set the credentials to make Infisical the source of truth (see INFISICAL.md).`,
    );
    applyAgentProxyToProcessEnv();
    return new ClutchSettingsImpl(undefined, seedFromProcessEnv());
  }
  const environment = resolveInfisicalEnvironment();
  const client = createInfisicalSettings({
    projectId: CLUTCH_INFISICAL_PROJECT_ID,
    environment,
    refreshIntervalMs: refreshIntervalMs(),
    clientId,
    clientSecret,
  });
  try {
    await client.init();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(
      `${LOG_PREFIX} Infisical load failed (${message}) — seeding settings from process.env instead. ` +
        `Fix Infisical access and restart for Infisical-sourced settings.`,
    );
    client.stop();
    applyAgentProxyToProcessEnv();
    return new ClutchSettingsImpl(undefined, seedFromProcessEnv());
  }
  backfillProcessEnv(client);
  return new ClutchSettingsImpl(client, new Map());
}

/**
 * Wire SIGHUP to settings refresh for long-running processes.  The web
 * server calls this after initClutchSettings().
 */
export function reloadSettingsOnSighup(settings: ClutchSettings): void {
  process.on("SIGHUP", () => {
    void settings.refresh().catch((error: unknown) => {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`${LOG_PREFIX} SIGHUP refresh failed: ${message} — keeping last-known-good cache`);
    });
  });
}

/** Test helper: is this key a secret (must never be logged)? */
export function isSecretSetting(key: string): boolean {
  return isSecretKey(key);
}
