import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { applySessionMeta, compactToolHistory, enrichMuseSessionPage } from "../src/web/chat-bridge.ts";
import { findMuseSessionLog, museDisplayTitle, museSessionsRoot, parseMuseSessionLog, readMuseSessionLog, readMuseSessionName, readMuseSessionSummary } from "../src/web/muse-session-log.ts";

const SESSION_ID = "8ec48d4a-e48d-4a49-ae87-f710d028e20c";

function makeRoot(): { root: string; file: string } {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "clutch-muse-session-log-")));
  const folder = join(root, "2026", "10", "21", SESSION_ID);
  mkdirSync(folder, { recursive: true });
  const file = join(folder, "session.jsonl");
  writeFileSync(file, [
    entry("runtime.session.metadata", { record: { model_id: "muse-spark-1.3", provider_id: "muse", workspace_root: "/invented/project" } }, 1),
    userRecord("Synthetic on-disk preview", 2),
  ].join("\n"));
  return { root, file };
}

function entry(payload_type: string, payload: Record<string, unknown>, sequence: number): string {
  return JSON.stringify({ record_type: "event", payload_type, payload, sequence });
}

function userRecord(prompt: string, sequence: number): string {
  return entry("runtime.session", { event: { kind: "user_prompt_display", prompt } }, sequence);
}

function providerUsage(usageId: string, input: number, output: number, reported = true): string {
  return entry("runtime.session", {
    event: {
      kind: "goal_usage_attribution",
      record: {
        usage_id: usageId,
        usage_family: "provider",
        quantity: { unit: "tokens", reported, input_tokens: input, output_tokens: output, cached_tokens: 3 },
      },
    },
  }, 7);
}

describe("Muse session log parser", () => {
  it("reads verified metadata and committed user, assistant, and tool transcript events", () => {
    const contents = [
      entry("runtime.session.metadata", { record: { model_id: "muse-wonder-1.0", provider_id: "muse", workspace_root: "/invented/workspace" } }, 1),
      entry("session.name.changed", { new_name: "Invented title" }, 2),
      userRecord("Invented user text", 3),
      entry("runtime.session", { event: { kind: "assistant_message_committed", text: "Invented assistant text" } }, 4),
      entry("runtime.session", { event: { kind: "assistant_tool_calls_committed", tool_calls: [{ call_id: "call-1", name: "read_file", args: "private args omitted" }] } }, 5),
      entry("runtime.session", { event: { kind: "tool_result_batch_committed", results: [{ tool_call_id: "call-1", tool_call_index: 0, text: "Invented tool result" }] } }, 6),
    ].join("\n");
    const parsed = parseMuseSessionLog(contents, SESSION_ID);

    expect(parsed).toMatchObject({
      sessionId: SESSION_ID,
      modelId: "muse-wonder-1.0",
      providerId: "muse",
      workspaceRoot: "/invented/workspace",
      name: "Invented title",
      truncated: false,
    });
    expect(parsed.transcript).toEqual([
      { sessionId: SESSION_ID, kind: "user_message_chunk", text: "Invented user text" },
      { sessionId: SESSION_ID, kind: "agent_message_chunk", text: "Invented assistant text" },
      { sessionId: SESSION_ID, kind: "tool_call", text: "read_file", toolCallId: "call-1", toolStatus: "running" },
      { sessionId: SESSION_ID, kind: "tool_call_update", text: "Invented tool result", toolCallId: "call-1", toolStatus: "completed", toolOutput: "Invented tool result" },
    ]);
    // The runtime log redacts the arguments of a call, so the parser must
    // not surface them:  there is nothing there to show.
    expect(parsed.transcript.join(" ")).not.toContain("private args omitted");
  });

  it("carries the time the engine recorded and leaves a record with no time alone", () => {
    // The engine writes its log in microseconds, and the time it recorded
    // is the time the message happened:  a replay that shows the time it
    // was read back tells the reader that an old thread happened now.
    const timed = JSON.stringify({
      record_type: "event",
      payload_type: "runtime.session",
      payload: { event: { kind: "assistant_message_committed", text: "Timed text" } },
      sequence: 3,
      recorded_at: 1_793_727_876_526_813,
    });
    const parsed = parseMuseSessionLog([timed, userRecord("Untimed text", 4)].join("\n"), SESSION_ID);

    expect(parsed.transcript[0]?.at).toBe(1_793_727_876_527);
    // A record with no recorded time carries none, rather than one that
    // was made up from the moment it was read.
    expect(parsed.transcript[1]?.at).toBeUndefined();
  });

  it("keeps the tool start and result times separate and does not date untimed replacements", () => {
    const result = (text: string) => ({ kind: "tool_result_batch_committed", results: [{ tool_call_id: "call-1", text }] });
    const timed = (event: object, sequence: number, recorded_at: number) => JSON.stringify({
      payload_type: "runtime.session", payload: { event }, sequence, recorded_at,
    });
    const call = timed({ kind: "assistant_tool_calls_committed", tool_calls: [{ call_id: "call-1", name: "read_file" }] }, 1, 1_793_727_060_000_000);
    const answer = timed(result("First result"), 2, 1_793_727_120_000_000);
    const compact = (...rows: string[]) => compactToolHistory(parseMuseSessionLog(rows.join("\n"), SESSION_ID).transcript);
    expect(compact(call, answer)[0]).toMatchObject({
      at: 1_793_727_060_000, toolResultAt: 1_793_727_120_000, toolOutput: "First result",
    });
    const [updated] = compact(call, answer, entry("runtime.session", { event: result("Replacement") }, 3));
    expect(updated).toMatchObject({ at: 1_793_727_060_000, toolOutput: "Replacement" });
    expect(updated).not.toHaveProperty("toolResultAt");
  });

  it("deduplicates provider usage IDs and excludes estimates and unreported totals", () => {
    const contents = [
      providerUsage("usage-unique", 100, 20),
      providerUsage("usage-unique", 100, 20),
      providerUsage("usage-unreported", 500, 500, false),
      entry("runtime.session", {
        event: {
          kind: "goal_usage_attribution",
          record: { usage_id: "tool-usage", usage_family: "tool", quantity: { unit: "tokens", reported: true, input_tokens: 999, output_tokens: 999 } },
        },
      }, 8),
      JSON.stringify({
        ...JSON.parse(entry("runtime.session", { event: { kind: "model_completed", estimated_prompt_tokens: 9999, duration_ms: 2, usage: { input_tokens: 900, output_tokens: 900 } } }, 9)),
        id: "completion-1",
      }),
      JSON.stringify({
        ...JSON.parse(entry("runtime.session", { event: { kind: "model_completed", duration_ms: 2, usage: { output_tokens: 900 } } }, 10)),
        id: "completion-1",
      }),
    ].join("\n");
    const parsed = parseMuseSessionLog(contents, SESSION_ID);

    expect(parsed.usage).toEqual({
      inputTokens: 100,
      outputTokens: 20,
      cachedTokens: 3,
      totalsComplete: true,
      completionDurationMs: 2,
      responseTokensPerSecond: 450_000,
      responseRateBasis: "whole-response-including-latency",
      generationOnlyTokensPerSecond: null,
      contextOccupancyTokens: null,
      generationTokensPerSecond: null,
      attributionCount: 1,
    });
  });

  it("reads actual retained-frame children and ignores malformed lines", () => {
    const children = [
      { child_index: 0, record_json: JSON.stringify({ record_type: "event", payload_type: "runtime.session.permission_format_declared", payload: { schema_version: 1, format: "Synthetic format" } }) },
      { child_index: 1, record_json: JSON.stringify({ record_type: "event", payload_type: "runtime.session.permission_profile_committed", payload: { schema_version: 1, cause: "fixture", source: { kind: "fixture", id: "synthetic", display_name: "Synthetic" } } }) },
    ];
    const contents = [
      "not-json",
      JSON.stringify({ retained_frame: "session_permission_transaction", children }),
      userRecord("Synthetic following record", 13),
    ].join("\n");
    const parsed = parseMuseSessionLog(contents, SESSION_ID);

    expect(parsed.usage.totalsComplete).toBe(false);
    expect(parsed.transcript).toEqual([
      { sessionId: SESSION_ID, kind: "user_message_chunk", text: "Synthetic following record" },
    ]);
  });

  it("derives the native Muse sessions path from home or absolute XDG_DATA_HOME", () => {
    expect(museSessionsRoot({}, "/synthetic/home")).toBe("/synthetic/home/.local/share/muse/sessions");
    expect(museSessionsRoot({ XDG_DATA_HOME: "/synthetic/data" }, "/ignored/home")).toBe("/synthetic/data/muse/sessions");
    expect(museSessionsRoot({ XDG_DATA_HOME: "relative/data" }, "/synthetic/home")).toBe("/synthetic/home/.local/share/muse/sessions");
    const xdgDataHome = process.env.XDG_DATA_HOME?.trim();
    const nativeDataHome = xdgDataHome?.startsWith("/") ? xdgDataHome : join(homedir(), ".local", "share");
    expect(museSessionsRoot()).toBe(join(nativeDataHome, "muse", "sessions"));
  });

  it("keeps reported zero distinct from a missing usage field", () => {
    const contents = entry("runtime.session", {
      event: { kind: "goal_usage_attribution", record: {
        usage_id: "usage-zero", usage_family: "provider",
        quantity: { unit: "tokens", reported: true, input_tokens: 0 },
      } },
    }, 1);
    const parsed = parseMuseSessionLog(contents, SESSION_ID);
    expect(parsed.usage.inputTokens).toBe(0);
    expect(parsed.usage.outputTokens).toBeUndefined();
    expect(parsed.usage.cachedTokens).toBeUndefined();
  });

  it("marks transcript text and update-budget truncation without changing usage completeness", () => {
    const longText = parseMuseSessionLog(userRecord("x".repeat(8_100), 1), SESSION_ID);
    expect(longText.transcript[0]?.text.length).toBeLessThan(8_100);
    expect(longText.transcriptTruncated).toBe(true);
    expect(longText.truncated).toBe(false);
    expect(longText.usage.totalsComplete).toBe(true);

    const manyUpdates = Array.from({ length: 505 }, (_, index) => userRecord(`message ${index}`, index + 1));
    const bounded = parseMuseSessionLog(manyUpdates.join("\n"), SESSION_ID);
    expect(bounded.transcript).toHaveLength(500);
    expect(bounded.transcript[0]?.text).toBe("message 5");
    expect(bounded.transcript.at(-1)?.text).toBe("message 504");
    expect(bounded.transcriptTruncated).toBe(true);
    expect(bounded.usage.totalsComplete).toBe(true);
  });

  it("bounds bytes and lines and omits malformed or oversized rows", () => {
    const contents = [
      entry("runtime.session", { event: { kind: "assistant_message_committed", text: "kept" } }, 1),
      "x".repeat(260 * 1024),
      entry("runtime.session", { event: { kind: "assistant_message_committed", text: "after byte limit" } }, 2),
    ].join("\n");
    const byBytes = parseMuseSessionLog(contents, SESSION_ID, { maxBytes: 1024 });
    expect(byBytes.truncated).toBe(true);
    expect(byBytes.usage.totalsComplete).toBe(false);
    expect(byBytes.transcript.map((row) => row.text)).toEqual(["kept"]);

    const byLines = parseMuseSessionLog([userRecord("first", 1), userRecord("second", 2)].join("\n"), SESSION_ID, { maxLines: 1 });
    expect(byLines.truncated).toBe(true);
    expect(byLines.transcript.map((row) => row.text)).toEqual(["second"]);

    const withHeadAndTail = parseMuseSessionLog([
      entry("runtime.session.metadata", { record: { model_id: "muse-spark-1.3" } }, 1),
      userRecord("old", 2),
      providerUsage("omitted-usage", 10, 1),
      userRecord("recent user", 4),
      entry("runtime.session", { event: { kind: "assistant_message_committed", text: "latest response" } }, 5),
    ].join("\n"), SESSION_ID, { maxLines: 3 });
    expect(withHeadAndTail.modelId).toBe("muse-spark-1.3");
    expect(withHeadAndTail.transcript.map((row) => row.text)).toEqual(["recent user", "latest response"]);
    expect(withHeadAndTail.truncated).toBe(true);
    expect(withHeadAndTail.usage.totalsComplete).toBe(false);
    expect(withHeadAndTail.transcriptTruncated).toBe(true);
  });
});

describe("Muse session log filesystem reader", () => {
  // The reader resolves the sessions root with realpath, so the fixture root is
  // physical too: on macOS tmpdir() is /var/folders, which is a symlink to
  // /private/var/folders, and an unresolved root makes every expected path
  // differ from the one the reader returns.

  it("locates strict UUID sessions only inside valid date directories and reads bounded metadata", async () => {
    const { root, file } = makeRoot();
    try {
      await expect(findMuseSessionLog(SESSION_ID, root)).resolves.toBe(file);
      await expect(findMuseSessionLog("../session.jsonl", root)).resolves.toBeNull();
      const parsed = await readMuseSessionLog(SESSION_ID, { sessionsRoot: root });
      expect(parsed).toMatchObject({ modelId: "muse-spark-1.3", providerId: "muse", workspaceRoot: "/invented/project" });
      expect(parsed?.transcript[0]?.text).toBe("Synthetic on-disk preview");
      expect(parsed?.usage.totalsComplete).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("returns an empty-transcript summary and marks bounded cumulative usage incomplete", async () => {
    const { root, file } = makeRoot();
    try {
      writeFileSync(file, [
        providerUsage("usage-summary", 8, 2),
        "x".repeat(300 * 1024),
        userRecord("Omitted from summary transcript", 10),
      ].join("\n"));
      const summary = await readMuseSessionSummary(SESSION_ID, { sessionsRoot: root });
      expect(summary?.transcript).toEqual([]);
      expect(summary?.truncated).toBe(true);
      expect(summary?.usage.totalsComplete).toBe(false);
      expect(summary?.usage.inputTokens).toBe(8);
      expect(summary?.modelId).toBeUndefined();
      expect(summary?.transcriptTruncated).toBe(false);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("refreshes a cached compact summary when the source file changes", async () => {
    const { root, file } = makeRoot();
    try {
      const first = await readMuseSessionSummary(SESSION_ID, { sessionsRoot: root });
      expect(first?.transcript).toEqual([]);
      writeFileSync(file, [
        entry("runtime.session.metadata", { record: { model_id: "muse-wonder-1.0", provider_id: "muse", workspace_root: "/invented/project" } }, 1),
        entry("session.name.changed", { new_name: "Updated summary" }, 2),
      ].join("\n"));
      const changed = new Date(Date.now() + 5_000);
      utimesSync(file, changed, changed);
      const second = await readMuseSessionSummary(SESSION_ID, { sessionsRoot: root });
      expect(second?.name).toBe("Updated summary");
      expect(museDisplayTitle(second?.name, "mild-andromeda")).toBe("Updated summary");
      expect(museDisplayTitle(undefined, "mild-andromeda")).toBe("mild-andromeda");
      expect(museDisplayTitle(" ", " ")).toBeUndefined();
      expect(museDisplayTitle(undefined, " generic ")).toBe("generic");
      expect(second?.modelId).toBe("muse-wonder-1.0");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("rejects symlinked session directories and symlinked session files", async () => {
    const { root } = makeRoot();
    const dateDir = join(root, "2026", "10", "21");
    const outside = realpathSync(mkdtempSync(join(tmpdir(), "clutch-muse-session-outside-")));
    const outsideFile = join(outside, "session.jsonl");
    writeFileSync(outsideFile, userRecord("Must not be read", 1));
    try {
      await expect(readMuseSessionSummary(SESSION_ID, { sessionsRoot: root })).resolves.not.toBeNull();
      const sessionDir = join(dateDir, SESSION_ID);
      rmSync(sessionDir, { recursive: true, force: true });
      symlinkSync(outside, sessionDir, "dir");
      await expect(findMuseSessionLog(SESSION_ID, root)).resolves.toBeNull();
      await expect(readMuseSessionSummary(SESSION_ID, { sessionsRoot: root })).resolves.toBeNull();
      rmSync(sessionDir);
      mkdirSync(sessionDir);
      symlinkSync(outsideFile, join(sessionDir, "session.jsonl"));
      await expect(readMuseSessionLog(SESSION_ID, { sessionsRoot: root })).resolves.toBeNull();
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(outside, { recursive: true, force: true });
    }
  });

  it("caps disk reads and returns the known tail rows as a partial preview", async () => {
    const { root, file } = makeRoot();
    try {
      writeFileSync(file, [
        providerUsage("usage-partial", 10, 2),
        "x".repeat(2 * 1024 * 1024 + 100),
        userRecord("Synthetic tail row", 10),
      ].join("\n"));
      const parsed = await readMuseSessionLog(SESSION_ID, { sessionsRoot: root });
      expect(parsed?.truncated).toBe(true);
      expect(parsed?.usage.totalsComplete).toBe(false);
      expect(parsed?.usage.inputTokens).toBe(10);
      expect(parsed?.transcript.some((row) => row.text === "Synthetic tail row")).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});


it("prefers the native Muse name even beyond the usage limit, without a Clutch alias", async () => {
  const rows = Array.from({ length: 51 }, (_, index) => ({ sessionId: String(index), title: "generic-muse" }));
  const visible = applySessionMeta(rows, { version: 1, sessions: { "50": { title: "Old Clutch label" } }, projects: [] }, false, false);
  const log = parseMuseSessionLog(entry("session.name.changed", { new_name: "Muse Code AA: Native Topic" }, 1), "50");
  const summaries: string[] = [];
  const names: string[] = [];
  const result = await enrichMuseSessionPage(visible, async (id) => {
    summaries.push(id);
    return null;
  }, async (id) => {
    names.push(id);
    return log.name;
  });
  expect(summaries).toHaveLength(50);
  expect(names).toEqual(["50"]);
  expect(visible[50]?.title).toBe("generic-muse");
  expect(result[49]?.title).toBe("generic-muse");
  expect(result[50]?.title).toBe("Muse Code AA: Native Topic");
  expect(result[50]?.title).toBe(museDisplayTitle(log.name));
  expect(result[50]?.usage).toBeUndefined();
  await expect(enrichMuseSessionPage([{ sessionId: "untitled", title: "   " }], async () => null))
    .resolves.toEqual([{ sessionId: "untitled" }]);
});


it("reads only a name and invalidates it after a native rename or clear", async () => {
  const { root, file } = makeRoot();
  try {
    const initial = entry("session.name.changed", { new_name: "Native first" }, 1);
    const large = userRecord("x".repeat(80_000), 2);
    writeFileSync(file, [initial, large, entry("session.name.changed", { new_name: "Native latest" }, 3)].join("\n"));
    const options = { sessionsRoot: root };
    await expect(readMuseSessionName(SESSION_ID, options)).resolves.toBe("Native latest");
    await expect(readMuseSessionName(SESSION_ID, options)).resolves.toBe("Native latest");
    writeFileSync(file, [initial, large, entry("session.name.changed", { new_name: " " }, 4)].join("\n"));
    await expect(readMuseSessionName(SESSION_ID, options)).resolves.toBeUndefined();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
