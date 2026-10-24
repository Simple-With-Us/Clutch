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
// refusal the catalog removal was meant to eliminate.  The Mac picker now
// reads the host's live catalog (src/web/engine-catalog.ts), so that file
// is part of the same guard: it is where the native rows come from.
const NATIVE_PICKERS = ["ios/App/Views/ChatView.swift", "ios/Mac/ChatViewMac.swift"];
const NATIVE_CATALOGS = ["src/web/engine-catalog.ts"];

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
    expect(STATIC_MINIMAX_MODELS.default).toBe("MiniMax-M3.1-Flash");
    expect(STATIC_MINIMAX_MODELS.options.map((option) => option.id)).toContain("MiniMax-M3");
  });

  it("advertises the working MiniMax-M3.1-Flash replacement", () => {
    // BF-2494 (2026-10-18): MiniMax retired MiniMax-M3.1-Flash-Preview.
    // MiniMax-M3.1-Flash is its stable successor, live on both the managed
    // and the direct route, and the M3-class multimodal model the picker
    // offers in its place.
    const ids = STATIC_MINIMAX_MODELS.options.map((option) => option.id);
    expect(ids).toContain("MiniMax-M3.1-Flash");
    const row = STATIC_MINIMAX_MODELS.options.find((option) => option.id === "MiniMax-M3.1-Flash");
    expect(row?.images).toBe(true);
    expect(row?.contextWindow).toBe(1_000_000);
  });

  it("does not advertise the retired MiniMax-M3.1-Flash-Preview model", () => {
    // The Preview id is gone for good: a turn asking for it fails before
    // the model ever runs.  The replacement is MiniMax-M3.1-Flash.
    expect(STATIC_MINIMAX_MODELS.options.map((option) => option.id))
      .not.toContain("MiniMax-M3.1-Flash-Preview");
  });

  it("does not offer the retired model from the native model pickers", () => {
    // BF-2494 (2026-10-18): the iOS and macOS menus name their rows as
    // literals, so the catalog guard above does not reach them.  Offering
    // the retired id there reproduces "model is not available for the
    // managed_token_plan route" on the next turn.
    for (const picker of [...NATIVE_PICKERS, ...NATIVE_CATALOGS]) {
      expect(readFileSync(join(ROOT, picker), "utf8"), picker)
        .not.toContain("MiniMax-M3.1-Flash-Preview");
    }
    // The native pickers must offer the working replacement, or the M3.1
    // option the owner asked for exists only in the TypeScript catalog.
    // The Mac picker reads the live catalog, so the catalog carries the
    // row now; the iOS agent menu still names it as a literal.
    for (const picker of NATIVE_CATALOGS) {
      expect(readFileSync(join(ROOT, picker), "utf8"), picker)
        .toContain("MiniMax-M3.1-Flash");
    }
    expect(readFileSync(join(ROOT, NATIVE_PICKERS[0]), "utf8"), NATIVE_PICKERS[0])
      .toContain("MiniMax-M3.1-Flash");
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
    // M3.1 Flash forces thinking on, so its list starts at "low" and runs
    // through max — there is no "none" level for it.
    expect(minimaxEffortLevelsForModel("MiniMax-M3.1-Flash")).toEqual(["low", "medium", "high", "xhigh", "max"]);
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
