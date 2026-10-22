import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import {
  clearUsageCache,
  contextUsedPercent,
  extractUsageFromLogText,
  outputTokensPerSecond,
  readSessionUsage,
  sessionLogPath,
  zstdAvailable,
} from "../src/web/session-usage.ts";

/** One engine line in the shapes the engine really writes. */
const line = (obj: unknown): string => JSON.stringify(obj);

const usageLine = (timeMs: number, usage: Record<string, number>) =>
  line({ type: "assistant/message", seq: timeMs, time: timeMs, data: { turn: 1, step: 1, usage } });

const contextLine = (provider: string, model: string, contextWindow: number) =>
  line({ type: "request/context", seq: 1, time: 1, data: { provider, model, contextWindow } });

describe("extractUsageFromLogText", () => {
  it("reads the real accounting record and the model's context window", () => {
    const text = [
      contextLine("minimax", "MiniMax-M3.1-Flash", 1_000_000),
      line({ type: "user/message", seq: 2, time: 2, data: {} }),
      usageLine(179_252_640_2614, {
        inputTokens: 151_923,
        outputTokens: 20,
        totalTokens: 152_071,
        cacheReadTokens: 128,
      }),
    ].join("\n");

    const usage = extractUsageFromLogText(text);
    expect(usage).not.toBeNull();
    expect(usage?.provider).toBe("minimax");
    expect(usage?.model).toBe("MiniMax-M3.1-Flash");
    expect(usage?.contextWindow).toBe(1_000_000);
    expect(usage?.inputTokens).toBe(151_923);
    expect(usage?.outputTokens).toBe(20);
    expect(usage?.totalTokens).toBe(152_071);
    expect(usage?.cacheReadTokens).toBe(128);
    expect(usage?.updatedAtMs).toBe(179_252_640_2614);
  });

  it("keeps the newest usage record when a session has many", () => {
    const text = [
      contextLine("minimax", "MiniMax-M3", 200_000),
      usageLine(1000, { inputTokens: 1, outputTokens: 1, totalTokens: 2 }),
      usageLine(2000, { inputTokens: 5, outputTokens: 6, totalTokens: 11 }),
      usageLine(3000, { inputTokens: 9, outputTokens: 10, totalTokens: 19 }),
    ].join("\n");

    const usage = extractUsageFromLogText(text);
    expect(usage?.totalTokens).toBe(19);
    expect(usage?.updatedAtMs).toBe(3000);
  });

  it("still finds the context window when it sits far outside the tail window", () => {
    // `request/context` is written once near the head; a long session pushes it
    // well beyond TAIL_LINES, so only the whole-file fallback can recover it.
    const parts: string[] = [contextLine("minimax", "MiniMax-M3", 1_000_000)];
    for (let i = 0; i < 5000; i += 1) {
      parts.push(line({ type: "tool/result", seq: i + 10, time: i + 10, data: { pad: "x".repeat(20) } }));
    }
    parts.push(usageLine(999_999, { inputTokens: 1, outputTokens: 2, totalTokens: 3 }));
    const text = parts.join("\n");

    const usage = extractUsageFromLogText(text);
    expect(usage?.contextWindow).toBe(1_000_000);
    expect(usage?.totalTokens).toBe(3);
  });

  it("returns null rather than inventing numbers from an empty or unrelated log", () => {
    expect(extractUsageFromLogText("")).toBeNull();
    expect(extractUsageFromLogText(line({ type: "step/end", seq: 1, time: 1, data: {} }))).toBeNull();
    // A retry record with zeroed counters is not a usage measurement.
    const zeroed = line({
      type: "assistant/attempt",
      seq: 1,
      time: 1,
      data: { stream: [{ type: "chunk", time: 1, chunk: { type: "usage", usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0 } } }] },
    });
    expect(extractUsageFromLogText(zeroed)).toBeNull();
  });

  it("skips a usage record that carries no total", () => {
    const text = [
      contextLine("minimax", "MiniMax-M3", 1000),
      usageLine(1000, { inputTokens: 1, outputTokens: 1 }),
      usageLine(2000, { inputTokens: 3, outputTokens: 4, totalTokens: 7 }),
    ].join("\n");
    expect(extractUsageFromLogText(text)?.totalTokens).toBe(7);
  });
});

describe("outputTokensPerSecond", () => {
  const at = (timeMs: number, outputTokens: number) => ({
    inputTokens: 0,
    outputTokens,
    totalTokens: 0,
    updatedAtMs: timeMs,
  });

  it("measures the rate between two real records", () => {
    // 200 tokens across 2 seconds is 100 tok/s.
    expect(outputTokensPerSecond(at(2000, 200), at(0, 0))).toBe(100);
    expect(outputTokensPerSecond(at(10_000, 1000), at(8000, 0))).toBe(500);
  });

  it("refuses rather than guessing when a rate is not measurable", () => {
    // No prior sample at all.
    expect(outputTokensPerSecond(at(2000, 10), undefined)).toBeUndefined();
    // The clock did not advance.
    expect(outputTokensPerSecond(at(2000, 10), at(2000, 0))).toBeUndefined();
    // Counters went backwards (a compaction, or a provider reset).
    expect(outputTokensPerSecond(at(2000, 5), at(0, 100))).toBeUndefined();
    // Either timestamp missing.
    const noTime = { inputTokens: 0, outputTokens: 10, totalTokens: 0 };
    expect(outputTokensPerSecond(at(2000, 10), noTime)).toBeUndefined();
  });
});

describe("contextUsedPercent", () => {
  it("divides occupancy by the window the engine reported", () => {
    expect(contextUsedPercent({ totalTokens: 610_000, contextWindow: 1_000_000 })).toBeCloseTo(61);
    expect(contextUsedPercent({ totalTokens: 262_144, contextWindow: 262_144 })).toBeCloseTo(100);
  });

  it("is unknown, not zero, when either half is missing", () => {
    expect(contextUsedPercent({ totalTokens: 100, contextWindow: undefined })).toBeUndefined();
    expect(contextUsedPercent({ totalTokens: 100, contextWindow: 0 })).toBeUndefined();
    expect(contextUsedPercent({ totalTokens: Number.NaN, contextWindow: 1000 })).toBeUndefined();
  });
});

/** Build a fake engine home so the file-reading path is exercised too. */
function fakeDshHome(): string {
  const root = mkdtempSync(join(tmpdir(), "clutch-usage-"));
  const sessionDir = join(root, "sessions", "--Users-jay-Code-Example--", "session-abc");
  mkdirSync(sessionDir, { recursive: true });
  writeFileSync(
    join(sessionDir, "session.v3.jsonl.zstd"),
    [
      contextLine("minimax", "MiniMax-M3.1-Flash", 1_000_000),
      usageLine(1700, { inputTokens: 10, outputTokens: 20, totalTokens: 30, cacheReadTokens: 0 }),
    ].join("\n"),
  );
  return root;
}

describe("readSessionUsage", () => {
  it("is honest about a session that has no log on disk", () => {
    clearUsageCache();
    const root = mkdtempSync(join(tmpdir(), "clutch-empty-"));
    expect(readSessionUsage(root, "session-missing")).toBeNull();
    expect(sessionLogPath(root, "session-missing")).toBeNull();
  });

  it("reports nothing instead of throwing when zstd is unavailable", () => {
    clearUsageCache();
    const root = fakeDshHome();
    const got = readSessionUsage(root, "session-abc");
    if (zstdAvailable()) {
      // With zstd the fake log is plain text, not compressed, so decoding must
      // fail cleanly rather than crash or fabricate a reading.
      expect(got).toBeNull();
    } else {
      expect(got).toBeNull();
    }
  });

  it("caches on the log's own mtime so an unchanged log is read once", () => {
    clearUsageCache();
    const root = mkdtempSync(join(tmpdir(), "clutch-cache-"));
    const sessionDir = join(root, "sessions", "g", "session-cache");
    mkdirSync(sessionDir, { recursive: true });
    const log = join(sessionDir, "session.v3.jsonl.zstd");
    writeFileSync(log, "not really zstd");

    expect(readSessionUsage(root, "session-cache")).toBeNull();
    // A rewrite with a new mtime must not serve the stale cached answer.
    const later = new Date(Date.now() + 5000);
    writeFileSync(log, "still not zstd but different");
    utimesSync(log, later, later);
    expect(readSessionUsage(root, "session-cache")).toBeNull();
  });
});