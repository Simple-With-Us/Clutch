import { describe, expect, it, vi } from "vitest";

import {
  CometChatRelay,
  cometchatApiBase,
  cometchatConfigFromEnv,
  createStreamSink,
  type CometChatConfig,
} from "../src/web/cometchat-relay.ts";

const config: CometChatConfig = {
  appId: "12345",
  region: "us",
  restApiKey: "rest-key",
  agentUid: "clutch-agent",
};

function mockFetch(calls: { method: string; path: string; body: unknown }[], nextId = 7) {
  let id = nextId;
  return vi.fn(async (url: string, init: { method?: string; headers?: Record<string, string>; body?: string }) => {
    calls.push({ method: init.method ?? "GET", path: new URL(url).pathname, body: JSON.parse(init.body ?? "{}") });
    const headers = init.headers ?? {};
    expect(headers.apikey).toBe("rest-key");
    expect(headers.onBehalfOf).toBe("clutch-agent");
    const assigned = id++;
    return { ok: true, status: 200, json: async () => ({ id: assigned }) } as Response;
  });
}

describe("cometchatConfigFromEnv", () => {
  it("builds the base URL and requires all four keys", () => {
    expect(cometchatApiBase(config)).toBe("https://12345.api-us.cometchat.io/v3");
    expect(
      cometchatConfigFromEnv({ COMETCHAT_APP_ID: "1", COMETCHAT_REGION: "us", COMETCHAT_REST_API_KEY: "k", COMETCHAT_AGENT_UID: "a" }),
    ).toEqual({ appId: "1", region: "us", restApiKey: "k", agentUid: "a" });
    expect(cometchatConfigFromEnv({ COMETCHAT_APP_ID: "1", COMETCHAT_REGION: "us" })).toBeNull();
    expect(cometchatConfigFromEnv({})).toBeNull();
  });
});

describe("CometChatRelay", () => {
  it("sends text as the agent and edits by id", async () => {
    const calls: { method: string; path: string; body: unknown }[] = [];
    const relay = new CometChatRelay(config, { fetchFn: mockFetch(calls, 41) });
    const id = await relay.sendText({ receiver: "user-1", receiverType: "user" }, "hello");
    expect(id).toBe("41");
    expect(calls[0]).toMatchObject({
      method: "POST",
      path: "/v3/messages",
      body: { receiver: "user-1", receiverType: "user", category: "message", type: "text" },
    });
    await relay.editText(id, "hello world");
    expect(calls[1]).toMatchObject({ method: "PUT", path: "/v3/messages/41" });
  });

  it("sends tool cards as interactive payloads", async () => {
    const calls: { method: string; path: string; body: unknown }[] = [];
    const relay = new CometChatRelay(config, { fetchFn: mockFetch(calls, 9) });
    const id = await relay.sendToolCard(
      { receiver: "user-1", receiverType: "user" },
      { title: "Bash", summary: "ran tests", actions: [{ id: "rerun", label: "Re-run" }] },
    );
    expect(id).toBe("9");
    expect(calls[0]?.body).toMatchObject({ category: "interactive", type: "card" });
  });

  it("surfaces REST failures without leaking the key", async () => {
    const relay = new CometChatRelay(config, {
      fetchFn: (async () => ({ ok: false, status: 401, json: async () => ({}) })) as typeof fetch,
    });
    await expect(relay.sendText({ receiver: "u", receiverType: "user" }, "x")).rejects.toThrow(/401/);
  });
});

describe("createStreamSink", () => {
  it("creates on first chunk, throttles edits, flushes on done", async () => {
    const calls: { method: string; path: string; body: unknown }[] = [];
    const relay = new CometChatRelay(config, { fetchFn: mockFetch(calls, 3) });
    let t = 0;
    const sink = createStreamSink(relay, { receiver: "user-1", receiverType: "user" }, () => t);
    sink.onUpdate("agent_message_chunk", "hello");
    await new Promise((r) => setTimeout(r, 10));
    expect(calls.filter((c) => c.method === "POST").length).toBe(1);
    t += 100;
    sink.onUpdate("agent_message_chunk", " there");
    await new Promise((r) => setTimeout(r, 10));
    expect(calls.filter((c) => c.method === "PUT").length).toBe(0);
    t += 2000;
    sink.onUpdate("agent_thought_chunk", "!");
    await new Promise((r) => setTimeout(r, 10));
    expect(calls.filter((c) => c.method === "PUT").length).toBe(1);
    await sink.onDone();
    const puts = calls.filter((c) => c.method === "PUT");
    expect(puts.length).toBe(2);
    expect((puts[1]?.body as { data: { text: string } }).data.text).toBe("hello there!");
  });

  it("never sends twice when done races the first create", async () => {
    const calls: { method: string; path: string; body: unknown }[] = [];
    let release!: () => void;
    const gate = new Promise<void>((r) => {
      release = r;
    });
    const slowFetch = vi.fn(async (url: string, init: { method?: string; body?: string }) => {
      calls.push({ method: init.method ?? "GET", path: new URL(url).pathname, body: JSON.parse(init.body ?? "{}") });
      await gate;
      return { ok: true, status: 200, json: async () => ({ id: 5 }) } as Response;
    });
    const relay = new CometChatRelay(config, { fetchFn: slowFetch });
    const sink = createStreamSink(relay, { receiver: "user-1", receiverType: "user" });
    sink.onUpdate("agent_message_chunk", "hello");
    sink.onUpdate("agent_message_chunk", " there");
    const done = sink.onDone();
    release();
    await done;
    expect(calls.filter((c) => c.method === "POST").length).toBe(1);
    const puts = calls.filter((c) => c.method === "PUT");
    expect(puts.length).toBe(1);
    expect((puts[0]?.body as { data: { text: string } }).data.text).toBe("hello there");
  });
});
