import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { createTurnDiagnostics } from "../src/web/turn-diagnostics.ts";

const temporaryDirectories: string[] = [];

async function makeDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "clutch-turn-diagnostics-"));
  temporaryDirectories.push(directory);
  return directory;
}

function acceptedResponse(init?: RequestInit): Response {
  const body = JSON.parse(String(init?.body)) as { resourceSpans: Array<{ scopeSpans: Array<{ spans: unknown[] }> }> };
  const received = body.resourceSpans[0]?.scopeSpans[0]?.spans.length ?? 0;
  return new Response(JSON.stringify({ ok: true, received, written: received, ignored: 0 }), { status: 200 });
}

afterEach(async () => {
  vi.useRealTimers();
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("turn diagnostics", () => {
  it("clears a prior numeric step code when the terminal error has no code", async () => {
    const directory = await makeDirectory();
    const diagnostics = createTurnDiagnostics({ directory });
    const turn = diagnostics.start({ engine: "muse" });
    turn.record("steer", { outcome: "error", errorCategory: "timeout", errorCode: -32603 });
    turn.record("progress", { phase: "finalizing", outcome: "error", errorCategory: "process", errorCode: null });
    turn.finish("error");
    await diagnostics.flush();
    const span = JSON.parse((await readFile(join(directory, "turn-diagnostics.outbox.jsonl"), "utf8")).trim()) as Record<string, unknown>;
    expect(span).toMatchObject({ outcome: "error", errorCategory: "process" });
    expect(span).not.toHaveProperty("errorCode");
  });

  it("flushes before coalesced progress would exceed the per-record bound", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-11-03T10:00:00Z"));
    const directory = await makeDirectory();
    const diagnostics = createTurnDiagnostics({ directory });
    const turn = diagnostics.start({ engine: "muse" });
    for (let index = 0; index < 3; index += 1) turn.record("progress", { phase: "streaming", count: 800_000 });
    turn.finish("success");
    await diagnostics.flush();
    const rows = (await readFile(join(directory, "turn-diagnostics.jsonl"), "utf8")).split("\n").filter(Boolean).map((line) => JSON.parse(line) as { kind: string; count?: number });
    const counts = rows.filter((row) => row.kind === "progress").map((row) => row.count ?? 0);
    expect(counts.every((count) => count <= 1_000_000)).toBe(true);
    expect(counts.reduce((total, count) => total + count, 0)).toBe(2_400_000);
  });

  it("keeps recovered step failures in local events without marking a successful span as failed", async () => {
    const directory = await makeDirectory();
    const diagnostics = createTurnDiagnostics({ directory });
    const turn = diagnostics.start({ engine: "muse" });
    turn.record("steer", { outcome: "error", errorCategory: "timeout", errorCode: -32603 });
    turn.finish("success");
    await diagnostics.flush();
    const span = JSON.parse((await readFile(join(directory, "turn-diagnostics.outbox.jsonl"), "utf8")).trim()) as Record<string, unknown>;
    expect(span.outcome).toBe("success");
    expect(span).not.toHaveProperty("errorCategory");
    expect(span).not.toHaveProperty("errorCode");
    const rows = (await readFile(join(directory, "turn-diagnostics.jsonl"), "utf8")).split("\n").filter(Boolean).map((line) => JSON.parse(line) as Record<string, unknown>);
    expect(rows.find((row) => row.kind === "steer")).toMatchObject({ errorCode: -32603, errorCategory: "timeout" });
    expect(rows.at(-1)).not.toHaveProperty("errorCode");
  });

  it("coalesces streamed progress while retaining every reported character count", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-11-03T10:00:00Z"));
    const directory = await makeDirectory();
    const diagnostics = createTurnDiagnostics({ directory });
    const turn = diagnostics.start({ engine: "muse" });
    for (let index = 0; index < 10_000; index += 1) turn.record("progress", { phase: "streaming", count: 1 });
    turn.finish("success");
    await diagnostics.flush();
    const rows = (await readFile(join(directory, "turn-diagnostics.jsonl"), "utf8")).split("\n").filter(Boolean).map((line) => JSON.parse(line) as { kind: string; count?: number });
    const progress = rows.filter((row) => row.kind === "progress");
    expect(progress.length).toBeLessThanOrEqual(2);
    expect(progress.reduce((total, row) => total + (row.count ?? 0), 0)).toBe(10_000);
    expect(rows.at(-1)?.kind).toBe("terminal");
  });

  it("writes a mode-600 bounded event log and excludes prompt, tool output, and path fields", async () => {
    const directory = await makeDirectory();
    const diagnostics = createTurnDiagnostics({ directory, maxFileBytes: 10_000 });
    const turn = diagnostics.start({ engine: "muse", provider: "anthropic", model: "muse-spark-1.3" });
    turn.record("progress", { phase: "thinking", outcome: "token=private", prompt: "private prompt", cwd: "/private/worktree" });
    turn.record("tool", { tool: "read_file", output: "private file contents", arguments: { path: "/private/key" } });
    turn.record("permission", { permissionKind: "token=private", outcome: "secret" });
    turn.record("usage", { inputTokens: 30, outputTokens: 7, totalTokens: 37 });
    turn.record("usage", { exactPerTurn: true, inputTokens: 30, outputTokens: 7, totalTokens: 37 });
    expect(turn.finish("success")).toBe(true);
    expect(turn.finish("error", { errorCategory: "internal" })).toBe(false);
    await diagnostics.flush();

    const current = await readFile(join(directory, "turn-diagnostics.jsonl"), "utf8");
    const content = current;
    expect(content).not.toContain("private prompt");
    expect(content).not.toContain("private file contents");
    expect(content).not.toContain("/private/");
    expect(content).toContain('"exactPerTurn":true');
    expect(content).toContain('"kind":"terminal"');
    expect((await stat(join(directory, "turn-diagnostics.jsonl"))).mode & 0o777).toBe(0o600);
    for (let i = 0; i < 80; i += 1) diagnostics.start({ engine: "muse" }).finish("success");
    await diagnostics.flush();
    expect((await stat(join(directory, "turn-diagnostics.jsonl"))).size).toBeLessThanOrEqual(10_000);
    expect((await stat(join(directory, "turn-diagnostics.jsonl.1"))).size).toBeLessThanOrEqual(10_000);
  });

  it("retains failed exports in the bounded outbox and retries them on flush using OTLP JSON", async () => {
    const directory = await makeDirectory();
    let shouldFail = true;
    const fetcher = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if (shouldFail) throw new Error("network failure with secret prompt text");
      return acceptedResponse(init);
    });
    const diagnostics = createTurnDiagnostics({
      directory,
      endpoint: "https://telemetry.invalid/v1/traces",
      authorization: "Bearer supplied-by-caller",
      fetch: fetcher,
      maxOutboxBytes: 16_384,
    });
    const turn = diagnostics.start({ engine: "minimax", provider: "minimax", model: "M3.1" });
    turn.record("usage", { exactPerTurn: true, inputTokens: 11, outputTokens: 5, totalTokens: 16 });
    turn.finish("error", { errorCategory: "process", errorCode: -32603, prompt: "do not export" });
    await diagnostics.flush();

    const outbox = join(directory, "turn-diagnostics.outbox.jsonl");
    const retained = await readFile(outbox, "utf8");
    expect(retained).toContain('"errorCategory":"process"');
    expect(retained).toContain('"errorCode":-32603');
    expect(retained).not.toContain("secret prompt");
    expect(retained).not.toContain("do not export");
    expect((await stat(outbox)).mode & 0o777).toBe(0o600);

    shouldFail = false;
    const restartedDiagnostics = createTurnDiagnostics({
      directory,
      endpoint: "https://telemetry.invalid/v1/traces",
      authorization: "Bearer supplied-by-caller",
      fetch: fetcher,
    });
    await restartedDiagnostics.flush();
    expect(fetcher).toHaveBeenCalledTimes(2);
    const request = fetcher.mock.calls[1];
    expect(request?.[0]).toBe("https://telemetry.invalid/v1/traces");
    expect(request?.[1]?.headers).toEqual({
      "content-type": "application/json",
      authorization: "Bearer supplied-by-caller",
    });
    const body = JSON.parse(String(request?.[1]?.body)) as {
      resourceSpans: Array<{
        resource: { attributes: Array<{ key: string; value: { stringValue?: string } }> };
        scopeSpans: Array<{ spans: Array<{ traceId: string; spanId: string; status: { code: number }; attributes: Array<{ key: string }> }> }>;
      }>;
    };
    const resource = body.resourceSpans[0]?.resource.attributes;
    const span = body.resourceSpans[0]?.scopeSpans[0]?.spans[0];
    expect(resource).toEqual(expect.arrayContaining([
      { key: "service.name", value: { stringValue: "clutch" } },
      { key: "telemetry.sdk.name", value: { stringValue: "clutch" } },
    ]));
    expect(span?.traceId).toMatch(/^[a-f0-9]{32}$/);
    expect(span?.spanId).toMatch(/^[a-f0-9]{16}$/);
    expect(span?.status.code).toBe(2);
    expect(span?.attributes.map(({ key }) => key)).toContain("gen_ai.usage.input_tokens");
    expect(JSON.stringify(span?.attributes)).not.toContain('"error.code"');
    expect(JSON.stringify(span?.attributes)).toContain('"key":"gen_ai.operation.name","value":{"stringValue":"chat"}');
    expect(JSON.stringify(span?.attributes)).toContain('"key":"error.type","value":{"stringValue":"acp.-32603.process"}');
    expect(JSON.stringify(span?.attributes)).toContain('"key":"gen_ai.system","value":{"stringValue":"minimax"}');
    await expect(readFile(outbox, "utf8")).rejects.toThrow();
    expect(await restartedDiagnostics.status()).toMatchObject({ configured: true, pending: 0, lastAcceptedAtMs: expect.any(Number) });
  });

  it("keeps recording local unless endpoint and authorization are both configured", async () => {
    const directory = await makeDirectory();
    const fetcher = vi.fn();
    const diagnostics = createTurnDiagnostics({ directory, endpoint: "https://telemetry.invalid/v1/traces", fetch: fetcher });
    diagnostics.start({ engine: "deepseek" }).finish("cancelled");
    await diagnostics.flush();
    expect(fetcher).not.toHaveBeenCalled();
    expect(await readFile(join(directory, "turn-diagnostics.jsonl"), "utf8")).toContain('"outcome":"cancelled"');
    expect(await diagnostics.status()).toMatchObject({ configured: false, pending: 1 });
  });

  it("requires caller authorization before exporting to a private HTTP endpoint", async () => {
    const directory = await makeDirectory();
    const fetcher = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => acceptedResponse(init));
    const diagnostics = createTurnDiagnostics({
      directory,
      endpoint: "http://127.0.0.1:4318/v1/traces",
      authorization: "Bearer caller-supplied",
      fetch: fetcher,
    });
    diagnostics.start({ engine: "deepseek" }).finish("success");
    await diagnostics.flush();
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(fetcher.mock.calls[0]?.[1]?.headers).toEqual({
      "content-type": "application/json",
      authorization: "Bearer caller-supplied",
    });
  });

  it("keeps latest-response context separate from exact per-turn billing usage", async () => {
    const directory = await makeDirectory();
    const fetcher = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => acceptedResponse(init));
    const diagnostics = createTurnDiagnostics({
      directory,
      endpoint: "https://telemetry.invalid/v1/traces",
      authorization: "Bearer caller-supplied",
      fetch: fetcher,
    });
    const turn = diagnostics.start({ engine: "muse" });
    turn.record("metadata", {
      model: "muse-wonder-1.0",
      provider: "muse",
      sessionId: "7ef4d9e2-c220-4abc-9e12-9a1ac93d2310",
      cwd: "/private/worktree",
    });
    turn.record("context", {
      basis: "latest-response",
      inputTokens: 100,
      outputTokens: 10,
      totalTokens: 110,
      contextWindow: 200_000,
      updatedAtMs: 1_800_000_000_000,
      rawResponse: "private response",
    });
    turn.record("tool", { tool: "search", toolType: "function", status: "success", arguments: "private args" });
    turn.finish("success");
    await diagnostics.flush();

    const body = String(fetcher.mock.calls[0]?.[1]?.body);
    expect(body).not.toContain("/private/worktree");
    expect(body).not.toContain("private response");
    expect(body).toContain('"context.tokens"');
    expect(body).toContain('"context.limit"');
    expect(body).not.toContain('"gen_ai.usage.input_tokens"');
    expect(body).not.toContain('"gen_ai.usage.output_tokens"');
    expect(body).toContain('"session.id"');
    expect(body).not.toContain('"key":"gen_ai.system"');
    expect(body).toContain('"key":"gen_ai.provider.name"');
    expect(body).toContain('"gen_ai.tool.name"');
    expect(body).toContain('"gen_ai.tool.status"');
    expect(body).not.toContain("private args");
  });

  it("exports reported engine context without creating billable token usage", async () => {
    const directory = await makeDirectory();
    const fetcher = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => acceptedResponse(init));
    const diagnostics = createTurnDiagnostics({ directory, endpoint: "https://telemetry.invalid/v1/traces",
      authorization: "Bearer caller-supplied", fetch: fetcher });
    const turn = diagnostics.start({ engine: "muse" });
    turn.record("context", { basis: "engine-context", totalTokens: 125, contextWindow: 100, prompt: "private prompt" });
    turn.finish("success");
    await diagnostics.flush();
    const body = String(fetcher.mock.calls[0]?.[1]?.body);
    expect(body).toContain('"key":"clutch.context.basis","value":{"stringValue":"engine-context"}');
    expect(body).toContain('"key":"context.tokens","value":{"intValue":"125"}');
    expect(body).toContain('"key":"context.utilization_pct","value":{"intValue":"125"}');
    expect(body).not.toContain("gen_ai.usage.");
    expect(body).not.toContain("private prompt");
    expect(await diagnostics.status()).toMatchObject({ pending: 0 });
  });

  it("records session snapshots as nonbillable custom metrics and preserves measured zero", async () => {
    const directory = await makeDirectory();
    const fetcher = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => acceptedResponse(init));
    const diagnostics = createTurnDiagnostics({
      directory,
      endpoint: "https://telemetry.invalid/v1/traces",
      authorization: "Bearer caller-supplied",
      fetch: fetcher,
    });
    const turn = diagnostics.start({ engine: "muse", sessionId: "7ef4d9e2-c220-4abc-9e12-9a1ac93d2310" });
    turn.record("metrics", {
      snapshotBasis: "session-snapshot",
      totalsComplete: false,
      recordedInputTokens: 0,
      recordedOutputTokens: 17,
      cachedTokens: 0,
      responseTokensPerSecond: 2.5,
      completionDurationMs: 1200,
      exactPerTurn: true,
      inputTokens: 999,
      outputTokens: 999,
      prompt: "private prompt text",
      rawUsage: { secret: "private payload" },
    });
    turn.finish("success");
    await diagnostics.flush();

    const rows = (await readFile(join(directory, "turn-diagnostics.jsonl"), "utf8"))
      .split("\n").filter(Boolean).map((line) => JSON.parse(line) as Record<string, unknown>);
    const metrics = rows.find((row) => row.kind === "metrics");
    expect(metrics).toMatchObject({
      snapshotBasis: "session-snapshot",
      totalsComplete: false,
      recordedInputTokens: 0,
      recordedOutputTokens: 17,
      cachedTokens: 0,
      responseTokensPerSecond: 2.5,
      completionDurationMs: 1200,
    });
    expect(metrics).not.toHaveProperty("exactPerTurn");
    expect(metrics).not.toHaveProperty("inputTokens");
    expect(JSON.stringify(rows)).not.toContain("private prompt text");
    expect(JSON.stringify(rows)).not.toContain("private payload");

    const spans = fetcher.mock.calls.flatMap((call) => {
      const body = JSON.parse(String(call[1]?.body)) as {
        resourceSpans: Array<{ scopeSpans: Array<{ spans: Array<{ name: string; attributes: Array<{ key: string; value: Record<string, unknown> }> }> }> }>;
      };
      return body.resourceSpans.flatMap((resource) => resource.scopeSpans.flatMap((scope) => scope.spans));
    });
    expect(spans).toHaveLength(2);
    const snapshotSpan = spans.find((span) => span.name === "session.snapshot");
    expect(snapshotSpan).toBeDefined();
    const attrs = snapshotSpan?.attributes ?? [];
    const values = new Map(attrs.map(({ key, value }) => [key, value]));
    expect(values.get("clutch.metrics.basis")).toEqual({ stringValue: "session-snapshot" });
    expect(values.get("clutch.metrics.totals_complete")).toEqual({ boolValue: false });
    expect(values.get("clutch.session.input_tokens")).toEqual({ intValue: "0" });
    expect(values.get("clutch.session.output_tokens")).toEqual({ intValue: "17" });
    expect(values.get("clutch.session.cached_tokens")).toEqual({ intValue: "0" });
    expect(values.get("clutch.response.tokens_per_second")).toEqual({ doubleValue: 2.5 });
    expect(values.get("clutch.response.duration_ms")).toEqual({ intValue: "1200" });
    expect(attrs.some(({ key }) => key.startsWith("gen_ai."))).toBe(false);
    expect(attrs.some(({ key }) => key.startsWith("gen_ai.usage."))).toBe(false);
    expect(JSON.stringify(attrs)).not.toContain("exactPerTurn");
    expect(JSON.stringify(attrs)).not.toContain("private prompt text");
  });

  it("drops malformed snapshot fields and refuses records without the session-snapshot basis", async () => {
    const directory = await makeDirectory();
    const diagnostics = createTurnDiagnostics({ directory });
    const turn = diagnostics.start({ engine: "muse" });
    turn.record("metrics", { snapshotBasis: "latest-response", totalsComplete: true, recordedInputTokens: 5 });
    turn.record("metrics", {
      snapshotBasis: "session-snapshot",
      totalsComplete: true,
      recordedInputTokens: -1,
      recordedOutputTokens: 1_000_000_001,
      cachedTokens: 2,
      responseTokensPerSecond: Number.POSITIVE_INFINITY,
      completionDurationMs: -10,
      summary: "do not store this text",
      error: "do not store this error",
    });
    turn.finish("success");
    await diagnostics.flush();

    const rows = (await readFile(join(directory, "turn-diagnostics.jsonl"), "utf8"))
      .split("\n").filter(Boolean).map((line) => JSON.parse(line) as Record<string, unknown>);
    const metrics = rows.filter((row) => row.kind === "metrics");
    expect(metrics).toHaveLength(1);
    expect(metrics[0]).toMatchObject({ snapshotBasis: "session-snapshot", totalsComplete: true, cachedTokens: 2 });
    expect(metrics[0]).not.toHaveProperty("recordedInputTokens");
    expect(metrics[0]).not.toHaveProperty("recordedOutputTokens");
    expect(metrics[0]).not.toHaveProperty("responseTokensPerSecond");
    expect(metrics[0]).not.toHaveProperty("completionDurationMs");
    expect(JSON.stringify(rows)).not.toContain("do not store");
  });

  it("records only allowlisted compaction status, never compaction identity or content", async () => {
    const directory = await makeDirectory();
    const fetcher = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => acceptedResponse(init));
    const diagnostics = createTurnDiagnostics({
      directory,
      endpoint: "https://telemetry.invalid/v1/traces",
      authorization: "Bearer caller-supplied",
      fetch: fetcher,
    });
    const turn = diagnostics.start({ engine: "muse" });
    turn.record("compaction", {
      status: "completed",
      compactionId: "private-compaction-id",
      summary: [{ type: "text", text: "private compacted summary" }],
      error: "private compaction error",
      command: "/compact",
      prompt: "private prompt",
    });
    turn.record("compaction", { status: "unexpected secret status" });
    turn.finish("success");
    await diagnostics.flush();

    const rows = (await readFile(join(directory, "turn-diagnostics.jsonl"), "utf8"))
      .split("\n").filter(Boolean).map((line) => JSON.parse(line) as Record<string, unknown>);
    expect(rows.filter((row) => row.kind === "compaction").map((row) => row.compactionStatus)).toEqual(["completed", "unknown"]);
    const body = String(fetcher.mock.calls[0]?.[1]?.body);
    expect(body).toContain('"key":"clutch.compaction.status","value":{"stringValue":"unknown"}');
    expect(body).not.toContain("private-compaction-id");
    expect(body).not.toContain("private compacted summary");
    expect(body).not.toContain("private compaction error");
    expect(body).not.toContain("/compact");
    expect(body).not.toContain("private prompt");
  });

  it("reports bounded pending state and backs off failed transport without retrying each event", async () => {
    const directory = await makeDirectory();
    const fetcher = vi.fn(async () => { throw new Error("private network error"); });
    const diagnostics = createTurnDiagnostics({
      directory,
      endpoint: "https://telemetry.invalid/v1/traces",
      authorization: "Bearer private-auth",
      fetch: fetcher,
    });
    const turn = diagnostics.start({ engine: "muse" });
    turn.finish("error", { errorCategory: "network", errorCode: -32603 });
    await diagnostics.flush();
    const firstStatus = await diagnostics.status();
    expect(firstStatus).toMatchObject({ configured: true, pending: 1, droppedEvents: 0, localWriteFailures: 0 });
    expect(firstStatus.lastFailureAtMs).not.toBeNull();

    for (let i = 0; i < 20; i += 1) diagnostics.start({ engine: "muse" }).record("progress", { phase: "streaming" });
    await diagnostics.flush();
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(await diagnostics.status())).not.toContain("private-auth");
    expect(JSON.stringify(await diagnostics.status())).not.toContain("telemetry.invalid");
  });

  it("exports no more than 32 completed spans per HTTP request", async () => {
    const directory = await makeDirectory();
    const batchSizes: number[] = [];
    const fetcher = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body)) as { resourceSpans: Array<{ scopeSpans: Array<{ spans: unknown[] }> }> };
      batchSizes.push(body.resourceSpans[0]?.scopeSpans[0]?.spans.length ?? 0);
      return acceptedResponse(init);
    });
    const diagnostics = createTurnDiagnostics({
      directory,
      endpoint: "https://telemetry.invalid/v1/traces",
      authorization: "Bearer caller-supplied",
      fetch: fetcher,
    });
    for (let i = 0; i < 35; i += 1) diagnostics.start({ engine: "muse" }).finish("success");
    await diagnostics.flush();
    expect(batchSizes.length).toBeGreaterThan(0);
    expect(batchSizes.every((size) => size > 0 && size <= 32)).toBe(true);
    expect(batchSizes.reduce((total, size) => total + size, 0)).toBe(35);
  });

  it("retains the outbox when a hub returns HTTP 200 with partial OTLP rejection", async () => {
    const directory = await makeDirectory();
    const fetcher = vi.fn(async () => new Response(JSON.stringify({
      partialSuccess: { rejectedSpans: 1, errorMessage: "one span rejected" },
    }), { status: 200 }));
    const diagnostics = createTurnDiagnostics({
      directory,
      endpoint: "https://telemetry.invalid/v1/traces",
      authorization: "Bearer caller-supplied",
      fetch: fetcher,
    });
    diagnostics.start({ engine: "muse" }).finish("success");
    await diagnostics.flush();
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(await diagnostics.status()).toMatchObject({ pending: 1, lastFailureAtMs: expect.any(Number) });
    expect(JSON.stringify(await diagnostics.status())).not.toContain("one span rejected");
  });
});
