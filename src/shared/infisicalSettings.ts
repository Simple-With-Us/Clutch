// =============================================================================
// infisicalSettings — zero-dependency Infisical settings client (fleet-shared)
// =============================================================================
//
// This module is the fleet-wide reference implementation of the Infisical
// sole-source-of-truth pattern (see INFISICAL.md at the repo root).  It is a
// generic client: TypeScript apps import it, point it at their own Infisical
// project, and get the canonical cache/refresh/write-through contract with
// zero new runtime dependencies (global `fetch` only).
//
// Contract summary:
//   - init()     loads every secret for the project+environment into an
//                in-memory Map at startup.  Startup fails fast on error.
//   - get()/getAll()/has()/getRequired()  read memory ONLY.  They never touch
//                the network, so they are safe in hot request/tick paths.
//   - refresh()  re-reads Infisical and swaps the cache on success.  On
//                failure it logs LOUDLY and keeps serving the last-known-good
//                cache — staleness is safer than an outage.
//   - set()      is write-through: it writes to Infisical FIRST, then updates
//                the cache.  If the Infisical write fails the save fails — the
//                cache and Infisical are never allowed to diverge silently.
//   - stop()     clears the background refresh timer.
//
// Auth: scoped Infisical service tokens.  The read token comes from the options,
// falling back to INFISICAL_TOKEN; writes use INFISICAL_WRITE_TOKEN when set.
// Secret VALUES are never printed, echoed, or logged —
// names and metadata only.
//
// Added as an explicit owner-directed exception (2026-10-03) to this repo's
// "do not add app runtime code here" rule: the library itself holds no
// secrets, but it is the home of the reusable pattern for the whole fleet.
// See the Infisical section in AGENTS.md.

import { isIP } from "node:net";

export interface InfisicalSettingsOptions {
  /** Infisical project ID (the workspaceId), e.g. "6a953a29-8397-4a9d-a5a5-7d1b61e4a5e7". */
  projectId: string;
  /** Infisical environment slug, e.g. "dev", "staging", or "prod". */
  environment: string;
  /**
   * Background cache refresh interval in milliseconds.  Defaults to 300000
   * (5 minutes).  Values <= 0 disable the background timer (manual
   * refresh() calls still work).
   */
  refreshIntervalMs?: number;
  /** Infisical instance base URL.  Defaults to "https://app.infisical.com". */
  infisicalUrl?: string;
  /** Scoped read token. Defaults to the INFISICAL_TOKEN env var. */
  readToken?: string;
  /** Optional, separate scoped write token. Defaults to INFISICAL_WRITE_TOKEN; never uses readToken. */
  writeToken?: string;
  /**
   * fetch implementation.  Defaults to globalThis.fetch.  Inject a mock in
   * tests; pass a custom fetch if you need proxies or retries.
   */
  fetchImpl?: typeof fetch;
  /**
   * Optional hook invoked after a failed background refresh has already been
   * logged loudly.  Useful for alerting; never receives secret values.
   */
  onRefreshError?: (error: Error) => void;
}

/** Thrown when a write-through `set()` cannot persist the value to Infisical. */
export class InfisicalWriteError extends Error {
  readonly key: string;
  constructor(key: string, message: string, options?: { cause?: unknown }) {
    super(`Infisical write-through failed for key "${key}": ${message}`);
    this.name = "InfisicalWriteError";
    this.key = key;
    if (options?.cause !== undefined) {
      (this as { cause?: unknown }).cause = options.cause;
    }
  }
}

/** Thrown when init()/refresh() cannot load settings from Infisical. */
export class InfisicalLoadError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(`Infisical settings load failed: ${message}`);
    this.name = "InfisicalLoadError";
    if (options?.cause !== undefined) {
      (this as { cause?: unknown }).cause = options.cause;
    }
  }
}

const DEFAULT_REFRESH_INTERVAL_MS = 300_000; // 5 minutes, per the canonical pattern.
const DEFAULT_INFISICAL_URL = "https://app.infisical.com";
const DEFAULT_SECRET_PATH = "/";
const LOG_PREFIX = "[infisical-settings]";

interface RawSecret {
  secretKey: string;
  secretValue: string;
}

interface RawSecretsResponse {
  secrets: RawSecret[];
}

const SERVICE_TOKEN_PREFIX = "st.";
const MIN_SERVICE_TOKEN_LENGTH = 20;
const MAX_SERVICE_TOKEN_LENGTH = 2048;

function validateInfisicalUrl(raw: string): string {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error("createInfisicalSettings: infisicalUrl must be a valid base URL");
  }
  if (url.username || url.password || url.search || url.hash || (url.pathname !== "" && url.pathname !== "/")) {
    throw new Error("createInfisicalSettings: infisicalUrl must be a base origin without credentials, path, query, or fragment");
  }
  if (url.protocol === "https:") return url.origin;
  const hostname = url.hostname.replace(/^\[|\]$/g, "");
  const loopback = (isIP(hostname) === 4 && hostname.startsWith("127.")) || hostname === "::1";
  if (url.protocol === "http:" && loopback) return url.origin;
  throw new Error("createInfisicalSettings: infisicalUrl must use HTTPS (HTTP is allowed only for literal loopback test servers)");
}

function isServiceToken(token: string): boolean {
  return token.startsWith(SERVICE_TOKEN_PREFIX) &&
    token.length >= MIN_SERVICE_TOKEN_LENGTH &&
    token.length <= MAX_SERVICE_TOKEN_LENGTH &&
    !/\s/.test(token);
}

/**
 * Read an environment variable without depending on Node globals, so the
 * module stays portable (Node, workers, edge runtimes).  In Node this reads
 * process.env; elsewhere it returns undefined.
 */
function readEnv(name: string): string | undefined {
  const proc = (globalThis as Record<string, unknown>)["process"] as
    | { env?: Record<string, string | undefined> }
    | undefined;
  return proc?.env?.[name];
}

function envOr(value: string | undefined, name: string): string | undefined {
  return value ?? readEnv(name);
}

export interface InfisicalSettings {
  /** Authenticate and load the full settings set into memory.  Call once at startup. */
  init(): Promise<void>;
  /** Read a value from the in-memory cache.  Never hits the network. */
  get(key: string): string | undefined;
  /** Read a value, throwing a clear error (naming the key, pointing at INFISICAL.md) if absent. */
  getRequired(key: string): string;
  /** True when the key is present in the in-memory cache.  Never hits the network. */
  has(key: string): boolean;
  /** Snapshot of the whole in-memory cache as a plain object.  Never hits the network. */
  getAll(): Record<string, string>;
  /**
   * Write-through save: persists to Infisical FIRST, then updates the cache.
   * Rejects with InfisicalWriteError (cache untouched) when the Infisical
   * write fails.
   */
  set(key: string, value: string): Promise<void>;
  /**
   * Re-read Infisical and swap the cache on success.  On failure logs loudly
   * and keeps the last-known-good cache.  Called automatically by the
   * background timer; call it on demand (SIGHUP, admin "Reload settings",
   * applicationDidBecomeActive) as needed.
   */
  refresh(): Promise<void>;
  /** Clear the background refresh timer.  Call on shutdown. */
  stop(): void;
}

class InfisicalSettingsClient implements InfisicalSettings {
  private readonly projectId: string;
  private readonly environment: string;
  private readonly refreshIntervalMs: number;
  private readonly infisicalUrl: string;
  private readonly readToken: string;
  private readonly writeToken: string | undefined;
  private readonly fetchImpl: typeof fetch;
  private readonly onRefreshError?: (error: Error) => void;

  private cache = new Map<string, string>();
  private timer: ReturnType<typeof setInterval> | undefined;
  private initialized = false;

  constructor(options: InfisicalSettingsOptions) {
    if (!options.projectId) {
      throw new Error("createInfisicalSettings: projectId is required");
    }
    if (!options.environment) {
      throw new Error("createInfisicalSettings: environment is required");
    }
    const readToken = envOr(options.readToken, "INFISICAL_TOKEN");
    const writeToken = envOr(options.writeToken, "INFISICAL_WRITE_TOKEN");
    if (!readToken || !isServiceToken(readToken)) {
      throw new Error(
        "createInfisicalSettings: a valid scoped service token is required — pass readToken or set INFISICAL_TOKEN",
      );
    }
    if (writeToken && !isServiceToken(writeToken)) {
      throw new Error("createInfisicalSettings: INFISICAL_WRITE_TOKEN must be a valid scoped service token");
    }
    this.projectId = options.projectId;
    this.environment = options.environment;
    this.refreshIntervalMs =
      options.refreshIntervalMs === undefined
        ? DEFAULT_REFRESH_INTERVAL_MS
        : options.refreshIntervalMs;
    this.infisicalUrl = validateInfisicalUrl(options.infisicalUrl ?? DEFAULT_INFISICAL_URL);
    this.readToken = readToken;
    this.writeToken = writeToken;
    this.fetchImpl = options.fetchImpl ?? globalThis.fetch.bind(globalThis);
    // Guarded assignment: this repo compiles with exactOptionalPropertyTypes.
    if (options.onRefreshError !== undefined) this.onRefreshError = options.onRefreshError;
  }

  async init(): Promise<void> {
    await this.loadIntoCache();
    this.initialized = true;
    if (this.refreshIntervalMs > 0) {
      this.timer = setInterval(() => {
        void this.backgroundRefresh();
      }, this.refreshIntervalMs);
      // Don't keep the process alive just for settings refresh.
      const maybeUnref = this.timer as { unref?: () => void };
      if (typeof maybeUnref.unref === "function") {
        maybeUnref.unref();
      }
    }
  }

  get(key: string): string | undefined {
    this.assertInitialized();
    return this.cache.get(key);
  }

  getRequired(key: string): string {
    const value = this.get(key);
    if (value === undefined) {
      throw new Error(
        `Missing required Infisical setting "${key}" (project ${this.projectId}, environment "${this.environment}"). ` +
          `Add it to the Infisical project and restart — see INFISICAL.md.`,
      );
    }
    return value;
  }

  has(key: string): boolean {
    this.assertInitialized();
    return this.cache.has(key);
  }

  getAll(): Record<string, string> {
    this.assertInitialized();
    return Object.fromEntries(this.cache);
  }

  async set(key: string, value: string): Promise<void> {
    this.assertInitialized();
    // Write-through: Infisical FIRST, cache only after the write succeeds.
    await this.persistSecret(key, value);
    this.cache.set(key, value);
  }

  async refresh(): Promise<void> {
    this.assertInitialized();
    await this.loadIntoCache();
  }

  stop(): void {
    if (this.timer !== undefined) {
      clearInterval(this.timer);
      this.timer = undefined;
    }
  }

  // -- internals ------------------------------------------------------------

  private assertInitialized(): void {
    if (!this.initialized) {
      throw new Error("InfisicalSettings: call init() before reading or writing settings");
    }
  }

  private async backgroundRefresh(): Promise<void> {
    try {
      await this.refresh();
    } catch (error) {
      const err = error instanceof Error ? error : new Error(String(error));
      // LOUD log, then keep serving the last-known-good cache.
      console.error(
        `${LOG_PREFIX} Refresh failed for project ${this.projectId} environment "${this.environment}": ${err.message}. ` +
          `Serving last-known-good cache (${this.cache.size} keys); staleness is safer than an outage.`,
      );
      this.onRefreshError?.(err);
    }
  }

  private authHeaders(token: string): Record<string, string> {
    return { Authorization: `Bearer ${token}` };
  }

  /** GET the full raw secret set and swap it into the cache.  Throws on failure. */
  private async loadIntoCache(): Promise<void> {
    const params = new URLSearchParams({
      workspaceId: this.projectId,
      environment: this.environment,
      secretPath: DEFAULT_SECRET_PATH,
    });
    const url = `${this.infisicalUrl}/api/v3/secrets/raw?${params.toString()}`;
    const response = await this.getWithServiceToken(url);
    if (!response.ok) {
      throw new InfisicalLoadError(
        `GET ${this.describeSecretsEndpoint()} returned HTTP ${response.status}`,
      );
    }
    const data = (await response.json()) as RawSecretsResponse;
    const next = new Map<string, string>();
    for (const secret of data.secrets ?? []) {
      if (secret.secretKey !== undefined) {
        next.set(secret.secretKey, secret.secretValue ?? "");
      }
    }
    this.cache = next;
  }

  /** GET with the scoped read token; rejected tokens are never replaced by a login. */
  private async getWithServiceToken(url: string): Promise<Response> {
    let response: Response;
    try {
      response = await this.fetchImpl(url, { headers: this.authHeaders(this.readToken), redirect: "error" });
    } catch (error) {
      throw new InfisicalLoadError(`GET ${this.describeSecretsEndpoint()} request failed`, {
        cause: error,
      });
    }
    return response;
  }

  private describeSecretsEndpoint(): string {
    return `/api/v3/secrets/raw (project ${this.projectId}, environment "${this.environment}")`;
  }

  /**
   * Persist one secret to Infisical.  PATCHes the existing secret; creates it
   * with POST when it does not exist yet (404).  Never touches the cache —
   * the caller updates the cache only after this resolves.
   */
  private async persistSecret(key: string, value: string): Promise<void> {
    const writeToken = this.writeToken;
    if (!writeToken) {
      throw new InfisicalWriteError(key, "a separate scoped INFISICAL_WRITE_TOKEN is required for writes");
    }
    const encodedKey = encodeURIComponent(key);
    const url = `${this.infisicalUrl}/api/v3/secrets/raw/${encodedKey}`;
    const write = async (method: "PATCH" | "POST"): Promise<Response> => {
      return this.fetchImpl(url, {
        method,
        headers: { ...this.authHeaders(writeToken), "Content-Type": "application/json" },
        body: JSON.stringify({
          workspaceId: this.projectId,
          environment: this.environment,
          secretPath: DEFAULT_SECRET_PATH,
          secretValue: value,
          type: "shared",
        }),
        redirect: "error",
      });
    };

    let response: Response;
    try {
      response = await write("PATCH");
    } catch (error) {
      throw new InfisicalWriteError(key, "PATCH request failed", { cause: error });
    }
    if (response.status === 404) {
      // Secret does not exist yet — create it.
      try {
        response = await write("POST");
      } catch (error) {
        throw new InfisicalWriteError(key, "POST (create) request failed", { cause: error });
      }
    }
    if (!response.ok) {
      throw new InfisicalWriteError(key, `Infisical returned HTTP ${response.status}`);
    }
  }
}

/**
 * Create a zero-dependency Infisical settings client for one project and
 * environment.  Call `init()` once at startup, read with `get()`/`getAll()`,
 * save admin changes with `set()`, and call `stop()` on shutdown.
 */
export function createInfisicalSettings(options: InfisicalSettingsOptions): InfisicalSettings {
  return new InfisicalSettingsClient(options);
}
