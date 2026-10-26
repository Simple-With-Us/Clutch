import { describe, expect, it, vi } from "vitest";
import { DshHostClientCache } from "../src/web/dshHostClientCache.ts";
import { DshHostTransportError } from "../src/web/dshHostClient.ts";

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
