import { describe, expect, it } from "vitest";

import { buildActivityWorkSnapshot, museTitlesForActivity, type ActivityThreadInput } from "../src/web/chat-bridge.ts";

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
    // The shared meta file has no engine provenance, so a raw id two engines
    // are both using is ambiguous:  the rows take the neutral fallback rather
    // than a name that could belong to either.
    expect(snapshot.runs.map((row) => row.title)).toEqual(["Thread", "Thread"]);
  });

  it("keeps the stored meta title for a raw id only one engine is using", () => {
    const snapshot = buildActivityWorkSnapshot(
      [thread({ engine: "mcode", threadId: "s1", busy: true })],
      {
        fallbackTitle: "Thread",
        museTitles: new Map(),
        hostTitles: new Map(),
        metaTitles: new Map([["s1", "Renamed By The Owner"]]),
      },
      "local",
    );

    expect(snapshot.runs[0]?.title).toBe("Renamed By The Owner");
  });

  it("puts Clutch's stored name first for a hosted thread whose id is unambiguous", () => {
    // A rename through PUT /clutch/v1/session-meta must reach the island:
    // the thread list shows the stored name, so the activity row does too.
    const snapshot = buildActivityWorkSnapshot(
      [thread({ engine: "minimax", threadId: "s1", busy: true })],
      {
        fallbackTitle: "Thread",
        museTitles: new Map(),
        hostTitles: new Map([["minimax\u0000s1", "Host Listing Name"]]),
        metaTitles: new Map([["s1", "Stored Name"]]),
      },
      "local",
    );

    expect(snapshot.runs[0]?.title).toBe("Stored Name");
  });

  it("never reads the ambiguous meta name for a hosted thread, taking the engine listing instead", () => {
    const snapshot = buildActivityWorkSnapshot(
      [
        thread({ engine: "deepseek", threadId: "s1", busy: true }),
        thread({ engine: "minimax", threadId: "s1", busy: false, pendingRequestIds: ["r1"] }),
      ],
      {
        fallbackTitle: "Thread",
        museTitles: new Map(),
        hostTitles: new Map([["minimax\u0000s1", "MiniMax Needs You"]]),
        metaTitles: new Map([["s1", "Somebody's Name"]]),
      },
      "local",
    );

    expect(snapshot.approvals[0]?.title).toBe("MiniMax Needs You");
    expect(snapshot.runs[0]?.title).toBe("Thread");
  });
});

describe("muse titles for the activity snapshot", () => {
  it("reads a named cold thread's native title when the listing has not answered", async () => {
    let reads = 0;
    const titles = await museTitlesForActivity(
      ["cold-1"],
      new Map(),
      async () => {
        reads += 1;
        return "Native Muse Name";
      },
    );

    expect(reads).toBe(1);
    expect(titles.get("cold-1")).toBe("Native Muse Name");
  });

  it("does not re-read a thread the listing already named", async () => {
    let reads = 0;
    const titles = await museTitlesForActivity(
      ["listed-1"],
      new Map([["listed-1", "Listed Name"]]),
      async () => {
        reads += 1;
        return "Log Name";
      },
    );

    expect(reads).toBe(0);
    expect(titles.get("listed-1")).toBe("Listed Name");
  });

  it("leaves a thread with no name anywhere to the builder's fallback", async () => {
    const titles = await museTitlesForActivity(["cold-2"], new Map(), async () => undefined);

    expect(titles.has("cold-2")).toBe(false);
  });
});
