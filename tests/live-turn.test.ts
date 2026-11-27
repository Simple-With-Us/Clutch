import { describe, expect, it } from "vitest";
import { findLiveTurn } from "../src/web/liveTurn.ts";

const turn = (over: Partial<{ engine: string; resumeSessionId: string | null; busy: boolean; bridgeSessionId: string }> = {}) => ({
  engine: "muse", resumeSessionId: "remote-1", busy: true, bridgeSessionId: "bridge-1", ...over,
});

describe("findLiveTurn", () => {
  it("offers the chat session id of a running Muse turn for the thread", () => {
    const sessions = new Map([["chat-other", turn({ resumeSessionId: "remote-2" })], ["chat-live", turn()]]);
    expect(findLiveTurn(sessions, "muse", "remote-1")).toEqual({ running: true, liveSessionId: "chat-live" });
  });

  it("reports nothing for a thread whose sessions are idle", () => {
    const sessions = new Map([["chat-idle", turn({ busy: false })]]);
    expect(findLiveTurn(sessions, "muse", "remote-1")).toEqual({ running: false });
  });

  it("reports running without a steering id when the turn has no bridge session or another engine", () => {
    expect(findLiveTurn(new Map([["c", turn({ bridgeSessionId: "" })]]), "muse", "remote-1")).toEqual({ running: true });
    expect(findLiveTurn(new Map([["c", turn({ engine: "deepseek" })]]), "deepseek", "remote-1")).toEqual({ running: true });
  });

  it("does not match another engine's thread of the same id", () => {
    expect(findLiveTurn(new Map([["c", turn({ engine: "deepseek" })]]), "muse", "remote-1")).toEqual({ running: false });
  });
});
