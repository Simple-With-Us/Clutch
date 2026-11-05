import { describe, it, expect } from "vitest";

import {
  createDshHostSession,
  runDshHostTurn,
  selectHostModel,
} from "../src/web/dshHostTurn.ts";
import { listDshHostSessions, loadDshHostHistory } from "../src/web/dshHostSessions.ts";
import type { DshHostClient } from "../src/web/dshHostClient.ts";

/**
 * dsh-host-wire-args — the argument envelope the sidecar sends to the dsh
 * host.
 *
 * The host's Typert descriptors put each endpoint's business object under one
 * wire key, and the gateway refuses any argument set that does not match the
 * descriptor exactly: a flat argument set is refused before the turn starts.
 * The key is not the same for every endpoint, so each one is checked here.
 *
 * The host is a fake that records what it was sent, so the envelope is proved
 * without a live host and without the dsh build being installed.
 */

/** One recorded call or stream, with the arguments it carried. */
interface Recorded {
  readonly endpoint: string;
  readonly args: Record<string, unknown>;
}

/** A host that records every call and stream the sidecar opens. */
class WireHost {
  readonly calls: Recorded[] = [];
  readonly streams: Recorded[] = [];

  /** How many model selections the host refused, so the fallback runs. */
  private refusedSelections = 0;

  async call(endpoint: string, args: Record<string, unknown>): Promise<unknown> {
    this.calls.push({ endpoint, args });
    if (endpoint === "session/create") return { sessionId: "host-session-1" };
    if (endpoint === "session/list") return { items: [] };
    if (endpoint === "session/selectModel") {
      // The host refuses the model the client named, so the sidecar falls
      // back to the provider's own model.
      if (this.refusedSelections === 0) {
        this.refusedSelections += 1;
        throw new Error(`model-unavailable`);
      }
      return { selected: true };
    }
    return undefined;
  }

  async *stream(
    endpoint: string,
    args: Record<string, unknown>,
    _options: { readonly signal?: AbortSignal } = {},
  ): AsyncGenerator<unknown> {
    this.streams.push({ endpoint, args });
    // The stream ends at once: the test reads the arguments it carried, and
    // a turn whose stream ends without an end event is a cancelled turn.
  }

  asClient(): DshHostClient {
    return this as unknown as DshHostClient;
  }
}

/** Every call the sidecar made to one endpoint. */
function callsTo(host: WireHost, endpoint: string): Recorded[] {
  return host.calls.filter((call) => call.endpoint === endpoint);
}

/** Every stream the sidecar opened on one endpoint. */
function streamsTo(host: WireHost, endpoint: string): Recorded[] {
  return host.streams.filter((stream) => stream.endpoint === endpoint);
}

/** The one call the sidecar made to an endpoint. */
function callTo(host: WireHost, endpoint: string): Recorded {
  const found = callsTo(host, endpoint);
  expect(found).toHaveLength(1);
  return found[0]!;
}

/** The business object one call carried under its envelope key. */
function envelope(recorded: Recorded, key: string): Record<string, unknown> {
  const value = recorded.args[key];
  expect(typeof value).toBe("object");
  expect(value).not.toBeNull();
  return value as Record<string, unknown>;
}

/**
 * Drive every call the sidecar makes to the host.
 *
 * The turn runs against a stream that ends at once, so the arguments are the
 * only thing under test and the turn settles on its own.
 */
async function drive(): Promise<WireHost> {
  const host = new WireHost();
  await createDshHostSession(host.asClient(), { cwd: "/work", agentPreset: "deepseek" });
  await selectHostModel(
    host.asClient(),
    "host-session-1",
    { provider: "deepseek-official", models: ["DeepSeek-V4.1-Pro"] },
    "DeepSeek-V9",
    "high",
  );
  await runDshHostTurn(host.asClient(), {
    sessionId: "host-session-1",
    prompt: "Fix the failing test",
    onUpdate: () => undefined,
  });
  await listDshHostSessions(host.asClient());
  await loadDshHostHistory(host.asClient(), { sessionId: "host-session-1" });
  return host;
}

describe("the dsh host's argument envelope", () => {
  it("carries the new session under the host's request key", async () => {
    const host = await drive();
    const created = callTo(host, "session/create");
    expect(Object.keys(created.args)).toEqual(["request"]);
    expect(envelope(created, "request")["cwd"]).toBe("/work");
    expect(envelope(created, "request")["agentPreset"]).toBe("deepseek");
  });

  it("carries the model selection under the host's request key", async () => {
    const host = await drive();
    const selections = callsTo(host, "session/selectModel");
    // The first selection is refused and the sidecar falls back, so both
    // carry the envelope.
    expect(selections).toHaveLength(2);
    for (const selection of selections) {
      expect(Object.keys(selection.args)).toEqual(["request"]);
    }
    expect(envelope(selections[0]!, "request")["sessionId"]).toBe("host-session-1");
    expect(envelope(selections[0]!, "request")["provider"]).toBe("deepseek-official");
    expect(envelope(selections[0]!, "request")["model"]).toBe("DeepSeek-V9");
    expect(envelope(selections[0]!, "request")["reasoningEffort"]).toBe("high");
    // The fallback is the provider's own model, under the same envelope.
    expect(envelope(selections[1]!, "request")["model"]).toBe("DeepSeek-V4.1-Pro");
  });

  it("carries the prompt under the host's request key", async () => {
    const host = await drive();
    const prompt = callTo(host, "session/prompt");
    expect(Object.keys(prompt.args)).toEqual(["request"]);
    expect(envelope(prompt, "request")["sessionId"]).toBe("host-session-1");
    expect(envelope(prompt, "request")["mode"]).toBe("queue");
    expect(envelope(prompt, "request")["content"]).toEqual([
      { type: "text", text: "Fix the failing test" },
    ]);
    expect(typeof envelope(prompt, "request")["requestId"]).toBe("string");
  });

  it("carries the turn's stream under the host's request key", async () => {
    const host = await drive();
    const follows = streamsTo(host, "session/follow");
    expect(follows.length).toBeGreaterThan(0);
    for (const follow of follows) {
      expect(Object.keys(follow.args)).toEqual(["request"]);
      expect(envelope(follow, "request")["address"]).toEqual({
        kind: "session",
        sessionId: "host-session-1",
      });
    }
    // The turn reads the live events alone, so it leaves the window out
    // entirely: the host refuses a window of zero.
    expect(envelope(follows[0]!, "request")).not.toHaveProperty("maxMessages");
    // The history reads the thread's opening window, so it asks for one.
    expect(envelope(follows[1]!, "request")["maxMessages"]).toBe(200);
  });

  it("keeps the list's own _request key", async () => {
    const host = await drive();
    const list = callTo(host, "session/list");
    expect(list.args).toEqual({ _request: {} });
    expect(list.args["request"]).toBeUndefined();
  });

  it("sends no business field outside the envelope", async () => {
    const host = await drive();
    const businessFields = [
      "address",
      "agentPreset",
      "content",
      "cwd",
      "maxMessages",
      "mode",
      "model",
      "provider",
      "reasoningEffort",
      "requestId",
      "sessionId",
    ];
    for (const recorded of [...host.calls, ...host.streams]) {
      for (const field of businessFields) {
        expect(recorded.args).not.toHaveProperty(field);
      }
    }
  });
});
