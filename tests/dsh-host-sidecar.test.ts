import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { createServer, type Server } from "node:http";
import { AddressInfo } from "node:net";

import {
  DshHostClient,
  DshHostHandshakeError,
  DshHostRemoteError,
  DshHostTransportError,
  launchUrlPath,
  readLaunchUrl,
} from "../src/web/dshHostClient";

/**
 * dsh-host-sidecar — the sidecar's own client for the dsh host.
 *
 * The native apps never speak the host's contract; this module does, and it
 * is the one place an upstream bump has to be absorbed.  The tests drive it
 * against a stub host that behaves like the real one: the launch URL answers
 * with a redirect that carries the signed cookie, and every later call has to
 * carry that cookie back.
 */

interface StubCall {
  readonly method: string;
  readonly url: string;
  readonly headers: Record<string, string | string[] | undefined>;
  readonly body: string;
}

let server: Server;
let origin: string;
let calls: StubCall[];
let launchRedirects = true;
let launchLoop = false;

beforeEach(async () => {
  calls = [];
  launchRedirects = true;
  launchLoop = false;
  server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8");
      calls.push({ method: req.method ?? "", url: req.url ?? "", headers: req.headers, body });

      if (req.url?.startsWith("/launch-away")) {
        res.writeHead(302, { location: "http://elsewhere.invalid/api/session/list" });
        res.end();
        return;
      }

      if (req.url === "/launched") {
        res.writeHead(200, { "content-type": "text/html" }).end("ok");
        return;
      }

      if (req.url?.startsWith("/launch")) {
        // The real host may answer the launch URL with a redirect, and the
        // signed cookie rides on that hop rather than on the final page.
        if (launchLoop) {
          // A host that never stops redirecting has to be given up on, and
          // the error must not quote the launch URL it kept being sent.
          res.writeHead(302, { location: "/launch" });
          res.end();
          return;
        }
        if (launchRedirects) {
          res.writeHead(302, {
            location: "/launched",
            "set-cookie": "dsh_session=signed-value; Path=/; HttpOnly; SameSite=Strict",
          });
          res.end();
          return;
        }
        res.writeHead(200, {
          "set-cookie": "dsh_session=signed-value; Path=/; HttpOnly; SameSite=Strict",
        });
        res.end("ok");
        return;
      }

      if (req.url === "/api/session/list") {
        res.writeHead(200, { "content-type": "application/json" }).end(
          JSON.stringify({
            type: "server-response",
            rpcId: "any",
            result: { ok: true, value: { items: [{ sessionId: "session-1" }] } },
          }),
        );
        return;
      }

      if (req.url === "/api/session/boom") {
        res.writeHead(200, { "content-type": "application/json" }).end(
          JSON.stringify({
            type: "server-response",
            rpcId: "any",
            result: {
              ok: false,
              error: { code: "gateway/method-unavailable", message: "no such method", details: {} },
            },
          }),
        );
        return;
      }

      if (req.url === "/api/session/garbage") {
        res.writeHead(200, { "content-type": "application/json" }).end("not json");
        return;
      }

      res.writeHead(404).end("not found");
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as AddressInfo;
  origin = `http://127.0.0.1:${address.port}`;
});

afterEach(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("readLaunchUrl", () => {
  it("reads the launch URL from the owner-only file", async () => {
    const url = await readLaunchUrl({
      readFileImpl: async () => "http://127.0.0.1:3180/launch?token=abc\n",
    });
    expect(url).toBe("http://127.0.0.1:3180/launch?token=abc");
  });

  it("returns null when the file is absent", async () => {
    const url = await readLaunchUrl({
      readFileImpl: async () => {
        throw new Error("ENOENT");
      },
    });
    expect(url).toBeNull();
  });

  it("prefers an explicit launch URL over the file", async () => {
    const url = await readLaunchUrl({
      launchUrl: "http://example.test/launch?token=explicit",
      readFileImpl: async () => "http://example.test/launch?token=from-file",
    });
    expect(url).toBe("http://example.test/launch?token=explicit");
  });

  it("prefers the environment over the file", async () => {
    const url = await readLaunchUrl({
      env: { DSH_HOST_LAUNCH_URL: "http://example.test/launch?token=from-env" },
      readFileImpl: async () => "http://example.test/launch?token=from-file",
    });
    expect(url).toBe("http://example.test/launch?token=from-env");
  });

  it("resolves the launch URL file under CLUTCH_HOME", () => {
    expect(launchUrlPath({ CLUTCH_HOME: "/tmp/clutch-home" })).toBe(
      "/tmp/clutch-home/web-launch-url",
    );
    expect(launchUrlPath({ CLUTCH_HOME: "/tmp/clutch-home", CLUTCH_LAUNCH_URL_FILE: "/tmp/x" })).toBe(
      "/tmp/x",
    );
  });
});

describe("DshHostClient", () => {
  it("exchanges the launch token and keeps the cookie from a redirect hop", async () => {
    const client = await DshHostClient.connect({
      launchUrl: `${origin}/launch?token=secret`,
    });

    expect(client.authenticated).toBe(true);
    expect(client.origin).toBe(origin);
    const launch = calls.find((call) => call.url.startsWith("/launch"));
    expect(launch?.method).toBe("GET");
  });

  it("keeps the cookie when the host sets it on the final answer", async () => {
    launchRedirects = false;
    const client = await DshHostClient.connect({
      launchUrl: `${origin}/launch?token=secret`,
    });
    expect(client.authenticated).toBe(true);
  });

  it("carries the cookie on every later call", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    await client.call("session/list");

    const api = calls.find((call) => call.url === "/api/session/list");
    expect(api?.headers["cookie"]).toBe("dsh_session=signed-value");
  });

  it("calls one endpoint and returns its value", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    const value = await client.call<{ items: Array<{ sessionId: string }> }>("session/list");

    expect(value.items[0]?.sessionId).toBe("session-1");
    const api = calls.find((call) => call.url === "/api/session/list");
    const envelope = JSON.parse(api?.body ?? "{}");
    expect(envelope.type).toBe("client-request");
    expect(envelope.method).toBe("session/list");
    expect(envelope.payload).toEqual({ args: {} });
  });

  it("passes the endpoint arguments as the payload args", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    await client.call("session/list", { limit: 10 });

    const api = calls.find((call) => call.url === "/api/session/list");
    const envelope = JSON.parse(api?.body ?? "{}");
    expect(envelope.payload).toEqual({ args: { limit: 10 } });
  });

  it("reports a failure the host raised as a remote error", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    await expect(client.call("session/boom")).rejects.toBeInstanceOf(DshHostRemoteError);
  });

  it("keeps the host's error code on a remote error", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    const error = await client.call("session/boom").catch((err: unknown) => err);
    expect(error).toBeInstanceOf(DshHostRemoteError);
    expect((error as DshHostRemoteError).code).toBe("gateway/method-unavailable");
  });

  it("reports a non-JSON answer as a transport error", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    await expect(client.call("session/garbage")).rejects.toBeInstanceOf(DshHostTransportError);
  });

  it("reports a missing endpoint as a transport error", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    await expect(client.call("session/nope")).rejects.toBeInstanceOf(DshHostTransportError);
  });

  it("refuses an endpoint the contract does not allow", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    await expect(client.call("../secret")).rejects.toBeInstanceOf(DshHostTransportError);
    await expect(client.call("session/../secret")).rejects.toBeInstanceOf(DshHostTransportError);
  });

  it("refuses to guess an origin when there is no launch URL", async () => {
    await expect(
      DshHostClient.connect({
        launchUrl: null,
        readFileImpl: async () => {
          throw new Error("ENOENT");
        },
      }),
    ).rejects.toBeInstanceOf(DshHostTransportError);
  });

  it("refuses a redirect that leaves the host's origin", async () => {
    // The host answers with a redirect to another authority; the cookie is
    // bound to this one, so the hop is refused rather than followed.
    await expect(
      DshHostClient.connect({ launchUrl: `${origin}/launch-away?token=secret` }),
    ).rejects.toBeInstanceOf(DshHostTransportError);
  });

  it("keeps the token out of the error it reports", async () => {
    const error = await DshHostClient.connect({
      launchUrl: `${origin}/launch-away?token=super-secret`,
    }).catch((err: unknown) => err as Error);
    expect(error.message).not.toContain("super-secret");
  });

  it("keeps the token out of the error it reports when the host never stops redirecting", async () => {
    launchLoop = true;
    const error = await DshHostClient.connect({
      launchUrl: `${origin}/launch?token=super-secret`,
    }).catch((err: unknown) => err as Error);
    expect(error).toBeInstanceOf(DshHostTransportError);
    expect(error.message).not.toContain("super-secret");
    expect(error.message).not.toContain("token=");
  });

  it("keeps the token out of the error it reports for a launch URL it cannot parse", async () => {
    const error = await DshHostClient.connect({
      launchUrl: "not a url?token=super-secret",
    }).catch((err: unknown) => err as Error);
    expect(error).toBeInstanceOf(DshHostTransportError);
    expect(error.message).not.toContain("super-secret");
  });

  it("derives the origin from the launch URL when none is given", async () => {
    const client = await DshHostClient.connect({
      launchUrl: `${origin}/launch?token=secret`,
    });
    expect(client.origin).toBe(origin);
  });
});

describe("DshHostClient mux", () => {
  /** One fake host socket, so the mux can be driven without a server. */
  class FakeSocket {
    readonly sent: string[] = [];
    closed = false;
    onopen: ((event: unknown) => void) | null = null;
    onmessage: ((event: { data: unknown }) => void) | null = null;
    onerror: ((event: unknown) => void) | null = null;
    onclose: ((event: unknown) => void) | null = null;

    constructor(
      readonly url: string,
      readonly init?: { headers?: Record<string, string> },
    ) {}

    send(data: string): void {
      this.sent.push(data);
    }

    close(): void {
      this.closed = true;
    }

    /** Deliver one frame to the client. */
    deliver(frame: unknown): void {
      this.onmessage?.({ data: JSON.stringify(frame) });
    }
  }

  let sockets: FakeSocket[] = [];
  let priorWebSocket: unknown;

  beforeEach(() => {
    sockets = [];
    priorWebSocket = (globalThis as { WebSocket?: unknown }).WebSocket;
    (globalThis as { WebSocket?: unknown }).WebSocket = class extends FakeSocket {
      constructor(url: string, init?: { headers?: Record<string, string> }) {
        super(url, init);
        sockets.push(this);
        setTimeout(() => this.onopen?.({}), 0);
      }
    };
  });

  afterEach(() => {
    // Restore what was there before, so another test in this process is not
    // left with a fake socket.
    if (priorWebSocket === undefined) {
      delete (globalThis as { WebSocket?: unknown }).WebSocket;
    } else {
      (globalThis as { WebSocket?: unknown }).WebSocket = priorWebSocket;
    }
  });

  it("propagates an error after the mux handshake instead of returning empty history", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    const reading = client.stream("session/follow").next().catch((error: unknown) => error);
    await new Promise((resolve) => setTimeout(resolve, 20));
    sockets[0]?.onerror?.({});
    const error = await reading;
    expect(error).toBeInstanceOf(DshHostTransportError);
    expect(error).not.toBeInstanceOf(DshHostHandshakeError);
  });

  it("opens the stream the host was asked for", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    const stream = client.stream("session/follow", { address: { kind: "session", sessionId: "session-1" } });
    const collected: unknown[] = [];
    const reader = (async () => {
      for await (const item of stream) {
        collected.push(item);
        if (collected.length === 1) break;
      }
    })();

    await new Promise((resolve) => setTimeout(resolve, 20));
    const socket = sockets[0];
    expect(socket?.url).toBe(`ws://127.0.0.1:${new URL(origin).port}/api/remote.mux`);
    const opened = JSON.parse(socket?.sent[0] ?? "{}");
    expect(opened.type).toBe("open");
    expect(opened.endpoint).toBe("session/follow");
    expect(opened.payload).toEqual({
      args: { address: { kind: "session", sessionId: "session-1" } },
    });
    expect(opened.streamId).toBeTruthy();

    socket?.deliver({ type: "item", streamId: opened.streamId, value: { type: "snapshot" } });
    await reader;
    expect(collected).toEqual([{ type: "snapshot" }]);
  });

  it("carries the host's cookie into the mux handshake", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    const stream = client.stream("session/follow", {});
    const reader = (async () => {
      for await (const _ of stream) break;
    })();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(sockets[0]?.init?.headers?.["cookie"]).toBe("dsh_session=signed-value");
    sockets[0]?.deliver({ type: "end", streamId: JSON.parse(sockets[0]?.sent[0] ?? "{}").streamId });
    await reader;
  });

  it("cancels the stream when the caller stops reading", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    const stream = client.stream("session/follow", {});
    const reader = (async () => {
      for await (const _ of stream) break;
    })();
    await new Promise((resolve) => setTimeout(resolve, 20));
    const streamId = JSON.parse(sockets[0]?.sent[0] ?? "{}").streamId;
    sockets[0]?.deliver({ type: "item", streamId, value: 1 });
    await reader;
    const cancelled = sockets[0]?.sent.map((raw) => JSON.parse(raw)).find((f) => f.type === "cancel");
    expect(cancelled?.streamId).toBe(streamId);
    expect(sockets[0]?.closed).toBe(true);
  });

  it("raises the host's failure as a remote error", async () => {
    const client = await DshHostClient.connect({ launchUrl: `${origin}/launch?token=secret` });
    const stream = client.stream("session/follow", {});
    const reader = (async () => {
      for await (const _ of stream) {
        // never reached
      }
    })();
    await new Promise((resolve) => setTimeout(resolve, 20));
    const streamId = JSON.parse(sockets[0]?.sent[0] ?? "{}").streamId;
    sockets[0]?.deliver({
      type: "error",
      streamId,
      error: { code: "gateway/bad-request", message: "nope", details: {} },
    });
    await expect(reader).rejects.toBeInstanceOf(DshHostRemoteError);
  });
});
