import { describe, expect, it } from "vitest";

import { buildActivityWorkSnapshot, type ActivityThreadInput } from "../src/web/chat-bridge.ts";

const thread = (overrides: Partial<ActivityThreadInput> = {}): ActivityThreadInput => ({
  engine: "minimax",
  threadId: "s1",
  busy: true,
  pendingRequestIds: [],
  ...overrides,
});

describe("the activity work snapshot", () => {
  it("keeps same-id threads of two dsh-hosted engines apart with their own listing titles", () => {
    // Every engine numbers its own sessions, so a DeepSeek thread and a
    // MiniMax Code thread can carry the same raw id.  Each row reads the
    // name of its own engine's filtered host listing, never the other's.
    const snapshot = buildActivityWorkSnapshot(
      [
        thread({ engine: "deepseek", threadId: "s1", busy: true }),
        thread({ engine: "minimax", threadId: "s1", busy: false, pendingRequestIds: ["r1"] }),
      ],
      {
        fallbackTitle: "Thread",
        museTitles: new Map(),
        hostTitles: new Map([
          ["deepseek\u0000s1", "DeepSeek Working"],
          ["minimax\u0000s1", "MiniMax Needs You"],
        ]),
        metaTitles: new Map([["s1", "A Shared Meta Name"]]),
      },
      "local",
    );

    expect(snapshot.runs.map((row) => [row.engine, row.sessionId, row.title])).toEqual([
      ["deepseek", "s1", "DeepSeek Working"],
    ]);
    expect(snapshot.approvals.map((row) => [row.engine, row.sessionId, row.title])).toEqual([
      ["minimax", "s1", "MiniMax Needs You"],
    ]);
  });

  it("never lets a cold Muse row read another engine's name", () => {
    // Cold sidecar:  Muse has not been listed yet, so museTitles is empty.
    // The shared meta file does hold a name for this raw id — the Muse row
    // must still fall back rather than pick it up.
    const snapshot = buildActivityWorkSnapshot(
      [thread({ engine: "muse", threadId: "s1", busy: false, pendingRequestIds: ["r1"] })],
      {
        fallbackTitle: "Thread",
        museTitles: new Map(),
        hostTitles: new Map(),
        metaTitles: new Map([["s1", "A DeepSeek Name"]]),
      },
      "local",
    );

    expect(snapshot.approvals).toHaveLength(1);
    expect(snapshot.approvals[0]?.title).toBe("Thread");
  });

  it("uses Muse's listed name once the listing has run", () => {
    const snapshot = buildActivityWorkSnapshot(
      [thread({ engine: "muse", threadId: "s1", busy: true })],
      {
        fallbackTitle: "Thread",
        museTitles: new Map([["s1", "Muse Listed Name"]]),
        hostTitles: new Map(),
        metaTitles: new Map([["s1", "A DeepSeek Name"]]),
      },
      "local",
    );

    expect(snapshot.runs.map((row) => [row.engine, row.sessionId, row.title])).toEqual([
      ["muse", "s1", "Muse Listed Name"],
    ]);
  });

  it("collapses two turns of one engine's thread and keys rows by host, engine and session", () => {
    const snapshot = buildActivityWorkSnapshot(
      [
        thread({ engine: "mcode", threadId: "s1", busy: true }),
        thread({ engine: "mcode", threadId: "s1", busy: true }),
        thread({ engine: "zcode", threadId: "s1", busy: true }),
      ],
      {
        fallbackTitle: "Thread",
        museTitles: new Map(),
        hostTitles: new Map(),
        metaTitles: new Map([["s1", "Meta Name"]]),
      },
      "local",
    );

    expect(snapshot.runs.map((row) => [row.hostId, row.engine, row.sessionId])).toEqual([
      ["local", "mcode", "s1"],
      ["local", "zcode", "s1"],
    ]);
    expect(snapshot.runs.map((row) => row.title)).toEqual(["Meta Name", "Meta Name"]);
  });
});
