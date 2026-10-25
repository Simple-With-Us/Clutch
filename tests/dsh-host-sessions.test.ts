import { describe, it, expect } from "vitest";

import {
  dshHostEventToUpdate,
  dshHostHistoryUpdates,
  dshHostSessionSummaries,
} from "../src/web/dshHostSessions.ts";
import { compactToolHistory } from "../src/web/sessionUpdates.ts";

/**
 * dsh-host-sessions — the translation from the dsh host's session graph into
 * the transcript vocabulary the clients already render.
 *
 * The point of the translation is that a DeepSeek thread and a MiniMax Code
 * thread are indistinguishable to the app: same kinds, same tool-call
 * convention, same history shape.
 */

describe("dshHostSessionSummaries", () => {
  it("reads the host's session list", () => {
    const summaries = dshHostSessionSummaries({
      items: [
        {
          sessionId: "session-abc",
          updatedAt: 1_700_000_000_000,
          running: false,
          blank: false,
          cwd: "/Users/jay/Code/Clutch",
        },
      ],
    });
    expect(summaries).toHaveLength(1);
    expect(summaries[0]?.sessionId).toBe("session-abc");
    expect(summaries[0]?.cwd).toBe("/Users/jay/Code/Clutch");
  });

  it("turns the host's epoch stamp into an ISO date", () => {
    const summaries = dshHostSessionSummaries({
      items: [{ sessionId: "session-abc", updatedAt: 1_700_000_000_000 }],
    });
    expect(summaries[0]?.updatedAt).toBe("2023-11-14T22:13:20.000Z");
  });

  it("takes the title from the session's projections", () => {
    const summaries = dshHostSessionSummaries({
      items: [
        {
          sessionId: "session-abc",
          projections: { asOfSeq: 12, values: { title: "Fix the picker" } },
        },
      ],
    });
    expect(summaries[0]?.title).toBe("Fix the picker");
  });

  it("leaves the title out when the session has none", () => {
    const summaries = dshHostSessionSummaries({
      items: [{ sessionId: "session-abc", projections: { asOfSeq: 12, values: {} } }],
    });
    expect(summaries[0]?.title).toBeUndefined();
  });

  it("drops a session with no id", () => {
    const summaries = dshHostSessionSummaries({ items: [{ cwd: "/tmp" }, { sessionId: "session-ok" }] });
    expect(summaries.map((row) => row.sessionId)).toEqual(["session-ok"]);
  });

  it("caps the list, because the host returns every session it knows", () => {
    const items = Array.from({ length: 50 }, (_, index) => ({ sessionId: `session-${index}` }));
    expect(dshHostSessionSummaries({ items }, 10)).toHaveLength(10);
  });

  it("answers with nothing when the host said nothing", () => {
    expect(dshHostSessionSummaries(undefined)).toEqual([]);
    expect(dshHostSessionSummaries({})).toEqual([]);
  });
});

describe("dshHostEventToUpdate", () => {
  it("reads a user message", () => {
    const update = dshHostEventToUpdate("session-abc", {
      type: "user/message",
      seq: 1,
      time: 0,
      data: {
        id: "m1",
        role: "user",
        content: [{ type: "text", text: "hello" }],
        source: { kind: "user" },
      },
    });
    expect(update).toEqual({ sessionId: "session-abc", kind: "user_message_chunk", text: "hello" });
  });

  it("joins several text blocks of one message", () => {
    const update = dshHostEventToUpdate("session-abc", {
      type: "assistant/message",
      data: {
        turn: 1,
        step: 1,
        message: {
          content: [
            { type: "text", text: "one" },
            { type: "reasoning", text: "thinking" },
            { type: "text", text: "two" },
          ],
        },
      },
    });
    expect(update?.kind).toBe("agent_message_chunk");
    expect(update?.text).toBe("one\ntwo");
  });

  it("reads a tool call as a call with the tool's name as its title", () => {
    const update = dshHostEventToUpdate("session-abc", {
      type: "tool/call",
      data: { turn: 1, step: 1, callId: "call-1", name: "Bash", arguments: '{"cmd":"ls"}' },
    });
    expect(update).toEqual({
      sessionId: "session-abc",
      kind: "tool_call",
      text: "Bash",
      toolCallId: "call-1",
      toolStatus: "running",
    });
  });

  it("reads a tool result as an update that completes the call", () => {
    const update = dshHostEventToUpdate("session-abc", {
      type: "tool/result",
      data: {
        turn: 1,
        step: 1,
        message: {
          role: "user",
          content: [
            {
              type: "tool-result",
              toolCallId: "call-1",
              content: [{ type: "text", text: "a.txt" }],
            },
          ],
        },
      },
    });
    expect(update?.kind).toBe("tool_call_update");
    expect(update?.toolCallId).toBe("call-1");
    expect(update?.toolStatus).toBe("completed");
  });

  it("marks a failed tool result as failed", () => {
    const update = dshHostEventToUpdate("session-abc", {
      type: "tool/result",
      data: {
        message: {
          content: [
            {
              type: "tool-result",
              toolCallId: "call-1",
              content: [{ type: "text", text: "boom" }],
              isError: true,
            },
          ],
        },
        error: { name: "BashError", code: "exit-1" },
      },
    });
    expect(update?.toolStatus).toBe("failed");
  });

  it("ignores the events the clients do not render", () => {
    expect(dshHostEventToUpdate("s", { type: "turn/start", data: { turn: 1 } })).toBeNull();
    expect(dshHostEventToUpdate("s", { type: "step/end", data: { turn: 1, step: 1 } })).toBeNull();
    expect(dshHostEventToUpdate("s", { type: "todo/write", data: {} })).toBeNull();
    expect(dshHostEventToUpdate("s", { type: "assistant/attempt", data: { stream: [] } })).toBeNull();
  });

  it("ignores an event with no data", () => {
    expect(dshHostEventToUpdate("s", { type: "user/message" })).toBeNull();
    expect(dshHostEventToUpdate("s", null)).toBeNull();
  });
});

describe("dshHostHistoryUpdates", () => {
  it("unwraps the host's record envelope", () => {
    const updates = dshHostHistoryUpdates("session-abc", [
      {
        type: "event",
        event: {
          type: "user/message",
          seq: 1,
          time: 0,
          data: { content: [{ type: "text", text: "hi" }] },
        },
      },
    ]);
    expect(updates).toHaveLength(1);
    expect(updates[0]?.text).toBe("hi");
  });

  it("reads a bare event as well as a wrapped one", () => {
    const updates = dshHostHistoryUpdates("session-abc", [
      { type: "user/message", data: { content: [{ type: "text", text: "hi" }] } },
    ]);
    expect(updates).toHaveLength(1);
  });

  it("answers with nothing when there are no records", () => {
    expect(dshHostHistoryUpdates("s", undefined)).toEqual([]);
    expect(dshHostHistoryUpdates("s", [])).toEqual([]);
  });

  it("produces a history the shared compactor can collapse", () => {
    const updates = dshHostHistoryUpdates("session-abc", [
      {
        type: "event",
        event: {
          type: "tool/call",
          data: { callId: "call-1", name: "Bash", arguments: "{}" },
        },
      },
      {
        type: "event",
        event: {
          type: "tool/result",
          data: {
            message: {
              content: [
                { type: "tool-result", toolCallId: "call-1", content: [{ type: "text", text: "ok" }] },
              ],
            },
          },
        },
      },
    ]);
    const compacted = compactToolHistory(updates);
    expect(compacted).toHaveLength(1);
    expect(compacted[0]?.text).toBe("Bash");
    expect(compacted[0]?.toolStatus).toBe("completed");
  });
});
