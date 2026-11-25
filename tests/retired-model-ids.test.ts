import { describe, expect, it } from "vitest";

import { isRetiredModelId, rewriteRetiredModelId } from "../src/shared/retired-model-ids.ts";

// The retired-id map is the load-side half of a catalog removal: dropping
// the row hides it in the picker, but a saved selection keeps naming the
// old id until something rewrites it.  These tests pin the rewrite's
// edges — exact match only, and provider-qualified spellings only under a
// qualifier that routes to the same vendor.
describe("rewriteRetiredModelId", () => {
  it("rewrites the retired MiniMax-M3 onto MiniMax-M3.1-Flash", () => {
    expect(rewriteRetiredModelId("MiniMax-M3")).toBe("MiniMax-M3.1-Flash");
    expect(isRetiredModelId("MiniMax-M3")).toBe(true);
  });

  it("rewrites the renamed M3.1 Flash Preview spelling", () => {
    expect(rewriteRetiredModelId("MiniMax-M3.1-Flash-Preview")).toBe("MiniMax-M3.1-Flash");
    expect(isRetiredModelId("MiniMax-M3.1-Flash-Preview")).toBe(true);
  });

  it("folds the retired deepseek-v4-flash spelling onto the declared picker id", () => {
    expect(rewriteRetiredModelId("deepseek-v4-flash")).toBe("DeepSeek-V4.1-Flash");
    expect(isRetiredModelId("deepseek-v4-flash")).toBe(true);
  });

  it("leaves live ids alone, including ones that contain a retired stem", () => {
    for (const live of [
      "MiniMax-M3.1-Flash",
      "MiniMax-M2.7",
      "MiniMax-M2.7-highspeed",
      "DeepSeek-V4.1-Flash",
      "DeepSeek-V4.1-Pro",
      "deepseek-flash",
      "glm-5.3",
    ]) {
      expect(rewriteRetiredModelId(live), live).toBe(live);
      expect(isRetiredModelId(live), live).toBe(false);
    }
  });

  it("keeps a known route qualifier on the replacement", () => {
    expect(rewriteRetiredModelId("minimax/MiniMax-M3")).toBe("minimax/MiniMax-M3.1-Flash");
    expect(rewriteRetiredModelId("minimax-coding-plan/MiniMax-M3")).toBe(
      "minimax-coding-plan/MiniMax-M3.1-Flash",
    );
    expect(isRetiredModelId("minimax-coding-plan/MiniMax-M3")).toBe(true);
  });

  it("leaves a retired stem under an unknown qualifier alone", () => {
    // A different route whose trailing segment merely shares the text is
    // not the retired model.
    expect(rewriteRetiredModelId("some-other-route/MiniMax-M3")).toBe("some-other-route/MiniMax-M3");
    expect(isRetiredModelId("some-other-route/MiniMax-M3")).toBe(false);
  });
});
