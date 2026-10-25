/**
 * A server-side client for the dsh host Clutch already runs.
 *
 * The native iOS and macOS apps talk to this sidecar, never to the host
 * directly.  One protocol then covers every engine — the dsh-hosted agents
 * (DeepSeek, MiniMax) and the code engines (MiniMax Code, Muse Code) — and
 * the host's version-pinned contract stays behind this module, where an
 * upstream bump is absorbed in one place instead of in two Swift clients.
 *
 * The wire contract itself lives in `src/shared/dshHostContract.ts`, which is
 * asserted against the installed dsh build by `tests/dsh-host-pinned.test.ts`.
 *
 * Authentication is the host's launch-token handshake: the host mints a
 * per-process token and prints a URL, and visiting that URL once exchanges it
 * for a signed cookie that every later request carries.  The cookie is bound
 * to the authority the host minted it for, so this client derives its origin
 * from the launch URL rather than assuming loopback.
 */

import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

import {
  buildDshHostRequest,
  dshHostEndpointURL,
  dshHostMuxURL,
  isValidDshHostEndpoint,
  parseDshHostServerResponse,
} from "../shared/dshHostContract.ts";

/** A failure the host itself reported, as opposed to a transport failure. */
export class DshHostRemoteError extends Error {
  readonly code: string;
  readonly details: unknown;

  constructor(code: string, message: string, details: unknown = null) {
    super(message);
    this.name = "DshHostRemoteError";
    this.code = code;
    this.details = details;
  }
}

/** The client could not reach the host, or the host answered outside the contract. */
export class DshHostTransportError extends Error {
  readonly status: number | null;

  constructor(message: string, status: number | null = null) {
    super(message);
    this.name = "DshHostTransportError";
    this.status = status;
  }
}

/** How the client reaches the host; injected in tests. */
export interface DshHostClientOptions {
  /** The host's origin. Derived from the launch URL when one is available. */
  readonly origin?: string | undefined;
  /** The launch URL that exchanges the per-process token for the cookie. */
  readonly launchUrl?: string | null | undefined;
  /** Injected in tests. */
  readonly readFileImpl?: ((path: string) => Promise<string>) | undefined;
}

/** One HTTP answer: the status, the headers, and the body as text. */
interface HttpAnswer {
  readonly status: number;
  readonly headers: Record<string, string | string[] | undefined>;
  readonly body: string;
}

/** Where the host's launch URL is written, and the default location of it. */
export function launchUrlPath(env: NodeJS.ProcessEnv = process.env): string {
  const home = env.CLUTCH_HOME ?? join(env.HOME ?? homedir(), ".clutch");
  return env.CLUTCH_LAUNCH_URL_FILE ?? join(home, "web-launch-url");
}

/**
 * Read the host's launch URL, or null when there is none.
 *
 * The file holds a token, so it is owner-only and is read but never logged.
 */
export async function readLaunchUrl(options: DshHostClientOptions = {}): Promise<string | null> {
  if (options.launchUrl !== undefined) {
    const explicit = options.launchUrl?.trim();
    return explicit && explicit.length > 0 ? explicit : null;
  }
  const read = options.readFileImpl ?? ((path: string) => readFile(path, "utf8"));
  try {
    const raw = await read(launchUrlPath());
    const trimmed = raw.trim();
    return trimmed.length > 0 ? trimmed : null;
  } catch {
    return null;
  }
}

/**
 * Perform one HTTP request, following redirects by hand.
 *
 * The hand-rolled redirect loop is the point: the host may answer the launch
 * URL with a redirect that carries the signed cookie, and a fetch that follows
 * redirects internally would drop that header.  Every hop's `set-cookie` is
 * collected, so the cookie is found wherever the host put it.
 */
async function httpWithRedirects(
  url: string,
  init: { readonly method: string; readonly headers?: Record<string, string>; readonly body?: string },
  maxHops = 5,
): Promise<{ readonly answer: HttpAnswer; readonly cookies: string[] }> {
  const cookies: string[] = [];
  let current = url;

  for (let hop = 0; hop <= maxHops; hop += 1) {
    const answer = await httpOnce(current, init);
    for (const raw of headerValues(answer.headers, "set-cookie")) {
      const pair = raw.split(";", 1)[0]?.trim();
      if (pair && pair.length > 0) cookies.push(pair);
    }
    const location = firstHeader(answer.headers, "location");
    const isRedirect = answer.status >= 300 && answer.status < 400 && location;
    if (!isRedirect) return { answer, cookies };
    current = new URL(location, current).toString();
  }
  throw new DshHostTransportError(`too many redirects from ${url}`);
}

/** One HTTP round trip, with no redirect handling. */
function httpOnce(
  url: string,
  init: { readonly method: string; readonly headers?: Record<string, string>; readonly body?: string },
): Promise<HttpAnswer> {
  return new Promise<HttpAnswer>((resolve, reject) => {
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      reject(new DshHostTransportError(`invalid host URL ${JSON.stringify(url)}`));
      return;
    }
    const send = parsed.protocol === "https:" ? httpsRequest : httpRequest;
    const req = send(
      parsed,
      {
        method: init.method,
        headers: init.headers ?? {},
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.on("end", () => {
          resolve({
            status: res.statusCode ?? 0,
            headers: res.headers,
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      },
    );
    req.on("error", (err: Error) => reject(new DshHostTransportError(err.message)));
    if (init.body !== undefined) req.write(init.body);
    req.end();
  });
}

/** Every value of one header, whatever the casing. */
function headerValues(headers: Record<string, string | string[] | undefined>, name: string): string[] {
  const wanted = name.toLowerCase();
  const out: string[] = [];
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() !== wanted) continue;
    if (Array.isArray(value)) out.push(...value);
    else if (typeof value === "string") out.push(value);
  }
  return out;
}

/** The first value of one header, or null. */
function firstHeader(headers: Record<string, string | string[] | undefined>, name: string): string | null {
  const values = headerValues(headers, name);
  return values[0] ?? null;
}

/**
 * A client for one dsh host.
 *
 * The client is stateless apart from the cookie it obtained at connect time,
 * so one instance can serve every request the sidecar makes.
 */
export class DshHostClient {
  private cookie: string | null = null;

  private constructor(
    private readonly originValue: string,
    private readonly launchUrlValue: string | null,
  ) {}

  /**
   * Connect to the host and obtain its cookie.
   *
   * The launch URL is redeemed when there is one.  Without it the host
   * answers 401, and the caller gets a transport error saying so rather than
   * a confusing refusal on the first real call.
   */
  static async connect(options: DshHostClientOptions = {}): Promise<DshHostClient> {
    const launchUrl = await readLaunchUrl(options);
    let origin = options.origin?.trim() ?? "";
    if (origin.length === 0 && launchUrl) {
      try {
        origin = new URL(launchUrl).origin;
      } catch {
        throw new DshHostTransportError(`invalid launch URL ${JSON.stringify(launchUrl)}`);
      }
    }
    if (origin.length === 0) {
      throw new DshHostTransportError(
        "no dsh host to talk to: no launch URL was found and no origin was given",
      );
    }
    const client = new DshHostClient(origin.replace(/\/+$/, ""), launchUrl);
    if (launchUrl) await client.exchangeLaunchToken(launchUrl);
    return client;
  }

  /** The host this client talks to. */
  get origin(): string {
    return this.originValue;
  }

  /** The launch URL the cookie came from, or null when there was none. */
  get launchUrl(): string | null {
    return this.launchUrlValue;
  }

  /** Whether the client holds the host's cookie. */
  get authenticated(): boolean {
    return this.cookie !== null;
  }

  /**
   * Redeem the launch token for the host's signed cookie.
   *
   * The token lives in the URL, so the URL is never logged and never leaves
   * this machine in a message.
   */
  private async exchangeLaunchToken(launchUrl: string): Promise<void> {
    const { answer, cookies } = await httpWithRedirects(launchUrl, { method: "GET" });
    if (answer.status < 200 || answer.status >= 400) {
      throw new DshHostTransportError(
        `launch exchange failed with status ${answer.status}`,
        answer.status,
      );
    }
    if (cookies.length > 0) {
      this.cookie = cookies.join("; ");
    }
  }

  /**
   * Call one endpoint on the host and return its value.
   *
   * A failure the host reported comes back as `DshHostRemoteError`, so the
   * caller can tell "the host refused" from "the host could not be reached".
   */
  async call<T = unknown>(endpoint: string, args: Record<string, unknown> = {}): Promise<T> {
    if (!isValidDshHostEndpoint(endpoint)) {
      throw new DshHostTransportError(`invalid dsh host endpoint ${JSON.stringify(endpoint)}`);
    }
    const url = dshHostEndpointURL(this.originValue, endpoint);
    const body = JSON.stringify(buildDshHostRequest(rpcId(), endpoint, { args }));
    const headers: Record<string, string> = {
      "content-type": "application/json",
      accept: "application/json",
    };
    if (this.cookie) headers["cookie"] = this.cookie;

    const { answer, cookies } = await httpWithRedirects(url, { method: "POST", headers, body });
    // A host that refreshes its cookie mid-flight hands us a new one.
    if (cookies.length > 0) this.cookie = cookies.join("; ");
    if (answer.status < 200 || answer.status >= 300) {
      throw new DshHostTransportError(
        `dsh host answered ${answer.status} for ${endpoint}`,
        answer.status,
      );
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(answer.body);
    } catch {
      throw new DshHostTransportError(`dsh host answered ${endpoint} with a non-JSON body`);
    }
    const envelope = parseDshHostServerResponse(parsed);
    if (!envelope.result.ok) {
      throw new DshHostRemoteError(
        envelope.result.error.code,
        envelope.result.error.message,
        envelope.result.error.details,
      );
    }
    return envelope.result.value as T;
  }

  /**
   * Open one logical stream on the host and yield its items.
   *
   * The mux is the only way to read a stream: the host serves nothing until a
   * client sends the `open` frame for the endpoint it wants, so a client that
   * only listens on the socket receives frames for a stream it never asked for.
   * The `cancel` frame is sent when the caller stops reading, which is what
   * tells the host the stream is no longer wanted.
   */
  async *stream(
    endpoint: string,
    args: Record<string, unknown> = {},
  ): AsyncGenerator<unknown, void, undefined> {
    if (!isValidDshHostEndpoint(endpoint)) {
      throw new DshHostTransportError(`invalid dsh host endpoint ${JSON.stringify(endpoint)}`);
    }
    const Ctor = webSocketConstructor();
    if (!Ctor) {
      throw new DshHostTransportError(
        "this runtime has no global WebSocket, so the dsh host mux is unavailable",
      );
    }

    streamCounter += 1;
    const streamId = `clutch-sidecar-stream-${streamCounter}`;
    const headers: Record<string, string> = {};
    if (this.cookie) headers["cookie"] = this.cookie;

    const socket = new Ctor(dshHostMuxURL(this.originValue), { headers });
    const pending: unknown[] = [];
    let finished = false;
    let failure: Error | null = null;
    let wake: (() => void) | null = null;

    const settle = (error?: Error): void => {
      if (error) failure = error;
      finished = true;
      wake?.();
    };
    const push = (value: unknown): void => {
      pending.push(value);
      wake?.();
    };

    socket.onmessage = (event) => {
      const frame = parseMuxFrame(event.data);
      if (!frame || frame.streamId !== streamId) return;
      if (frame.type === "item") {
        push(frame.value);
        return;
      }
      if (frame.type === "error") {
        settle(
          new DshHostRemoteError(
            frame.error?.code ?? "unknown",
            frame.error?.message ?? "",
            frame.error?.details ?? null,
          ),
        );
        return;
      }
      if (frame.type === "end") settle();
    };
    socket.onerror = () => settle(new DshHostTransportError("the dsh host mux connection failed"));
    socket.onclose = () => settle();

    await new Promise<void>((resolve, reject) => {
      socket.onopen = () => resolve();
      socket.onerror = () => reject(new DshHostTransportError("the dsh host mux connection failed"));
    });

    socket.send(
      JSON.stringify({ type: "open", streamId, endpoint, payload: { args } }),
    );

    try {
      for (;;) {
        while (pending.length > 0) yield pending.shift();
        if (failure) throw failure;
        if (finished) return;
        await new Promise<void>((resolve) => {
          wake = resolve;
        });
      }
    } finally {
      try {
        socket.send(JSON.stringify({ type: "cancel", streamId }));
      } catch {
        /* the socket is already gone */
      }
      socket.close();
    }
  }
}

let rpcCounter = 0;

/** A unique id for one request envelope. */
function rpcId(): string {
  rpcCounter += 1;
  return `clutch-sidecar-${rpcCounter}`;
}

let streamCounter = 0;

/**
 * The slice of the WebSocket API this client uses.
 *
 * Node 24 ships a global `WebSocket`, but `@types/node` 24 does not declare
 * it globally and `undici-types` is not a dependency of this package, so the
 * shape is declared here: the constructor, `send`, `close`, and the four
 * event handlers.
 */
interface WebSocketLike {
  send(data: string): void;
  close(code?: number, reason?: string): void;
  onopen: ((event: unknown) => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onerror: ((event: unknown) => void) | null;
  onclose: ((event: unknown) => void) | null;
}

type WebSocketConstructor = new (
  url: string,
  init?: { readonly headers?: Record<string, string> },
) => WebSocketLike;

/** The runtime's WebSocket constructor, or null when there is none. */
function webSocketConstructor(): WebSocketConstructor | null {
  const ctor = (globalThis as { WebSocket?: unknown }).WebSocket;
  return typeof ctor === "function" ? (ctor as WebSocketConstructor) : null;
}

/** One frame the host sent over the mux. */
interface MuxFrame {
  readonly type: string;
  readonly streamId?: string;
  readonly value?: unknown;
  readonly error?: { code?: string; message?: string; details?: unknown };
}

/** Parse one mux frame, or null when the payload is not a frame. */
function parseMuxFrame(data: unknown): MuxFrame | null {
  if (typeof data !== "string") return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(data);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const frame = parsed as Record<string, unknown>;
  if (typeof frame["type"] !== "string") return null;
  return {
    type: frame["type"],
    ...(typeof frame["streamId"] === "string" ? { streamId: frame["streamId"] } : {}),
    ...("value" in frame ? { value: frame["value"] } : {}),
    ...(typeof frame["error"] === "object" && frame["error"] !== null
      ? {
          error: frame["error"] as {
            code?: string;
            message?: string;
            details?: unknown;
          },
        }
      : {}),
  };
}

