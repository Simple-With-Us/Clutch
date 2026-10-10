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
];

const SCHEMA_BY_KEY = new Map(CLUTCH_SETTINGS_SCHEMA.map((d) => [d.key, d]));

export type ClutchSettingsSource = "infisical" | "env-seed";

const LOG_PREFIX = "[clutch-settings]";

function isSecretKey(key: string): boolean {
  return SCHEMA_BY_KEY.get(key)?.kind === "secret";
}

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
 * Copy Infisical-sourced values into process.env for managed keys that are
 * not already set.  Explicitly-set env vars always win (local override).
 * This is the delivery mechanism: downstream readers — ACP driver env
 * params, Python bridges, spawned child processes — see Infisical values
 * with zero code churn, and nothing fetches per-request.
 */
function backfillProcessEnv(client: InfisicalSettings): void {
  const filled: string[] = [];
  for (const def of CLUTCH_SETTINGS_SCHEMA) {
    const current = process.env[def.key];
    if (current !== undefined && current.length > 0) continue; // explicit env wins
    const cached = client.get(def.key);
    if (cached !== undefined && cached.length > 0) {
      process.env[def.key] = cached;
      filled.push(def.key);
    }
  }
  if (filled.length > 0) {
    // Names only — never values.
    console.error(`${LOG_PREFIX} backfilled from Infisical: ${describeKeys(filled)}`);
  }
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
