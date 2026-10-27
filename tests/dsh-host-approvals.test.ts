import { describe, it, expect } from "vitest";

import { DshHostApprovalRelay, type HostApproval } from "../src/web/dshHostApprovals.ts";
import type { DshHostClient } from "../src/web/dshHostClient.ts";

/**
 * dsh-host-approvals — the sidecar's end of the host's approval channel.
 *
 * The host asks for approval through a waterfall: it hands the question to
 * every client on its event stream, and the answer comes back over a unary
 * endpoint with the id the question carried.  The native apps never speak
 * that protocol, so the sidecar does it for them.
 *
 * The tests drive the relay against a host that behaves like the real one:
 * it opens the stream with a frame that names the generation, it asks
 * questions through waterfall frames, and it tells the clients a question is
 * no longer waiting with a cancellation.
 */

class FakeHost {
  readonly calls: Array<{ endpoint: string; args: Record<string, unknown> }> = [];
  readonly streams: Array<{ endpoint: string; args: Record<string, unknown> }> = [];

  private readonly queue: unknown[] = [];
  private readonly waiters: Array<() => void> = [];

  async *stream(endpoint: string, args: Record<string, unknown>): AsyncGenerator<unknown> {
    this.streams.push({ endpoint, args });
    for (;;) {
      while (this.queue.length > 0) yield this.queue.shift();
      await new Promise<void>((resolve) => this.waiters.push(resolve));
    }
  }

  async call(endpoint: string, args: Record<string, unknown>): Promise<unknown> {
    this.calls.push({ endpoint, args });
    return undefined;
  }

  /** Hand one frame to the reader. */
  push(frame: unknown): void {
    this.queue.push(frame);
    this.waiters.shift()?.();
  }

  asClient(): DshHostClient {
    return this as unknown as DshHostClient;
  }
}

/** Start a relay over a fake host and wait until the host named the stream. */
async function started(
  host: FakeHost,
  hooks: {
    onApproval?: (approval: HostApproval) => void;
    onSettled?: (eventId: string) => void;
  } = {},
): Promise<DshHostApprovalRelay> {
  const relay = DshHostApprovalRelay.start({
    client: async () => host.asClient(),
    onApproval: hooks.onApproval ?? (() => undefined),
    ...(hooks.onSettled ? { onSettled: hooks.onSettled } : {}),
  });
  host.push({ type: "ready", clientId: "client-1", host: { home: "/home" } });
  await relay.ready(2_000);
  return relay;
}

describe("the host approval relay", () => {
  it("opens the host's event stream", async () => {
    const host = new FakeHost();
    const relay = await started(host);
    expect(host.streams[0]?.endpoint).toBe("$events");
    // The host requires an empty argument object on this stream.
    expect(host.streams[0]?.args).toEqual({});
    relay.stop();
  });

  it("reports the approval the host asked about", async () => {
    const host = new FakeHost();
    const approvals: HostApproval[] = [];
    const relay = await started(host, { onApproval: (approval) => approvals.push(approval) });

    host.push({
      type: "waterfall",
      event: "approval/request",
      eventId: "event-1",
      agentId: "session-7",
      request: { toolName: "bash", callId: "call-3", reason: "writes outside the workspace" },
    });
    await waitFor(() => approvals.length > 0);

    expect(approvals[0]).toEqual({
      eventId: "event-1",
      agentId: "session-7",
      toolName: "bash",
      callId: "call-3",
      reason: "writes outside the workspace",
    });
    relay.stop();
  });

  it("leaves out the fields the host did not send", async () => {
    const host = new FakeHost();
    const approvals: HostApproval[] = [];
    const relay = await started(host, { onApproval: (approval) => approvals.push(approval) });

    host.push({
      type: "waterfall",
      event: "approval/request",
      eventId: "event-2",
      agentId: "session-7",
      request: { toolName: "bash" },
    });
    await waitFor(() => approvals.length > 0);

    expect(approvals[0]?.callId).toBeUndefined();
    expect(approvals[0]?.reason).toBeUndefined();
    relay.stop();
  });

  it("answers on the host's result endpoint, in the generation that asked", async () => {
    const host = new FakeHost();
    const approvals: HostApproval[] = [];
    const relay = await started(host, { onApproval: (approval) => approvals.push(approval) });

    host.push({
      type: "waterfall",
      event: "approval/request",
      eventId: "event-3",
      agentId: "session-7",
      request: { toolName: "bash" },
    });
    await waitFor(() => approvals.length > 0);

    const answered = await relay.answer("event-3", "allowed-once");
    expect(answered).toBe(true);
    expect(host.calls[0]).toEqual({
      endpoint: "$events/result",
      args: {
        clientId: "client-1",
        eventId: "event-3",
        outcome: { kind: "result", value: "allowed-once" },
      },
    });
    relay.stop();
  });

  it("refuses to answer a question it was never given", async () => {
    const host = new FakeHost();
    const relay = await started(host);
    expect(await relay.answer("event-unknown", "rejected")).toBe(false);
    expect(host.calls).toHaveLength(0);
    relay.stop();
  });

  it("ignores a question another event asked", async () => {
    const host = new FakeHost();
    const approvals: HostApproval[] = [];
    const relay = await started(host, { onApproval: (approval) => approvals.push(approval) });

    host.push({
      type: "waterfall",
      event: "user-questions/request",
      eventId: "event-4",
      agentId: "session-7",
      request: { questions: [] },
    });
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(approvals).toHaveLength(0);
    relay.stop();
  });

  it("ignores a question with no tool in it", async () => {
    const host = new FakeHost();
    const approvals: HostApproval[] = [];
    const relay = await started(host, { onApproval: (approval) => approvals.push(approval) });

    host.push({
      type: "waterfall",
      event: "approval/request",
      eventId: "event-5",
      agentId: "session-7",
      request: { reason: "no tool named" },
    });
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(approvals).toHaveLength(0);
    relay.stop();
  });

  it("tells the caller when the host settled a question elsewhere", async () => {
    const host = new FakeHost();
    const settled: string[] = [];
    const approvals: HostApproval[] = [];
    const relay = await started(host, {
      onApproval: (approval) => approvals.push(approval),
      onSettled: (eventId) => settled.push(eventId),
    });

    host.push({
      type: "waterfall",
      event: "approval/request",
      eventId: "event-6",
      agentId: "session-7",
      request: { toolName: "bash" },
    });
    await waitFor(() => approvals.length > 0);
    host.push({ type: "cancel", eventId: "event-6" });
    await waitFor(() => settled.length > 0);

    expect(settled).toEqual(["event-6"]);
    // A question the host already settled cannot be answered again.
    expect(await relay.answer("event-6", "allowed-once")).toBe(false);
    relay.stop();
  });

  it("ignores a frame that is not one of the host's", async () => {
    const host = new FakeHost();
    const approvals: HostApproval[] = [];
    const settled: string[] = [];
    const relay = await started(host, {
      onApproval: (approval) => approvals.push(approval),
      onSettled: (eventId) => settled.push(eventId),
    });

    host.push({ type: "nonsense" });
    host.push({ type: "waterfall", eventId: "event-7" });
    host.push({ type: "cancel" });
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(approvals).toHaveLength(0);
    expect(settled).toHaveLength(0);
    relay.stop();
  });

  it("reads the host's notifications without treating them as questions", async () => {
    const host = new FakeHost();
    const approvals: HostApproval[] = [];
    const relay = await started(host, { onApproval: (approval) => approvals.push(approval) });

    host.push({ type: "emit", event: "api-session/status", args: [{ sessionId: "session-7" }] });
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(approvals).toHaveLength(0);
    relay.stop();
  });
});

/** Wait until a condition holds, or give up after a moment. */
async function waitFor(condition: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
