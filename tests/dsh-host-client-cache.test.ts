import { describe, expect, it, vi } from "vitest";
import { DshHostClientCache } from "../src/web/dshHostClientCache.ts";
import { DshHostHandshakeError, DshHostTransportError } from "../src/web/dshHostClient.ts";

describe("host client identity cache", () => {
  for (const status of [401, 404]) {
    it(`exchanges identity on the next read after ${status}, without replaying the failed read`, async () => {
      const stale = { generation: 1 };
      const fresh = { generation: 2 };
      const connect = vi.fn().mockResolvedValueOnce(stale).mockResolvedValueOnce(fresh);
      const cache = new DshHostClientCache(connect);
      expect(await cache.run(async (client) => client.generation)).toBe(1);
      const refused = new DshHostTransportError("fixture refusal", status);
      const read = vi.fn(async () => { throw refused; });
      await expect(cache.run(read)).rejects.toBe(refused);
      expect(read).toHaveBeenCalledTimes(1);
      expect(connect).toHaveBeenCalledTimes(1);
      expect(await cache.run(async (client) => client.generation)).toBe(2);
      expect(connect).toHaveBeenCalledTimes(2);
    });
  }

  it("keeps a valid cached identity after unrelated transport errors", async () => {
    const client = {};
    const connect = vi.fn().mockResolvedValue(client);
    const cache = new DshHostClientCache(connect);
    await expect(cache.run(async () => { throw new DshHostTransportError("fixture", 500); })).rejects.toThrow();
    expect(await cache.run(async (value) => value)).toBe(client);
    expect(connect).toHaveBeenCalledTimes(1);
  });

  it("keeps the late-start cooldown, then retries connect", async () => {
    let now = 0;
    const connect = vi.fn().mockRejectedValueOnce(new Error("fixture offline")).mockResolvedValueOnce({});
    const cache = new DshHostClientCache(connect, () => now);
    await expect(cache.run(async () => true)).rejects.toThrow("fixture offline");
    now = 29_999;
    await expect(cache.run(async () => true)).rejects.toThrow("not reachable");
    expect(connect).toHaveBeenCalledTimes(1);
    now = 30_000;
    expect(await cache.run(async () => true)).toBe(true);
    expect(connect).toHaveBeenCalledTimes(2);
  });
});

describe("route integration", () => {
  it("wraps both host-owned reads in the invalidating cache", async () => {
    const { readFile } = await import("node:fs/promises");
    const source = await readFile(new URL("../src/web/chat-bridge.ts", import.meta.url), "utf8");
    expect(source).toContain("hostClient.run((client) => listDshHostSessions(client");
    expect(source).toContain("hostClient.run((client) => loadDshHostHistory(client");
    expect(source).not.toContain("await dshHost()");
  });
});

describe("recovery limits", () => {
  it("shares an in-flight identity exchange", async () => {
    let release!: (value: object) => void;
    const connect = vi.fn(() => new Promise<object>((resolve) => { release = resolve; }));
    const cache = new DshHostClientCache(connect);
    const first = cache.run(async (client) => client);
    const second = cache.run(async (client) => client);
    const client = {};
    release(client);
    expect(await first).toBe(client);
    expect(await second).toBe(client);
    expect(connect).toHaveBeenCalledTimes(1);
  });

  it("permits one immediate identity refresh, then cools down repeated refusals", async () => {
    let now = 0;
    const connect = vi.fn().mockResolvedValue({});
    const cache = new DshHostClientCache(connect, () => now);
    const refuse = async () => { throw new DshHostTransportError("fixture", 401); };
    await expect(cache.run(refuse)).rejects.toThrow("fixture");
    await expect(cache.run(refuse)).rejects.toThrow("fixture");
    await expect(cache.run(async () => true)).rejects.toThrow("not reachable");
    expect(connect).toHaveBeenCalledTimes(2);
    now = 30_000;
    expect(await cache.run(async () => true)).toBe(true);
    expect(connect).toHaveBeenCalledTimes(3);
  });
});


describe("mux failure boundary", () => {
  it("invalidates a failed upgrade but not a snapshot timeout", async () => {
    const connect = vi.fn().mockResolvedValue({});
    const cache = new DshHostClientCache(connect);
    await expect(cache.run(async () => { throw new DshHostHandshakeError("fixture handshake"); })).rejects.toThrow();
    await cache.run(async () => true);
    expect(connect).toHaveBeenCalledTimes(2);
    await expect(cache.run(async () => { throw new DshHostTransportError("snapshot timeout"); })).rejects.toThrow();
    await cache.run(async () => true);
    expect(connect).toHaveBeenCalledTimes(2);
  });
});

describe("held clients report their refusals", () => {
  it("noteFailure drops the client still in use after a 401, and ignores other errors and replaced clients", async () => {
    const first = { generation: 1 };
    const second = { generation: 2 };
    const connect = vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second);
    const cache = new DshHostClientCache(connect);
    const held = await cache.run(async (client) => client);
    cache.noteFailure(held, new Error("network blip"));
    expect(await cache.run(async (client) => client.generation)).toBe(1);
    cache.noteFailure(held, new DshHostTransportError("refused", 401));
    expect(await cache.run(async (client) => client.generation)).toBe(2);
    // The first client is no longer the cached one, so its late failure changes nothing.
    cache.noteFailure(held, new DshHostTransportError("late refusal", 401));
    expect(await cache.run(async (client) => client.generation)).toBe(2);
    expect(connect).toHaveBeenCalledTimes(2);
  });

  it("an approval relay whose stream is refused gets a fresh identity on its next attempt", async () => {
    const { DshHostApprovalRelay } = await import("../src/web/dshHostApprovals.ts");
    const refused = new DshHostTransportError("identity refused", 401);
    const stale = {
      generation: 1,
      // eslint-disable-next-line require-yield
      async *stream(): AsyncGenerator<unknown> { throw refused; },
      async call() { return undefined; },
    };
    const fresh = {
      generation: 2,
      async *stream(): AsyncGenerator<unknown> {
        yield { type: "ready", clientId: "client-2", host: { home: "/home" } };
        await new Promise(() => undefined);
      },
      async call() { return undefined; },
    };
    const connect = vi.fn().mockResolvedValueOnce(stale).mockResolvedValueOnce(fresh);
    const cache = new DshHostClientCache(connect);
    const relay = DshHostApprovalRelay.start({
      client: () => cache.run(async (client) => client as never),
      onClientError: (client, error) => cache.noteFailure(client as never, error),
      onApproval: () => undefined,
    });
    try {
      expect(await relay.ready(6_000)).toBe(true);
      expect(connect).toHaveBeenCalledTimes(2);
    } finally {
      relay.stop();
    }
  }, 10_000);
});

describe("held-client routes report to the cache", () => {
  it("passes the host turn and the relay through noteFailure", async () => {
    const { readFile } = await import("node:fs/promises");
    const source = await readFile(new URL("../src/web/chat-bridge.ts", import.meta.url), "utf8");
    expect(source).toContain("onClientError: (client, error) => hostClient.noteFailure(client, error)");
    expect(source).toContain("hostClient.noteFailure(heldHost, err)");
    expect(source).toContain("viaHost(() => runDshHostTurn(host");
  });
});
