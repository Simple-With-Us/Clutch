import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  clearZcodeUsageCache,
  readZcodeSessionUsage,
  zcodeSessionFileName,
  zcodeSessionUsage,
  zcodeSessionsRoot,
} from "../src/web/zcode-session-usage.ts";

/**
 * Z Code session usage, read from the engine's own log.
 *
 * The numbers under test are the ones a Z Code session really produced: the
 * model and provider it used, how long the response took, and the provider's
 * own token counters.  Nothing here may be an estimate, and the context
 * window is never invented.
 */

const SESSION_ID = "sess_c5b7367c-f9da-4882-abbc-f381ddcec9d7";

function record(options: {
  outputTokens: number;
  inputTokens?: number;
  totalTokens?: number;
  cacheReadTokens?: number;
  durationMs: number;
  completedAt?: string;
  modelId?: string;
  providerId?: string;
}): string {
  return JSON.stringify({
    type: "model_io",
    attempt: 1,
    sessionId: SESSION_ID,
    turnId: "turn_645abdb6-e829-467c-88cd-be97edef774d",
    startedAt: "2026-11-11T02:31:21.233Z",
    completedAt: options.completedAt ?? "2026-11-11T02:32:11.771Z",
    durationMs: options.durationMs,
    model: { modelId: options.modelId ?? "GLM-5.3-Flash", providerId: options.providerId ?? "account:zai-individual-coding-plan" },
    response: {
      modelId: options.modelId ?? "GLM-5.3-Flash",
      usage: {
        inputTokens: options.inputTokens ?? 154_644,
        outputTokens: options.outputTokens,
        totalTokens: options.totalTokens ?? (options.inputTokens ?? 154_644) + options.outputTokens,
        cacheReadTokens: options.cacheReadTokens ?? 0,
        cacheWriteTokens: 0,
      },
    },
  });
}

let root = "";

beforeEach(() => {
  clearZcodeUsageCache();
  root = mkdtempSync(join(tmpdir(), "clutch-zcode-usage-"));
});

afterEach(() => {
  if (root) rmSync(root, { recursive: true, force: true });
});

function writeLog(name: string, lines: string[]): string {
  const path = join(root, name);
  writeFileSync(path, lines.length > 0 ? `${lines.join("\n")}\n` : "");
  return path;
}

describe("the Z Code sessions root", () => {
  it("is where the engine writes its model I/O logs", () => {
    expect(zcodeSessionsRoot("/home/someone")).toBe("/home/someone/.zcode/cli/rollout");
  });
});

describe("the Z Code log file name", () => {
  it("is the engine's own name for the session", () => {
    expect(zcodeSessionFileName(SESSION_ID)).toBe(`model-io-${SESSION_ID}.jsonl`);
  });

  it("keeps the legacy session id form the engine still accepts", () => {
    expect(zcodeSessionFileName("session_abc123")).toBe("model-io-session_abc123.jsonl");
  });

  it("replaces anything the engine's own name would replace", () => {
    // The engine turns every run of other characters into a hyphen, so the
    // reader has to do the same to find the file.
    expect(zcodeSessionFileName("sess_a.b")).toBe("model-io-sess_a-b.jsonl");
  });

  it("cuts the name where the engine cuts it", () => {
    const long = `sess_${"a".repeat(200)}`;
    expect(zcodeSessionFileName(long)).toBe(`model-io-${"sess_".concat("a".repeat(75))}.jsonl`);
  });

  it("holds no dot and no separator, so a crafted id cannot leave the directory", () => {
    for (const id of ["sess_..", "sess_....//....", "session_../.."]) {
      const name = zcodeSessionFileName(id);
      expect(name).not.toContain("/");
      expect(name).not.toContain("..");
    }
  });
});

describe("reading a Z Code session's usage", () => {
  it("reports the engine's own model, provider, tokens and rate", async () => {
    writeLog(`model-io-${SESSION_ID}.jsonl`, [
      record({ outputTokens: 1_395, durationMs: 50_538 }),
    ]);

    const usage = await readZcodeSessionUsage(SESSION_ID, { root });

    expect(usage).not.toBeNull();
    expect(usage?.model).toBe("GLM-5.3-Flash");
    expect(usage?.provider).toBe("account:zai-individual-coding-plan");
    expect(usage?.inputTokens).toBe(154_644);
    expect(usage?.outputTokens).toBe(1_395);
    expect(usage?.totalTokens).toBe(156_039);
    expect(usage?.cacheReadTokens).toBe(0);
    // The rate is the engine's output tokens over the engine's own duration.
    expect(usage?.responseTokensPerSecond).toBeCloseTo(1_395 / 50.538, 6);
    expect(usage?.completionDurationMs).toBe(50_538);
    expect(usage?.updatedAtMs).toBe(Date.parse("2026-11-11T02:32:11.771Z"));
  });

  it("reports the context that was in play, with the cached read already inside it", async () => {
    writeLog(`model-io-${SESSION_ID}.jsonl`, [
      record({ outputTokens: 447, inputTokens: 163_245, cacheReadTokens: 154_624, durationMs: 18_356 }),
    ]);

    const usage = await readZcodeSessionUsage(SESSION_ID, { root });

    expect(usage?.totalTokens).toBe(163_692);
    expect(usage?.cacheReadTokens).toBe(154_624);
    // The cached read is part of the input, so it is never added on top.
    expect(usage?.totalTokens).toBe((usage?.inputTokens ?? 0) + (usage?.outputTokens ?? 0));
  });

  it("never invents a context window", async () => {
    writeLog(`model-io-${SESSION_ID}.jsonl`, [record({ outputTokens: 69, durationMs: 8_399 })]);

    const usage = await readZcodeSessionUsage(SESSION_ID, { root });

    expect(usage?.contextWindow).toBeUndefined();
    expect(usage?.contextUsedTokens).toBeUndefined();
  });

  it("uses the latest response as its basis", async () => {
    writeLog(`model-io-${SESSION_ID}.jsonl`, [record({ outputTokens: 69, durationMs: 8_399 })]);

    const usage = await readZcodeSessionUsage(SESSION_ID, { root });

    expect(usage?.basis).toBe("latest-response");
  });

  it("takes the newest record, not the first one", async () => {
    writeLog(`model-io-${SESSION_ID}.jsonl`, [
      record({ outputTokens: 1_395, durationMs: 50_538 }),
      record({ outputTokens: 447, durationMs: 18_356 }),
    ]);

    const usage = await readZcodeSessionUsage(SESSION_ID, { root });

    expect(usage?.outputTokens).toBe(447);
    expect(usage?.responseTokensPerSecond).toBeCloseTo(24.35, 2);
  });

  it("skips a newer record with no token counts and takes the older one", async () => {
    writeLog(`model-io-${SESSION_ID}.jsonl`, [
      record({ outputTokens: 1_395, durationMs: 50_538 }),
      // A newer record whose usage carries no real counters.
      JSON.stringify({
        type: "model_io",
        sessionId: SESSION_ID,
        durationMs: 900,
        model: { modelId: "GLM-5.3-Flash", providerId: "account:zai-individual-coding-plan" },
        response: { usage: { inputTokens: null, outputTokens: null } },
      }),
    ]);

    const usage = await readZcodeSessionUsage(SESSION_ID, { root });

    // The empty newer record must not hide the real counters below it.
    expect(usage?.outputTokens).toBe(1_395);
    expect(usage?.responseTokensPerSecond).toBeCloseTo(1_395 / 50.538, 6);
  });

  it("skips a malformed record and takes the one before it", async () => {
    writeLog(`model-io-${SESSION_ID}.jsonl`, [
      record({ outputTokens: 447, durationMs: 18_356 }),
      '{"type":"model_io","response":{"usage":{"inputTokens":"many"',
    ]);

    const usage = await readZcodeSessionUsage(SESSION_ID, { root });

    expect(usage?.outputTokens).toBe(447);
  });

  it("refuses a session id that is not Z Code's", async () => {
    writeLog(`model-io-${SESSION_ID}.jsonl`, [record({ outputTokens: 69, durationMs: 8_399 })]);

    for (const id of ["../secrets", "sess_../../etc/passwd", "not-a-zcode-session", "", "sess_a/b"]) {
      expect(await readZcodeSessionUsage(id, { root }), id).toBeNull();
    }
  });

  it("answers null for a session the engine has not logged", async () => {
    expect(await readZcodeSessionUsage("sess_00000000-0000-4000-8000-000000000000", { root })).toBeNull();
  });

  it("reads the last complete record when the engine is still writing the file", async () => {
    const path = writeLog(`model-io-${SESSION_ID}.jsonl`, [
      record({ outputTokens: 1_395, durationMs: 50_538 }),
      record({ outputTokens: 447, durationMs: 18_356 }),
    ]);
    // A half-written last line, as a live append leaves behind.
    appendFileSync(path, '{"type":"model_io","response":{"usage":{"outputTok');

    const usage = await readZcodeSessionUsage(SESSION_ID, { root });

    expect(usage?.outputTokens).toBe(447);
    expect(usage?.responseTokensPerSecond).toBeCloseTo(447 / 18.356, 6);
  });

  it("does not read a log that is a symlink", async () => {
    const real = writeLog("real.jsonl", [record({ outputTokens: 69, durationMs: 8_399 })]);
    symlinkSync(real, join(root, `model-io-${SESSION_ID}.jsonl`));

    expect(await readZcodeSessionUsage(SESSION_ID, { root })).toBeNull();
  });

  it("does not read the file again while it has not changed", async () => {
    const path = writeLog(`model-io-${SESSION_ID}.jsonl`, [record({ outputTokens: 69, durationMs: 8_399 })]);

    const first = await readZcodeSessionUsage(SESSION_ID, { root });
    const second = await readZcodeSessionUsage(SESSION_ID, { root });
    expect(second).toBe(first);

    // The engine wrote more, so the answer is read again.
    appendFileSync(path, `${record({ outputTokens: 120, durationMs: 4_000 })}\n`);
    const third = await readZcodeSessionUsage(SESSION_ID, { root });
    expect(third?.outputTokens).toBe(120);
  });

  it("reads the engine's own file for a legacy session id", async () => {
    writeLog("model-io-session_legacy1.jsonl", [record({ outputTokens: 447, durationMs: 18_356 })]);

    const usage = await readZcodeSessionUsage("session_legacy1", { root });

    expect(usage?.outputTokens).toBe(447);
  });

  it("reads a log the engine named with a replaced character", async () => {
    // The engine writes `sess_a-b.jsonl` for the id `sess_a.b`.
    writeLog("model-io-sess_a-b.jsonl", [record({ outputTokens: 447, durationMs: 18_356 })]);

    const usage = await readZcodeSessionUsage("sess_a.b", { root });

    expect(usage?.outputTokens).toBe(447);
  });
});

describe("a Z Code record", () => {
  it("answers null when it carries no usage", () => {
    expect(zcodeSessionUsage(null)).toBeNull();
    expect(zcodeSessionUsage({})).toBeNull();
    expect(zcodeSessionUsage({ response: { usage: {} } })).toBeNull();
    expect(zcodeSessionUsage({ response: { usage: { inputTokens: "many" } } })).toBeNull();
  });

  it("leaves the rate absent when the engine reported no duration", () => {
    const usage = zcodeSessionUsage({
      response: { usage: { inputTokens: 10, outputTokens: 2, totalTokens: 12 } },
    });
    expect(usage?.responseTokensPerSecond).toBeUndefined();
    expect(usage?.completionDurationMs).toBeUndefined();
  });

  it("reports a token count the engine did not give as not reported", () => {
    const usage = zcodeSessionUsage({
      response: { usage: { outputTokens: 2 } },
    });
    expect(usage?.inputTokensReported).toBe(false);
    expect(usage?.outputTokensReported).toBeUndefined();
  });
});
