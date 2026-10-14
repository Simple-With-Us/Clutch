import { describe, expect, it, vi } from "vitest";

import {
  CometChatRelay,
  cleanEnvValue,
  cometchatApiBase,
  cometchatConfigFromEnv,
  createStreamSink,
  isThreadUid,
  normalizeThreadMessages,
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

  it("accepts double-quoted handoff values", () => {
    expect(cleanEnvValue('"abc123"')).toBe("abc123");
    expect(cleanEnvValue('  "us"  ')).toBe("us");
    expect(cleanEnvValue("plain")).toBe("plain");
    expect(cleanEnvValue(undefined)).toBe("");
    expect(
      cometchatConfigFromEnv({
        COMETCHAT_APP_ID: '"1"',
        COMETCHAT_REGION: '"us"',
        COMETCHAT_REST_API_KEY: '"k"',
        COMETCHAT_AGENT_UID: '"a"',
      }),
    ).toEqual({ appId: "1", region: "us", restApiKey: "k", agentUid: "a" });
    expect(
      cometchatConfigFromEnv({
        COMETCHAT_APP_ID: '"1"',
        COMETCHAT_REGION: '"us"',
        COMETCHAT_REST_API_KEY: '"k"',
      }),
    ).toEqual({ appId: "1", region: "us", restApiKey: "k", agentUid: "clutch-agent" });
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

  it("accepts the live create shape with the id under data", async () => {
    const relay = new CometChatRelay(config, {
      fetchFn: (async () => ({ ok: true, status: 200, json: async () => ({ data: { id: "abc" } }) })) as typeof fetch,
    });
    await expect(relay.sendText({ receiver: "u", receiverType: "user" }, "x")).resolves.toBe("abc");
  });

  it("sends tool cards as interactive payloads", async () => {    const calls: { method: string; path: string; body: unknown }[] = [];
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

describe("normalizeThreadMessages", () => {
  const textMsg = {
    id: "11",
    sender: { uid: "clutch-agent" },
    category: "message",
    type: "text",
    data: { text: "hello" },
    sentAt: 1_700_000_000,
  };
  const cardMsg = {
    id: 12,
    sender: "clutch-agent",
    category: "interactive",
    type: "card",
    data: { interactiveData: { text: "ran tests", title: "Bash" } },
    sentOn: 1_700_000_100_000,
  };

  it("keeps text and card bubbles from the {data} list shape", () => {
    expect(normalizeThreadMessages({ data: [textMsg, cardMsg] })).toEqual([
      { id: "11", senderUid: "clutch-agent", text: "hello", sentAt: 1_700_000_000_000, kind: "text" },
      { id: "12", senderUid: "clutch-agent", text: "ran tests", sentAt: 1_700_000_100_000, kind: "card" },
    ]);
  });

  it("accepts a bare array and skips unreadable entries", () => {
    expect(normalizeThreadMessages([textMsg, null, 42, { id: "x" }, {}])).toEqual([
      { id: "11", senderUid: "clutch-agent", text: "hello", sentAt: 1_700_000_000_000, kind: "text" },
    ]);
  });

  it("returns empty on shape drift instead of throwing", () => {
    expect(normalizeThreadMessages({})).toEqual([]);
    expect(normalizeThreadMessages(null)).toEqual([]);
    expect(normalizeThreadMessages("nope")).toEqual([]);
  });
});

describe("CometChatRelay.fetchThread", () => {
  function threadFetch(calls: { method: string; path: string; query: string }[]) {
    return vi.fn(async (url: string, init: { method?: string; headers?: Record<string, string> }) => {
      const parsed = new URL(url);
      calls.push({ method: init.method ?? "GET", path: parsed.pathname, query: parsed.search });
      expect(init.headers?.apikey).toBe("rest-key");
      expect(init.headers?.onBehalfOf).toBe("clutch-agent");
      expect(init).not.toHaveProperty("body");
      return {
        ok: true,
        status: 200,
        json: async () => ({
          data: [
            { id: "1", sender: "clutch-agent", category: "message", type: "text", data: { text: "hi" }, sentAt: 100 },
          ],
        }),
      } as Response;
    });
  }

  it("reads one device thread with the relay headers and no body", async () => {
    const calls: { method: string; path: string; query: string }[] = [];
    const relay = new CometChatRelay(config, { fetchFn: threadFetch(calls) });
    const messages = await relay.fetchThread("clutch-mac-abcdef12", 25);
    expect(calls[0]).toMatchObject({ method: "GET", path: "/v3/users/clutch-mac-abcdef12/messages" });
    expect(calls[0]?.query).toContain("limit=25");
    expect(messages).toEqual([{ id: "1", senderUid: "clutch-agent", text: "hi", sentAt: 100_000, kind: "text" }]);
  });

  it("caps the limit and rejects bad uids before any request", async () => {
    const calls: { method: string; path: string; query: string }[] = [];
    const relay = new CometChatRelay(config, { fetchFn: threadFetch(calls) });
    await relay.fetchThread("clutch-mac-abcdef12", 9999);
    expect(calls[0]?.query).toContain("limit=100");
    await expect(relay.fetchThread("../../etc/passwd", 10)).rejects.toThrow(/bad uid/);
    await expect(relay.fetchThread("", 10)).rejects.toThrow(/bad uid/);
    expect(calls.length).toBe(1);
  });

  it("surfaces REST failures without leaking the key", async () => {
    const relay = new CometChatRelay(config, {
      fetchFn: (async () => ({ ok: false, status: 403, json: async () => ({}) })) as typeof fetch,
    });
    await expect(relay.fetchThread("clutch-mac-abcdef12")).rejects.toThrow(/403/);
  });

  it("only accepts app-scoped slug uids", () => {
    expect(isThreadUid("clutch-mac-abcdef12")).toBe(true);
    expect(isThreadUid("clutch-ios-12345678")).toBe(true);
    expect(isThreadUid("")).toBe(false);
    expect(isThreadUid("../x")).toBe(false);
    expect(isThreadUid("a".repeat(65))).toBe(false);
    expect(isThreadUid(42)).toBe(false);
  });
});
