import { describe, it, expect } from "vitest";

import { createDshHostSession, runDshHostTurn } from "../src/web/dshHostTurn.ts";
import type { DshHostClient } from "../src/web/dshHostClient.ts";
import type { SessionUpdate } from "../src/web/sessionUpdates.ts";

/**
 * dsh-host-turn — running a turn inside the dsh host.
 *
 * The dsh-hosted engines live in the host: it owns their threads, their
 * plan, their tool calls and their approval requests.  A turn that runs
 * there is the same turn the web canvas runs, so the sidecar drives it over
 * the host's contract and translates what it hears into the one vocabulary
 * the clients render.
 *
 * The tests drive it against a host that behaves like the real one: it
 * answers `session/create`, it acknowledges the prompt and then runs the
 * turn, and it ends the turn with the event the clients read as the end.
 */

class FakeHost {
  readonly calls: Array<{ endpoint: string; args: Record<string, unknown> }> = [];
  readonly streams: Array<{ endpoint: string; args: Record<string, unknown> }> = [];

  private readonly queue: unknown[] = [];
  private readonly waiters: Array<() => void> = [];

  /** The frames the host sends once the prompt is acknowledged. */
  onPrompt: unknown[] = [];

  async *stream(
    endpoint: string,
    args: Record<string, unknown>,
    options: { readonly signal?: AbortSignal } = {},
  ): AsyncGenerator<unknown> {
    this.streams.push({ endpoint, args });
    // A cancelled stream ends like a finished one, so the reader stops and
    // the generator's cleanup runs.
    let cancelled = false;
    const onAbort = (): void => {
      cancelled = true;
      this.waiters.shift()?.();
    };
    options.signal?.addEventListener("abort", onAbort, { once: true });
    try {
      for (;;) {
        while (this.queue.length > 0) yield this.queue.shift();
        if (cancelled) return;
        await new Promise<void>((resolve) => this.waiters.push(resolve));
        if (cancelled) return;
      }
    } finally {
      options.signal?.removeEventListener("abort", onAbort);
    }
  }

  async call(endpoint: string, args: Record<string, unknown>): Promise<unknown> {
    this.calls.push({ endpoint, args });
    if (endpoint === "session/create") return { sessionId: "host-session-1" };
    if (endpoint === "session/prompt") {
      for (const frame of this.onPrompt) this.push(frame);
    }
    return undefined;
  }

  push(frame: unknown): void {
    this.queue.push(frame);
    this.waiters.shift()?.();
  }

  asClient(): DshHostClient {
    return this as unknown as DshHostClient;
  }
}

/** One host event, in the shape the host's stream carries. */
function event(type: string, data: unknown): unknown {
  return { type: "event", event: { type, seq: 1, time: 0, data } };
}

describe("opening a thread in the host", () => {
  it("asks the host for a session and keeps its id", async () => {
    const host = new FakeHost();
    const sessionId = await createDshHostSession(host.asClient(), { cwd: "/work" });
    expect(sessionId).toBe("host-session-1");
    expect(host.calls[0]).toEqual({ endpoint: "session/create", args: { cwd: "/work" } });
  });

  it("names the agent preset when one is asked for", async () => {
    const host = new FakeHost();
    await createDshHostSession(host.asClient(), { cwd: "/work", agentPreset: "deepseek" });
    expect(host.calls[0]?.args).toEqual({ cwd: "/work", agentPreset: "deepseek" });
  });

  it("refuses a session the host did not name", async () => {
    const host = new FakeHost();
    const unnamed = {
      call: async () => ({}),
    } as unknown as DshHostClient;
    await expect(createDshHostSession(unnamed, { cwd: "/work" })).rejects.toThrow(/without naming it/);
    expect(host.calls).toHaveLength(0);
  });
});

describe("running a turn in the host", () => {
  it("opens the thread's stream and then sends the prompt", async () => {
    const host = new FakeHost();
    host.onPrompt = [event("turn/end", { reason: { kind: "completed" } })];

    await runDshHostTurn(host.asClient(), {
      sessionId: "host-session-1",
      prompt: "Fix the failing test",
      onUpdate: () => undefined,
    });

    // The stream is opened first, so no event of the turn is missed.
    expect(host.streams[0]?.endpoint).toBe("session/follow");
    expect(host.streams[0]?.args).toEqual({
      address: { kind: "session", sessionId: "host-session-1" },
      maxMessages: 0,
    });
    const prompt = host.calls.find((call) => call.endpoint === "session/prompt");
    expect(prompt?.args["sessionId"]).toBe("host-session-1");
    expect(prompt?.args["mode"]).toBe("queue");
    expect(prompt?.args["content"]).toEqual([{ type: "text", text: "Fix the failing test" }]);
    expect(typeof prompt?.args["requestId"]).toBe("string");
  });

  it("carries the attached images with the prompt", async () => {
    const host = new FakeHost();
    host.onPrompt = [event("turn/end", { reason: { kind: "completed" } })];

    await runDshHostTurn(host.asClient(), {
      sessionId: "host-session-1",
      prompt: "What is this?",
      images: [{ mediaType: "image/png", data: "AAAA", name: "shot.png" }],
      onUpdate: () => undefined,
    });

    const prompt = host.calls.find((call) => call.endpoint === "session/prompt");
    expect(prompt?.args["content"]).toEqual([
      { type: "text", text: "What is this?" },
      { type: "image", mediaType: "image/png", data: "AAAA", name: "shot.png" },
    ]);
  });

  it("translates what the host says into the clients' vocabulary", async () => {
    const host = new FakeHost();
    const updates: SessionUpdate[] = [];
    host.onPrompt = [
      event("user/message", { content: [{ type: "text", text: "Fix the failing test" }] }),
      event("todo/write", { todos: [{ content: "Read the test", status: "in_progress" }] }),
      event("assistant/message", {
        message: { content: [{ type: "text", text: "On it." }] },
      }),
      event("turn/end", { reason: { kind: "completed" } }),
    ];

    const result = await runDshHostTurn(host.asClient(), {
      sessionId: "host-session-1",
      prompt: "Fix the failing test",
      onUpdate: (update) => updates.push(update),
    });

    expect(updates.map((update) => update.kind)).toEqual([
      "user_message_chunk",
      "plan",
      "agent_message_chunk",
    ]);
    expect(updates[1]?.plan).toEqual([
      { content: "Read the test", priority: "medium", status: "in_progress" },
    ]);
    expect(result.stopReason).toBe("end_turn");
  });

  it("reads a turn the host aborted as a cancellation", async () => {
    const host = new FakeHost();
    host.onPrompt = [event("turn/end", { reason: { kind: "aborted" } })];
    const result = await runDshHostTurn(host.asClient(), {
      sessionId: "host-session-1",
      prompt: "Stop",
      onUpdate: () => undefined,
    });
    expect(result.stopReason).toBe("cancelled");
  });

  it("keeps a reason the clients do not know", async () => {
    const host = new FakeHost();
    host.onPrompt = [event("turn/end", { reason: { kind: "max-tokens" } })];
    const result = await runDshHostTurn(host.asClient(), {
      sessionId: "host-session-1",
      prompt: "Long one",
      onUpdate: () => undefined,
    });
    expect(result.stopReason).toBe("max-tokens");
  });

  it("ends the turn when the owner stops it", async () => {
    const host = new FakeHost();
    host.onPrompt = [];
    const result = await runDshHostTurn(host.asClient(), {
      sessionId: "host-session-1",
      prompt: "Quiet",
      onUpdate: () => undefined,
      signal: AbortSignal.timeout(50),
    });
    expect(result.stopReason).toBe("cancelled");
  });
});
