import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { classifyMinimaxError, minimaxSpawnArgs, minimaxSupport, STATIC_MINIMAX_MODELS } from "../src/minimax/acp/driver.ts";
import {
  MINIMAX_DEFAULT_BASE_URL,
  MINIMAX_DEFAULT_MODEL,
  minimaxChatCompletionsUrl,
  minimaxIsAuthenticated,
  minimaxTransformEnv,
} from "../src/minimax/http-client/index.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

// The native model pickers advertise their rows by literal string, so a
// retired id left behind in Swift is selectable and reproduces the API
// refusal the catalog removal was meant to eliminate.
const NATIVE_PICKERS = ["ios/App/Views/ChatView.swift", "ios/Mac/ChatViewMac.swift"];

describe("minimax http client", () => {
  it("builds the chat-completions URL", () => {
    expect(minimaxChatCompletionsUrl()).toBe(`${MINIMAX_DEFAULT_BASE_URL}/chat/completions`);
    expect(minimaxChatCompletionsUrl("https://api.minimax.io/v1/")).toBe("https://api.minimax.io/v1/chat/completions");
  });

  it("fills default env and authenticates on MINIMAX_API_KEY", () => {
    const env: Record<string, string | undefined> = {};
    minimaxTransformEnv(env);
    expect(env.CLUTCH_MINIMAX_BASE_URL).toBe(MINIMAX_DEFAULT_BASE_URL);
    expect(env.CLUTCH_MINIMAX_MODEL).toBe(MINIMAX_DEFAULT_MODEL);
    expect(minimaxIsAuthenticated({})).toBe(false);
    expect(minimaxIsAuthenticated({ MINIMAX_API_KEY: "k" })).toBe(true);
  });
});

describe("minimaxSupport", () => {
  it("exposes MCP server mounts and the current MiniMax model catalog", () => {
    expect(minimaxSpawnArgs()).toEqual([]);
    expect(minimaxSupport.driverKind).toBe("minimaxAgent");
    expect(minimaxSupport.mcpServers).toBe(true);
    expect(STATIC_MINIMAX_MODELS.default).toBe("MiniMax-M2.7-highspeed");
    expect(STATIC_MINIMAX_MODELS.options.map((option) => option.id)).toContain("MiniMax-M3");
  });

  it("does not advertise the retired MiniMax-M3.1-Flash-Preview model", () => {
    // BF-2494 (2026-10-18): MiniMax-M3.1-Flash-Preview was retired on the
    // MiniMax side.  A re-introduction must be a deliberate decision backed
    // by a verified stable replacement, not a regression.
    expect(STATIC_MINIMAX_MODELS.options.map((option) => option.id))
      .not.toContain("MiniMax-M3.1-Flash-Preview");
  });

  it("does not offer the retired model from the native model pickers", () => {
    // BF-2494 (2026-10-18): the iOS and macOS menus name their rows as
    // literals, so the catalog guard above does not reach them.  Offering
    // the retired id there reproduces "model is not available for the
    // managed_token_plan route" on the next turn.
    for (const picker of NATIVE_PICKERS) {
      expect(readFileSync(join(ROOT, picker), "utf8"), picker)
        .not.toContain("MiniMax-M3.1-Flash-Preview");
    }
  });
});

describe("classifyMinimaxError", () => {
  it("maps MiniMax HTTP failures onto provider codes", () => {
    expect(classifyMinimaxError(new Error("invalid api key"))).toBe("invalid_credentials");
    expect(classifyMinimaxError(new Error("insufficient balance"))).toBe("quota_or_region_restriction");
    expect(classifyMinimaxError(new Error("unknown model xyz"))).toBe("model_catalog_outage");
    expect(classifyMinimaxError(new Error("nope"))).toBeUndefined();
  });
});

describe("minimaxEffortLevelsForModel", () => {
  it("gives MiniMax-M3 the full effort range and falls back for M2.7", async () => {
    const { minimaxEffortLevelsForModel } = await import("../src/minimax/acp/driver.ts");
    expect(minimaxEffortLevelsForModel("MiniMax-M3")).toEqual(["none", "low", "medium", "high", "max"]);
    expect(minimaxEffortLevelsForModel("MiniMax-M2.7")).toEqual(["none"]);
    expect(minimaxEffortLevelsForModel("MiniMax-M2.7-highspeed")).toEqual(["none"]);
    expect(minimaxEffortLevelsForModel("unknown-model")).toEqual(["none"]);
  });

  it("declares the per-model map on minimaxSupport", () => {
    expect(minimaxSupport.perModelEffortLevels?.["MiniMax-M3"]).toEqual([
      "none",
      "low",
      "medium",
      "high",
      "max",
    ]);
  });
});
