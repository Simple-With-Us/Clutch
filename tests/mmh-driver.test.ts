import { describe, expect, it } from "vitest";

import { classifyMmhError, mmhSpawnArgs, mmhSupport, STATIC_MMH_MODELS } from "../src/mmh/acp/driver.ts";
import {
  MMH_DEFAULT_BASE_URL,
  MMH_DEFAULT_MODEL,
  mmhChatCompletionsUrl,
  mmhIsAuthenticated,
  mmhTransformEnv,
} from "../src/mmh/http-client/index.ts";

describe("mmh http client", () => {
  it("builds the chat-completions URL", () => {
    expect(mmhChatCompletionsUrl()).toBe(`${MMH_DEFAULT_BASE_URL}/chat/completions`);
    expect(mmhChatCompletionsUrl("https://api.minimax.io/v1/")).toBe("https://api.minimax.io/v1/chat/completions");
  });

  it("fills default env and authenticates on MINIMAX_API_KEY", () => {
    const env: Record<string, string | undefined> = {};
    mmhTransformEnv(env);
    expect(env.MMH_BASE_URL).toBe(MMH_DEFAULT_BASE_URL);
    expect(env.MMH_MODEL).toBe(MMH_DEFAULT_MODEL);
    expect(mmhIsAuthenticated({})).toBe(false);
    expect(mmhIsAuthenticated({ MINIMAX_API_KEY: "k" })).toBe(true);
  });
});

describe("mmhSupport", () => {
  it("is an HTTP adapter, not an MCP CLI", () => {
    expect(mmhSpawnArgs()).toEqual([]);
    expect(mmhSupport.driverKind).toBe("mmhAgent");
    expect(mmhSupport.mcpServers).toBe(false);
    expect(STATIC_MMH_MODELS.default).toBe("MiniMax-M2.7-highspeed");
    expect(STATIC_MMH_MODELS.options.map((option) => option.id)).toContain("MiniMax-M3");
  });
});

describe("classifyMmhError", () => {
  it("maps MiniMax HTTP failures onto provider codes", () => {
    expect(classifyMmhError(new Error("invalid api key"))).toBe("invalid_credentials");
    expect(classifyMmhError(new Error("insufficient balance"))).toBe("quota_or_region_restriction");
    expect(classifyMmhError(new Error("unknown model xyz"))).toBe("model_catalog_outage");
    expect(classifyMmhError(new Error("nope"))).toBeUndefined();
  });
});

describe("mmhEffortLevelsForModel", () => {
  it("gives MiniMax-M3 the full effort range and falls back for M2.7", async () => {
    const { mmhEffortLevelsForModel } = await import("../src/mmh/acp/driver.ts");
    expect(mmhEffortLevelsForModel("MiniMax-M3")).toEqual(["none", "low", "medium", "high", "max"]);
    expect(mmhEffortLevelsForModel("MiniMax-M2.7")).toEqual(["none"]);
    expect(mmhEffortLevelsForModel("MiniMax-M2.7-highspeed")).toEqual(["none"]);
    expect(mmhEffortLevelsForModel("unknown-model")).toEqual(["none"]);
  });

  it("declares the per-model map on mmhSupport", () => {
    expect(mmhSupport.perModelEffortLevels?.["MiniMax-M3"]).toEqual([
      "none",
      "low",
      "medium",
      "high",
      "max",
    ]);
  });
});
