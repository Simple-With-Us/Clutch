/**
 * DeepSeek model discovery — `GET https://api.deepseek.com/models`.
 *
 * DeepSeek's model list is the authority on which models the account can
 * actually call, and it changes without a Clutch release: new point
 * versions land, and the owner's own models differ from the public
 * catalogue.  `STATIC_DSH_MODELS` in `./acp/driver.ts` is therefore a
 * starting list, not the truth, and this module is how the truth is fetched.
 *
 * Two facts shape the design, both verified against the pinned
 * `@deepseek-ai/dsh@0.1.5-rc.2`:
 *
 *   1. The upstream web UI already ships a "Fetch available models" button,
 *      but it is rendered only for `llm-pi-ai` providers (`ModelListEditor`).
 *      The DeepSeek card renders `DeepSeekModelsEditor`, which is handed no
 *      fetch affordance at all.
 *   2. Even for `llm-pi-ai`, the host answers a named provider from the
 *      installed pi-ai catalogue with no network call, and `dsh-llm-deepseek`
 *      registers no discovery whatsoever.
 *
 * So the live call has to be made here.  This module is the transport and
 * the normalisation; it has no UI opinions and no dependency on the dsh
 * runtime, which keeps it unit-testable and reusable from the ACP driver,
 * a cordis plugin, or the macOS shell.
 *
 * The API key is never placed in an error message, a return value, or a log
 * line.  Callers resolve it from the dsh credential seam and pass it in.
 */
import type { ModelCatalog, ProviderErrorCode } from "../shared/contracts.ts";
import { classifyDshError } from "./acp/driver.ts";

/** DeepSeek's model-listing endpoint.  Owned by Jay, not configurable per
 *  call site — an override exists only for tests and for gateways that
 *  re-expose the same listing. */
export const DEEPSEEK_MODELS_URL = "https://api.deepseek.com/models";

/** Mirrors the upstream `dsh-web-fetch-http` ceiling: refuse on the declared
 *  length first, then on the accumulated total, because a server that
 *  under-declares or streams still gets bounded.  2 MiB is far above any
 *  plausible model list and far below a response worth rendering. */
export const DEEPSEEK_MODELS_MAX_BYTES = 2 * 1024 * 1024;

/** A model as DeepSeek advertises it, normalized onto the Clutch catalog
 *  shape.  `contextWindow` is omitted rather than guessed: DeepSeek does not
 *  return it, and a wrong window is worse than none because callers size
 *  truncation against it. */
export interface DeepSeekModel {
  readonly id: string;
  readonly label: string;
  readonly ownedBy?: string;
}

/** A discovery failure carrying the canonical provider-error code so the
 *  fallback chain can treat it like any other engine failure instead of a
 *  generic error.  `cause` keeps the original for logs; the message never
 *  carries the credential. */
export class DeepSeekModelsError extends Error {
  readonly code: ProviderErrorCode | "discovery_failed";
  override readonly cause?: unknown;

  constructor(message: string, code: ProviderErrorCode | "discovery_failed", cause?: unknown) {
    super(message);
    this.name = "DeepSeekModelsError";
    this.code = code;
    this.cause = cause;
  }
}

export interface FetchDeepSeekModelsOptions {
  /** Bearer credential for the DeepSeek API.  Required — an unauthenticated
   *  listing answers 401, and pretending otherwise would report a healthy
   *  provider as broken. */
  readonly apiKey: string;
  /** Overridable for tests; defaults to the global `fetch`. */
  readonly fetchImpl?: typeof fetch;
  readonly signal?: AbortSignal;
  /** Overridable for tests and for gateways re-exposing the listing. */
  readonly url?: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Read a reply body, refusing one that outgrows the ceiling.
 *
 * A declared length is checked first so an honest server is turned away
 * without transferring anything; the accumulated total is what actually
 * enforces the bound, because a server that under-declares its length
 * (or streams) tells us nothing up front.
 */
async function readBounded(response: Response, limit: number): Promise<string> {
  const declared = Number(response.headers.get("content-length") ?? "");
  if (Number.isFinite(declared) && declared > limit) {
    throw new DeepSeekModelsError(
      `model list is larger than the ${limit} byte ceiling`,
      "discovery_failed",
    );
  }
  if (response.body === null) {
    // No stream to meter: read fully, then enforce the same ceiling on
    // the byte length of what arrived.
    const text = await response.text();
    if (new TextEncoder().encode(text).byteLength > limit) {
      throw new DeepSeekModelsError(
        `model list is larger than the ${limit} byte ceiling`,
        "discovery_failed",
      );
    }
    return text;
  }

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value === undefined) continue;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      throw new DeepSeekModelsError(
        `model list is larger than the ${limit} byte ceiling`,
        "discovery_failed",
      );
    }
    chunks.push(value);
  }
  return new TextDecoder().decode(concat(chunks));
}

function concat(chunks: readonly Uint8Array[]): Uint8Array {
  const out = new Uint8Array(chunks.reduce((sum, c) => sum + c.byteLength, 0));
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

/**
 * Normalize a DeepSeek listing onto the Clutch model shape.
 *
 * DeepSeek answers in the OpenAI list shape: `{ object: "list", data: [{ id,
 * object, owned_by }] }`.  `data` is the contract; anything else is a shape
 * this module does not understand, and guessing at it would put junk ids
 * into the picker.  Duplicate ids are dropped, first occurrence wins, so a
 * listing that repeats an id cannot produce a duplicate row.
 */
export function normalizeDeepSeekModels(body: unknown): readonly DeepSeekModel[] {
  if (!isRecord(body) || !Array.isArray(body.data)) return [];

  const seen = new Set<string>();
  const models: DeepSeekModel[] = [];
  for (const entry of body.data) {
    if (!isRecord(entry)) continue;
    const id = typeof entry.id === "string" ? entry.id.trim() : "";
    if (id.length === 0 || seen.has(id)) continue;
    seen.add(id);
    const ownedBy = typeof entry.owned_by === "string" && entry.owned_by.length > 0
      ? entry.owned_by
      : undefined;
    models.push({ id, label: id, ...(ownedBy === undefined ? {} : { ownedBy }) });
  }
  return models;
}

/**
 * List the models the DeepSeek account can call.
 *
 * The endpoint needs a bearer credential, so a missing key is refused here
 * rather than being sent as an empty header and reported back as an opaque
 * 401.  A 401/403 maps to `invalid_credentials`; anything else is classified
 * by the shared DSH classifier so quota, region, and upstream failures land
 * on their canonical codes.
 */
export async function fetchDeepSeekModels(
  options: FetchDeepSeekModelsOptions,
): Promise<readonly DeepSeekModel[]> {
  const { apiKey, signal, url = DEEPSEEK_MODELS_URL } = options;
  if (apiKey.trim().length === 0) {
    throw new DeepSeekModelsError(
      "a DeepSeek API key is required to list models",
      "invalid_credentials",
    );
  }
  const doFetch = options.fetchImpl ?? fetch;

  let response: Response;
  try {
    const request = new Request(url, {
      method: "GET",
      headers: { authorization: `Bearer ${apiKey}`, accept: "application/json" },
      ...(signal === undefined ? {} : { signal }),
    });
    response = await doFetch(request);
  } catch (cause) {
    if (signal?.aborted === true) {
      throw new DeepSeekModelsError("model discovery aborted by caller", "discovery_failed", cause);
    }
    throw new DeepSeekModelsError(`could not reach ${url}`, "discovery_failed", cause);
  }

  if (!response.ok) {
    const code: ProviderErrorCode = response.status === 401 || response.status === 403
      ? "invalid_credentials"
      : classifyDshError(`HTTP ${response.status}`) ?? "quota_or_region_restriction";
    throw new DeepSeekModelsError(
      `${url} answered ${response.status}${response.status === 401 || response.status === 403 ? "; check the API key" : ""}`,
      code,
    );
  }

  const text = await readBounded(response, DEEPSEEK_MODELS_MAX_BYTES);

  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch (cause) {
    throw new DeepSeekModelsError(`${url} did not answer with JSON`, "discovery_failed", cause);
  }
  return normalizeDeepSeekModels(body);
}

/**
 * Fold a discovered listing into a model catalog, preserving the caller's
 * curated metadata.
 *
 * A discovered model keeps whatever the catalog already said about it —
 * the badge, the tooltip, the context window.  Only genuinely new ids are
 * appended, so fetching the list never silently downgrades a hand-tuned
 * entry or disturbs the default.  `default` is left exactly as it was: a
 * listing cannot know which model the operator wants to start on.
 */
export function mergeDiscoveredModels(
  catalog: ModelCatalog,
  discovered: readonly DeepSeekModel[],
): ModelCatalog {
  const known = new Set(catalog.options.map((option) => option.id));
  const additions = discovered
    .filter((model) => !known.has(model.id))
    .map((model) => ({ id: model.id, label: model.label }));

  if (additions.length === 0) return catalog;
  return { default: catalog.default, options: [...catalog.options, ...additions] };
}
