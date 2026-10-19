/**
 * The dsh host wire contract.
 *
 * Clutch's web UI is the upstream `dsh web` binary — `scripts/start-web.sh`
 * execs `clutch.sh web` — so a dsh host already runs inside Clutch's
 * always-on stack on `$CLUTCH_WEB_PORT`.  That host is a cordis application
 * (176 KB of plugin framework, 2,696 LOC, no Node builtins), and it serves
 * the client contract over a WebSocket mux plus an HTTP API.
 *
 * A native client — the iOS app or the macOS app — is therefore a second
 * client of a host that already runs.  It is not a separate process, not a
 * WebView, and it does not embed a JavaScript engine.  This module is the
 * single source of truth for that contract inside Clutch: the TypeScript side
 * asserts it in `tests/dsh-host-contract.test.ts`, and the Swift client in
 * `ios/App/Services/DshHostClient.swift` implements the same envelopes.
 *
 * Two transports, and the difference matters:
 *
 *   * A unary call is a `POST` to `/api/<endpoint>`.  The body is the
 *     client-request envelope and the answer is the server-response envelope.
 *   * The WebSocket mux at `/api/remote.mux` carries streams — the cordis
 *     event stream in particular.  It is not the unary path.
 *
 * Upstream source (MIT; read-only reference clone at
 * `~/apps/upstream/deepseek-harness`, pinned to `dsh-v0.1.5-rc.3`):
 *
 *   packages/api/gateway/src/stream-protocol.ts  — the mux path and the
 *                                                  logical stream endpoints
 *   packages/client/connection/src/rpc-schema.ts  — the request and response
 *                                                    envelopes
 *   packages/client/connection/src/api-path.ts    — the `/api` prefix
 *   packages/client/connection/src/api-request-trust.ts
 *                                                — the Host fence
 *
 * The installed package is the authority: `tests/dsh-host-pinned.test.ts`
 * asserts every constant in this module against the `@deepseek-ai/dsh` build
 * Clutch actually ships, so a dsh bump that moves the contract fails here
 * rather than on a phone.
 */

/** Route prefix owning every API request (`/api` and `/api/<anything>`). */
export const DSH_HOST_API_PATH = "/api";

/**
 * Exact WebSocket route carrying every Remote stream.  The client opens one
 * socket and multiplexes its logical streams over it.
 */
export const DSH_HOST_MUX_PATH = "/api/remote.mux";

/** Gateway-internal logical stream carrying application-selected cordis events. */
export const DSH_HOST_EVENT_STREAM_ENDPOINT = "$events";

/** Gateway-internal unary endpoint returning one client Remote Event outcome. */
export const DSH_HOST_EVENT_RESULT_ENDPOINT = "$events/result";

/**
 * The characters an endpoint name may contain.
 *
 * The host validates a call target before it dispatches: the channel is
 * `/`-prefixed and the endpoint is one or more segments, each matching this
 * pattern, with no empty, `.` or `..` segment.  The endpoint is also the
 * envelope's `method`, and the request goes to `/api/<endpoint>`.
 */
export const DSH_HOST_ENDPOINT_SEGMENT_PATTERN = /^[A-Za-z0-9_$.-]+$/;

/**
 * Whether an endpoint name is one the host will accept.
 *
 * Upstream namespaces endpoints by domain — `remote.session`,
 * `remote.commands`, `remote.terminal`, `remote.workspace`,
 * `remote.subagents`, `remote.job`, `remote.remotes` — and the separator is a
 * dot, which this pattern allows.
 */
export function isValidDshHostEndpoint(endpoint: string): boolean {
  if (endpoint.length === 0) return false;
  const segments = endpoint.split("/");
  return segments.every(
    (segment) =>
      segment.length > 0 &&
      segment !== "." &&
      segment !== ".." &&
      DSH_HOST_ENDPOINT_SEGMENT_PATTERN.test(segment),
  );
}

/** The generic endpoint failure carried in a response envelope. */
export interface DshHostRpcError {
  code: string;
  message: string;
  details: Record<string, unknown>;
}

/** A response envelope's result: a value, or a typed failure. */
export type DshHostRpcResult =
  | { ok: true; value: unknown }
  | { ok: false; error: DshHostRpcError };

/** Client request envelope; endpoint payload validation belongs to its owner. */
export interface DshHostClientRequest {
  type: "client-request";
  rpcId: string;
  method: string;
  payload: unknown;
}

/** Server response envelope. */
export interface DshHostServerResponse {
  type: "server-response";
  rpcId: string;
  result: DshHostRpcResult;
}

/**
 * Build one client request envelope.
 *
 * `method` is the endpoint name — upstream namespaces them by domain, for
 * example `remote.session`, `remote.commands`, `remote.terminal`,
 * `remote.workspace`, `remote.subagents`, `remote.job` and
 * `credentials.describe`.  `payload` is the endpoint's own argument object;
 * the gateway carries it as `{ args: … }`.
 */
export function buildDshHostRequest(
  rpcId: string,
  method: string,
  payload: unknown = { args: {} },
): DshHostClientRequest {
  return { type: "client-request", rpcId, method, payload };
}

/**
 * Parse one server response envelope, rejecting anything that is not one.
 *
 * A malformed envelope is a protocol error, not an empty result: silently
 * treating it as success is how a client ends up believing a call worked
 * when the host never answered it.
 */
export function parseDshHostServerResponse(value: unknown): DshHostServerResponse {
  if (typeof value !== "object" || value === null) {
    throw new DshHostContractError("response is not an object");
  }
  const record = value as Record<string, unknown>;
  if (record.type !== "server-response") {
    throw new DshHostContractError(`unexpected envelope type ${JSON.stringify(record.type)}`);
  }
  if (typeof record.rpcId !== "string") {
    throw new DshHostContractError("response has no rpcId");
  }
  const result = record.result;
  if (typeof result !== "object" || result === null) {
    throw new DshHostContractError("response has no result");
  }
  const resultRecord = result as Record<string, unknown>;
  if (resultRecord.ok === true) {
    return {
      type: "server-response",
      rpcId: record.rpcId,
      result: { ok: true, value: resultRecord.value },
    };
  }
  if (resultRecord.ok === false) {
    const error = resultRecord.error;
    if (typeof error !== "object" || error === null) {
      throw new DshHostContractError("failed response has no error");
    }
    const errorRecord = error as Record<string, unknown>;
    return {
      type: "server-response",
      rpcId: record.rpcId,
      result: {
        ok: false,
        error: {
          code: typeof errorRecord.code === "string" ? errorRecord.code : "unknown",
          message: typeof errorRecord.message === "string" ? errorRecord.message : "",
          details:
            typeof errorRecord.details === "object" && errorRecord.details !== null
              ? (errorRecord.details as Record<string, unknown>)
              : {},
        },
      },
    };
  }
  throw new DshHostContractError("response result is neither ok nor failed");
}

/** A response envelope that does not match the dsh host contract. */
export class DshHostContractError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DshHostContractError";
  }
}

/**
 * The WebSocket URL of the host's mux, derived from a base origin.
 *
 * `http` becomes `ws` and `https` becomes `wss`; the path is the mux route.
 */
export function dshHostMuxURL(baseOrigin: string): string {
  const url = new URL(DSH_HOST_MUX_PATH, baseOrigin.endsWith("/") ? baseOrigin : `${baseOrigin}/`);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  return url.href;
}

/** The HTTP URL of the host's API, derived from a base origin. */
export function dshHostApiURL(baseOrigin: string): string {
  const url = new URL(DSH_HOST_API_PATH, baseOrigin.endsWith("/") ? baseOrigin : `${baseOrigin}/`);
  return url.href;
}

/**
 * The URL a unary call posts to: `/api/<endpoint>`.
 *
 * A unary call is a `POST` whose body is the client-request envelope, and the
 * host answers with the server-response envelope.  The WebSocket mux is for
 * streams — the event stream in particular — not for unary calls.
 */
export function dshHostEndpointURL(baseOrigin: string, endpoint: string): string {
  if (!isValidDshHostEndpoint(endpoint)) {
    throw new DshHostContractError(`invalid RPC endpoint ${JSON.stringify(endpoint)}`);
  }
  const base = dshHostApiURL(baseOrigin);
  return `${base}${endpoint}`;
}

/**
 * The `Host` header a native client must send, and the authority the host
 * will accept.
 *
 * The host's fence binds every request to a trusted authority: loopback, the
 * listener's bind IP literal, or a declared `trustedHosts` entry.  A native
 * client sends no `Origin` and no fetch metadata, so the `Host` header is
 * the only thing that proves which deployment it is talking to — and the
 * host needs it to be one the operator trusted.
 */
export function dshHostAuthority(origin: string): string {
  const url = new URL(origin);
  return url.port ? `${url.hostname}:${url.port}` : url.hostname;
}
