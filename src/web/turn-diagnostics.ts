import { randomUUID } from "node:crypto";
import { mkdir, open, readFile, rename, stat, unlink, writeFile } from "node:fs/promises";
import { isIP } from "node:net";
import { join } from "node:path";
import { z } from "zod";

export type TurnDiagnosticKind = "metadata" | "progress" | "tool" | "plan" | "context" | "usage" | "steer" | "permission";
export type TurnOutcome = "success" | "error" | "cancelled" | "stopped" | "unknown";

export interface TurnDiagnosticsOptions {
  directory: string;
  endpoint?: string;
  authorization?: string;
  fetch?: typeof globalThis.fetch;
  maxFileBytes?: number;
  maxOutboxBytes?: number;
  maxQueuedBytes?: number;
}

export interface TurnDiagnosticIdentity {
  engine: string;
  model?: string;
  provider?: string;
  sessionId?: string;
}

export interface TurnDiagnosticHandle {
  readonly turnId: string;
  record(kind: TurnDiagnosticKind, details?: Record<string, unknown>): void;
  finish(outcome: TurnOutcome, details?: Record<string, unknown>): boolean;
}

export interface TurnDiagnostics {
  start(identity: TurnDiagnosticIdentity): TurnDiagnosticHandle;
  flush(): Promise<void>;
  status(): Promise<TurnDiagnosticsStatus>;
}

export interface TurnDiagnosticsStatus {
  configured: boolean;
  pending: number;
  lastAcceptedAtMs: number | null;
  lastFailureAtMs: number | null;
  droppedEvents: number;
  localWriteFailures: number;
}

interface SafeEvent {
  at: string;
  turnId: string;
  traceId: string;
  kind: TurnDiagnosticKind | "start" | "terminal";
  engine: string;
  model?: string;
  provider?: string;
  sessionId?: string;
  outcome?: string;
  phase?: string;
  tool?: string;
  toolType?: string;
  toolStatus?: string;
  permissionKind?: string;
  errorCategory?: string;
  errorCode?: number;
  durationMs?: number;
  count?: number;
  stepCount?: number;
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  totalTokens?: number;
  exactPerTurn?: true;
  contextBasis?: "latest-response";
  contextWindow?: number;
  updatedAtMs?: number;
}

interface CompletedSpan {
  traceId: string;
  spanId: string;
  startNs: string;
  endNs: string;
  durationMs: number;
  engine: string;
  model?: string;
  provider?: string;
  sessionId?: string;
  outcome: TurnOutcome;
  errorCategory?: string;
  errorCode?: number;
  usage?: Pick<SafeEvent, "inputTokens" | "outputTokens" | "cacheReadTokens" | "cacheWriteTokens" | "totalTokens">;
  toolStatus?: string;
  toolName?: string;
  toolType?: string;
  context?: Pick<SafeEvent, "inputTokens" | "outputTokens" | "cacheReadTokens" | "totalTokens" | "contextWindow" | "updatedAtMs" | "contextBasis">;
}

const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/;
const CATEGORY = /^(?:auth|session-in-use|timeout|process|rate-limit|internal|network|permission|unknown)$/;
const AI_VENDORS = new Set(["openai", "anthropic", "google", "aws.bedrock", "azure.ai.openai", "mistral_ai", "cohere", "deepseek", "minimax", "xai", "meta", "groq", "together_ai", "openrouter"]);
const PROGRESS_PHASES = new Set(["starting", "thinking", "streaming", "tool", "plan", "waiting", "permission", "steering", "finalizing", "unknown"]);
const EVENT_OUTCOMES = new Set(["success", "error", "cancelled", "stopped", "unknown", "running", "completed", "failed", "denied", "approved", "pending", "skipped"]);
const PERMISSION_KINDS = new Set(["tool", "file", "filesystem", "shell", "network", "approval", "unknown"]);
const TOOL_STATUSES = new Set(["success", "error", "failed", "denied", "approved", "pending", "cancelled", "skipped", "running", "completed", "unknown"]);
const TOOL_TYPES = new Set(["function", "command", "mcp", "built-in", "unknown"]);
const ALLOWED_OUTCOMES = new Set<TurnOutcome>(["success", "error", "cancelled", "stopped", "unknown"]);
const DEFAULT_FILE_BYTES = 512 * 1024;
const DEFAULT_OUTBOX_BYTES = 512 * 1024;
const DEFAULT_QUEUED_BYTES = 256 * 1024;
const SafeIdentifierSchema = z.string().regex(IDENTIFIER).refine((value) => !/^(?:sk[-_]|bearer|password|secret[-_])/i.test(value));
const SafeSessionIdSchema = z.string().regex(/^(?:[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}|[a-f0-9]{16,64})$/i);
const SafeCountsSchema = z.object({
  inputTokens: z.number().int().nonnegative().max(1_000_000_000).optional(),
  outputTokens: z.number().int().nonnegative().max(1_000_000_000).optional(),
  cacheReadTokens: z.number().int().nonnegative().max(1_000_000_000).optional(),
  cacheWriteTokens: z.number().int().nonnegative().max(1_000_000_000).optional(),
  totalTokens: z.number().int().nonnegative().max(1_000_000_000).optional(),
}).strict();
const SafeContextSchema = SafeCountsSchema.extend({
  contextWindow: z.number().int().nonnegative().max(1_000_000_000).optional(),
  updatedAtMs: z.number().int().nonnegative().max(8_640_000_000_000_000).optional(),
  contextBasis: z.literal("latest-response"),
}).strict();
const CompletedSpanSchema = z.object({
  traceId: z.string().regex(/^[a-f0-9]{32}$/),
  spanId: z.string().regex(/^[a-f0-9]{16}$/),
  startNs: z.string().regex(/^\d{1,24}$/),
  endNs: z.string().regex(/^\d{1,24}$/),
  durationMs: z.number().int().nonnegative().max(7 * 24 * 60 * 60 * 1000),
  engine: SafeIdentifierSchema,
  model: SafeIdentifierSchema.optional(),
  provider: SafeIdentifierSchema.optional(),
  sessionId: SafeSessionIdSchema.optional(),
  outcome: z.enum(["success", "error", "cancelled", "stopped", "unknown"]),
  errorCategory: z.string().regex(CATEGORY).optional(),
  errorCode: z.number().int().min(-2_147_483_648).max(2_147_483_647).optional(),
  usage: SafeCountsSchema.optional(),
  toolStatus: z.enum(["success", "error", "failed", "denied", "approved", "pending", "cancelled", "skipped", "running", "completed", "unknown"]).optional(),
  toolName: SafeIdentifierSchema.optional(),
  toolType: z.enum(["function", "command", "mcp", "built-in", "unknown"]).optional(),
  context: SafeContextSchema.optional(),
}).strict();
const ReceiverAckSchema = z.object({
  ok: z.boolean().optional(),
  received: z.number().int().nonnegative().optional(),
  ignored: z.number().int().nonnegative().optional(),
  written: z.number().int().nonnegative().optional(),
  partialSuccess: z.object({
    rejectedSpans: z.number().int().nonnegative().optional(),
    errorMessage: z.string().optional(),
  }).optional(),
}).passthrough();

function identifier(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const clean = value.trim();
  return SafeIdentifierSchema.safeParse(clean).success ? clean : undefined;
}

function safeSessionId(value: unknown): string | undefined {
  const parsed = SafeSessionIdSchema.safeParse(value);
  return parsed.success ? parsed.data.toLowerCase() : undefined;
}

function boundedInteger(value: unknown, max = Number.MAX_SAFE_INTEGER): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= max ? value : undefined;
}

function signedErrorCode(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= -2_147_483_648 && value <= 2_147_483_647 ? value : undefined;
}

function safeDetail(kind: TurnDiagnosticKind, details: Record<string, unknown> | undefined): Partial<SafeEvent> {
  if (!details) return {};
  const out: Partial<SafeEvent> = {};
  if (kind === "metadata") {
    const model = identifier(details.model);
    const provider = identifier(details.provider);
    const sessionId = safeSessionId(details.sessionId);
    if (model) out.model = model;
    if (provider) out.provider = provider;
    if (sessionId) out.sessionId = sessionId;
    return out;
  }
  if (typeof details.outcome === "string" && EVENT_OUTCOMES.has(details.outcome)) out.outcome = details.outcome;
  const durationMs = boundedInteger(details.durationMs, 7 * 24 * 60 * 60 * 1000);
  if (durationMs !== undefined) out.durationMs = durationMs;
  switch (kind) {
    case "progress": {
      const phase = typeof details.phase === "string" && PROGRESS_PHASES.has(details.phase) ? details.phase : undefined;
      const count = boundedInteger(details.count, 1_000_000);
      if (phase) out.phase = phase;
      if (count !== undefined) out.count = count;
      break;
    }
    case "tool": {
      const tool = identifier(details.tool);
      const toolType = typeof details.toolType === "string" && TOOL_TYPES.has(details.toolType) ? details.toolType : undefined;
      const status = typeof details.status === "string" ? details.status : details.outcome;
      const toolStatus = typeof status === "string" && TOOL_STATUSES.has(status) ? status : undefined;
      if (tool) out.tool = tool;
      if (toolType) out.toolType = toolType;
      if (toolStatus) out.toolStatus = toolStatus;
      break;
    }
    case "plan": {
      const stepCount = boundedInteger(details.stepCount, 1_000_000);
      if (stepCount !== undefined) out.stepCount = stepCount;
      break;
    }
    case "usage": {
      if (details.exactPerTurn !== true) break;
      out.exactPerTurn = true;
      for (const key of ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "totalTokens"] as const) {
        const value = boundedInteger(details[key], 1_000_000_000);
        if (value !== undefined) out[key] = value;
      }
      break;
    }
    case "context": {
      if (details.basis !== "latest-response") break;
      out.contextBasis = "latest-response";
      for (const key of ["inputTokens", "outputTokens", "cacheReadTokens", "totalTokens"] as const) {
        const value = boundedInteger(details[key], 1_000_000_000);
        if (value !== undefined) out[key] = value;
      }
      const contextWindow = boundedInteger(details.contextWindow, 1_000_000_000);
      const updatedAtMs = boundedInteger(details.updatedAtMs, 8_640_000_000_000_000);
      if (contextWindow !== undefined) out.contextWindow = contextWindow;
      if (updatedAtMs !== undefined) out.updatedAtMs = updatedAtMs;
      break;
    }
    case "steer":
      break;
    case "permission": {
      const permissionKind = typeof details.permissionKind === "string" && PERMISSION_KINDS.has(details.permissionKind) ? details.permissionKind : undefined;
      if (permissionKind) out.permissionKind = permissionKind;
      break;
    }
  }
  if (details.errorCategory !== undefined && typeof details.errorCategory === "string" && CATEGORY.test(details.errorCategory)) {
    out.errorCategory = details.errorCategory;
  }
  const errorCode = signedErrorCode(details.errorCode);
  if (errorCode !== undefined) out.errorCode = errorCode;
  return out;
}

function attributes(values: Array<[string, string | number | boolean | undefined]>): Array<{ key: string; value: Record<string, unknown> }> {
  return values.flatMap(([key, value]) => value === undefined ? [] : [{
    key,
    value: typeof value === "string" ? { stringValue: value } : typeof value === "boolean" ? { boolValue: value } : Number.isInteger(value) ? { intValue: String(value) } : { doubleValue: value },
  }]);
}

function allAcceptedAcknowledgement(value: unknown, expected: number): boolean {
  const parsed = ReceiverAckSchema.safeParse(value);
  if (!parsed.success || parsed.data.ok === false) return false;
  const ack = parsed.data;
  if (ack.partialSuccess && ((ack.partialSuccess.rejectedSpans ?? 0) > 0 || Boolean(ack.partialSuccess.errorMessage))) return false;
  const hasCounts = ack.received !== undefined || ack.written !== undefined || ack.ignored !== undefined;
  if (hasCounts) return ack.received === expected && ack.written === expected && ack.ignored === 0;
  return ack.partialSuccess !== undefined && (ack.partialSuccess.rejectedSpans ?? 0) === 0 && !ack.partialSuccess.errorMessage;
}

function makeOtlp(spans: CompletedSpan[]): unknown {
  const encodedSpans = spans.map((span) => {
    const vendor = span.provider?.toLowerCase();
    const contextUtilization = span.context?.contextWindow && span.context.totalTokens !== undefined
      ? span.context.totalTokens / span.context.contextWindow * 100
      : undefined;
    const attrs = attributes([
      ["agent.platform", "clutch"],
      ["gen_ai.agent.name", span.engine],
      ["gen_ai.provider.name", span.provider],
      ...(vendor && AI_VENDORS.has(vendor) ? [["gen_ai.system", vendor] as [string, string]] : []),
      ["gen_ai.operation.name", "chat"],
      ["gen_ai.request.model", span.model],
      ["session.id", span.sessionId],
      ["duration_ms", span.durationMs],
      ["error.type", span.errorCode !== undefined ? `acp.${span.errorCode}.${span.errorCategory ?? "internal"}` : span.errorCategory],
      ["gen_ai.tool.name", span.toolName],
      ["gen_ai.tool.type", span.toolType],
      ["gen_ai.tool.status", span.toolStatus],
      ["gen_ai.usage.input_tokens", span.usage?.inputTokens],
      ["gen_ai.usage.output_tokens", span.usage?.outputTokens],
      ["gen_ai.usage.cache_read_input_tokens", span.usage?.cacheReadTokens],
      ["gen_ai.usage.cache_creation_input_tokens", span.usage?.cacheWriteTokens],
      ["context.tokens", span.context?.totalTokens],
      ["context.limit", span.context?.contextWindow],
      ["context.utilization_pct", contextUtilization],
    ]);
    return {
      traceId: span.traceId,
      spanId: span.spanId,
      name: "chat",
      kind: 1,
      startTimeUnixNano: span.startNs,
      endTimeUnixNano: span.endNs,
      attributes: attrs,
      status: { code: span.outcome === "error" ? 2 : 1 },
    };
  });
  return {
    resourceSpans: [{
      resource: { attributes: attributes([["service.name", "clutch"], ["telemetry.sdk.name", "clutch"]]) },
      scopeSpans: [{
        scope: { name: "clutch.turn-diagnostics" },
        spans: encodedSpans,
      }],
    }],
  };
}

function timestampNs(date: Date): string {
  return (BigInt(date.getTime()) * 1_000_000n).toString();
}

function validEndpoint(endpoint: unknown): endpoint is string {
  if (typeof endpoint !== "string" || endpoint.length > 2048) return false;
  try {
    const url = new URL(endpoint);
    if ((url.protocol !== "http:" && url.protocol !== "https:") || url.username || url.password || url.search || url.hash) return false;
    if (url.protocol === "https:") return true;
    const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
    if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".ts.net")) return true;
    if (isIP(host) === 4) {
      const octets = host.split(".").map(Number);
      return (octets[0] === 127) || (octets[0] === 100 && octets[1]! >= 64 && octets[1]! <= 127);
    }
    if (isIP(host) === 6) return host === "::1" || host.startsWith("fd7a:115c:a1e0:");
    return false;
  } catch {
    return false;
  }
}

export function createTurnDiagnostics(options: TurnDiagnosticsOptions): TurnDiagnostics {
  const maxFileBytes = boundedInteger(options.maxFileBytes) ?? DEFAULT_FILE_BYTES;
  const maxOutboxBytes = boundedInteger(options.maxOutboxBytes) ?? DEFAULT_OUTBOX_BYTES;
  const maxQueuedBytes = boundedInteger(options.maxQueuedBytes) ?? DEFAULT_QUEUED_BYTES;
  const logPath = join(options.directory, "turn-diagnostics.jsonl");
  const outboxPath = join(options.directory, "turn-diagnostics.outbox.jsonl");
  const fetcher = options.fetch ?? globalThis.fetch;
  const configuredEndpoint = validEndpoint(options.endpoint) ? options.endpoint : undefined;
  const configuredAuthorization = typeof options.authorization === "string" && options.authorization.trim().length > 0 && options.authorization.length <= 4096 ? options.authorization : undefined;
  const configured = Boolean(configuredEndpoint && configuredAuthorization && typeof fetcher === "function");
  let writeChain = Promise.resolve();
  let queuedBytes = 0;
  let flushChain: Promise<void> | undefined;
  let flushRequested = false;
  let retryDelayMs = 5_000;
  let nextRetryAtMs = 0;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;
  let lastAcceptedAtMs: number | null = null;
  let lastFailureAtMs: number | null = null;
  let droppedEvents = 0;
  let localWriteFailures = 0;

  const enqueueWrite = (line: string, outbox = false): void => {
    const bytes = Buffer.byteLength(line);
    if (queuedBytes + bytes > maxQueuedBytes) {
      droppedEvents += 1;
      return;
    }
    queuedBytes += bytes;
    writeChain = writeChain.then(async () => {
      await mkdir(options.directory, { recursive: true, mode: 0o700 });
      const file = outbox ? outboxPath : logPath;
      const max = outbox ? maxOutboxBytes : maxFileBytes;
      if (bytes > max) {
        droppedEvents += 1;
        return;
      }
      const existing = await stat(file).then((result) => result.size).catch(() => 0);
      if (existing + bytes > max) {
        if (outbox) {
          const old = await readFile(file, "utf8").catch(() => "");
          const kept = old.split("\n").filter(Boolean);
          kept.push(line.trimEnd());
          let body = kept.join("\n") + "\n";
          while (Buffer.byteLength(body) > max && kept.length > 1) {
            kept.shift();
            droppedEvents += 1;
            body = kept.join("\n") + "\n";
          }
          await writeFile(file, body, { mode: 0o600 });
          const handle = await open(file, "r");
          await handle.chmod(0o600);
          await handle.close();
        } else {
          const previous = `${file}.1`;
          await unlink(previous).catch(() => undefined);
          await rename(file, previous).catch(() => undefined);
          await writeFile(file, line, { mode: 0o600 });
          const handle = await open(file, "r");
          await handle.chmod(0o600);
          await handle.close();
        }
      } else {
        const handle = await open(file, "a", 0o600);
        try {
          await handle.chmod(0o600);
          await handle.writeFile(line);
        } finally {
          await handle.close();
        }
      }
    }).catch(() => {
      localWriteFailures += 1;
      droppedEvents += 1;
    }).finally(() => { queuedBytes = Math.max(0, queuedBytes - bytes); });
  };

  const rewriteOutbox = (successfulKeys: Set<string>): Promise<void> => {
    const rewrite = writeChain.then(async () => {
      const current = (await readFile(outboxPath, "utf8").catch(() => "")).split("\n").filter(Boolean);
      const retained = current.filter((row) => {
        try {
          const parsed = CompletedSpanSchema.safeParse(JSON.parse(row) as unknown);
          if (!parsed.success) {
            droppedEvents += 1;
            return false;
          }
          return !successfulKeys.has(`${parsed.data.traceId}:${parsed.data.spanId}`);
        } catch {
          droppedEvents += 1;
          return false;
        }
      });
      let body = retained.join("\n");
      if (body) body += "\n";
      while (Buffer.byteLength(body) > maxOutboxBytes && retained.length > 1) {
        retained.shift();
        body = retained.join("\n");
        if (body) body += "\n";
        droppedEvents += 1;
      }
      if (body) {
        const temporary = `${outboxPath}.tmp`;
        await writeFile(temporary, body, { mode: 0o600 });
        const handle = await open(temporary, "r");
        await handle.chmod(0o600);
        await handle.close();
        await rename(temporary, outboxPath);
      } else {
        await unlink(outboxPath).catch(() => undefined);
      }
    }).catch(() => { localWriteFailures += 1; });
    writeChain = rewrite;
    return rewrite;
  };

  const scheduleRetry = (): void => {
    if (retryTimer) clearTimeout(retryTimer);
    const delay = retryDelayMs;
    nextRetryAtMs = Date.now() + delay;
    retryDelayMs = Math.min(60_000, retryDelayMs * 2);
    retryTimer = setTimeout(() => {
      retryTimer = undefined;
      void flush();
    }, delay);
    retryTimer.unref();
  };

  const flushOutbox = async (): Promise<boolean> => {
    if (!configured || !configuredEndpoint || !configuredAuthorization || typeof fetcher !== "function") return true;
    await writeChain;
    const rows = (await readFile(outboxPath, "utf8").catch(() => "")).split("\n").filter(Boolean);
    const spans: CompletedSpan[] = [];
    for (const row of rows) {
      try {
        const parsed = CompletedSpanSchema.safeParse(JSON.parse(row) as unknown);
        if (parsed.success) spans.push(parsed.data as CompletedSpan);
        else droppedEvents += 1;
      } catch {
        droppedEvents += 1;
      }
    }
    const batch = spans.slice(0, 32);
    if (!batch.length) {
      if (rows.length) await rewriteOutbox(new Set());
      return true;
    }

    let accepted = false;
    try {
      const response = await fetcher(configuredEndpoint, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: configuredAuthorization },
        body: JSON.stringify(makeOtlp(batch)),
        signal: AbortSignal.timeout(3_000),
        redirect: "error",
      });
      let acknowledgement: unknown;
      try { acknowledgement = await response.json() as unknown; } catch { acknowledgement = undefined; }
      if (response.body) await response.body.cancel().catch(() => undefined);
      accepted = response.ok && allAcceptedAcknowledgement(acknowledgement, batch.length);
    } catch {
      accepted = false;
    }

    if (!accepted) {
      lastFailureAtMs = Date.now();
      flushRequested = false;
      scheduleRetry();
      return false;
    }

    lastAcceptedAtMs = Date.now();
    lastFailureAtMs = null;
    retryDelayMs = 5_000;
    nextRetryAtMs = 0;
    if (retryTimer) clearTimeout(retryTimer);
    retryTimer = undefined;
    const successfulKeys = new Set(batch.map((span) => `${span.traceId}:${span.spanId}`));
    await rewriteOutbox(successfulKeys);
    const remaining = await readFile(outboxPath, "utf8").catch(() => "");
    if (remaining.split("\n").filter(Boolean).length > 0) flushRequested = true;
    return true;
  };

  const flush = (): Promise<void> => {
    if (!configured) return writeChain;
    if (Date.now() < nextRetryAtMs) return writeChain;
    if (flushChain) {
      flushRequested = true;
      return flushChain;
    }
    flushRequested = false;
    flushChain = (async () => {
      do {
        flushRequested = false;
        const canContinue = await flushOutbox();
        if (!canContinue) break;
      } while (flushRequested);
    })().catch(() => undefined).finally(() => { flushChain = undefined; });
    return flushChain;
  };

  const queueSpan = (span: CompletedSpan): void => {
    enqueueWrite(`${JSON.stringify(span)}\n`, true);
    void flush();
  };

  return {
    start(identity) {
      const engine = identifier(identity.engine) ?? "unknown";
      let model = identifier(identity.model);
      let provider = identifier(identity.provider);
      let sessionId = safeSessionId(identity.sessionId);
      const turnId = randomUUID();
      const traceId = randomUUID().replaceAll("-", "");
      const spanId = randomUUID().replaceAll("-", "").slice(0, 16);
      const started = new Date();
      let terminal = false;
      let usage: CompletedSpan["usage"];
      let context: CompletedSpan["context"];
      let errorCategory: string | undefined;
      let errorCode: number | undefined;
      let toolStatus: string | undefined;
      let toolName: string | undefined;
      let toolType: string | undefined;
      let pendingProgress: Partial<SafeEvent> | undefined;
      let lastProgressWriteAtMs = 0;
      const writeEvent = (kind: SafeEvent["kind"], details: Partial<SafeEvent> = {}): void => {
        const row: SafeEvent = {
          at: new Date().toISOString(), turnId, traceId, kind, engine,
          ...(model ? { model } : {}), ...(provider ? { provider } : {}), ...(sessionId ? { sessionId } : {}), ...details,
        };
        enqueueWrite(`${JSON.stringify(row)}\n`);
      };
      const flushProgress = (): void => {
        if (!pendingProgress) return;
        writeEvent("progress", pendingProgress);
        pendingProgress = undefined;
        lastProgressWriteAtMs = Date.now();
      };
      writeEvent("start");
      return {
        turnId,
        record(kind, details) {
          if (terminal) return;
          const clean = safeDetail(kind, details);
          if (kind === "progress" && clean.count !== undefined && !clean.errorCategory && clean.errorCode === undefined) {
            if (pendingProgress && (pendingProgress.phase !== clean.phase || (pendingProgress.count ?? 0) + clean.count > 1_000_000)) flushProgress();
            pendingProgress = { ...clean, count: (pendingProgress?.count ?? 0) + clean.count };
            if (Date.now() - lastProgressWriteAtMs >= 1_000) flushProgress();
            return;
          }
          flushProgress();
          if (kind === "metadata") {
            if (clean.model) model = clean.model;
            if (clean.provider) provider = clean.provider;
            if (clean.sessionId) sessionId = clean.sessionId;
          }
          if (kind === "usage" && clean.exactPerTurn === true) {
            usage = {
              ...(clean.inputTokens !== undefined ? { inputTokens: clean.inputTokens } : {}),
              ...(clean.outputTokens !== undefined ? { outputTokens: clean.outputTokens } : {}),
              ...(clean.cacheReadTokens !== undefined ? { cacheReadTokens: clean.cacheReadTokens } : {}),
              ...(clean.cacheWriteTokens !== undefined ? { cacheWriteTokens: clean.cacheWriteTokens } : {}),
              ...(clean.totalTokens !== undefined ? { totalTokens: clean.totalTokens } : {}),
            };
          }
          if (kind === "context" && clean.contextBasis === "latest-response") {
            context = {
              ...(clean.inputTokens !== undefined ? { inputTokens: clean.inputTokens } : {}),
              ...(clean.outputTokens !== undefined ? { outputTokens: clean.outputTokens } : {}),
              ...(clean.cacheReadTokens !== undefined ? { cacheReadTokens: clean.cacheReadTokens } : {}),
              ...(clean.totalTokens !== undefined ? { totalTokens: clean.totalTokens } : {}),
              ...(clean.contextWindow !== undefined ? { contextWindow: clean.contextWindow } : {}),
              ...(clean.updatedAtMs !== undefined ? { updatedAtMs: clean.updatedAtMs } : {}),
              contextBasis: "latest-response",
            };
          }
          writeEvent(kind, clean);
          if (kind === "progress" && clean.phase === "finalizing") {
            errorCategory = clean.errorCategory;
            errorCode = clean.errorCode;
          } else {
            if (clean.errorCategory) errorCategory = clean.errorCategory;
            if (clean.errorCode !== undefined) errorCode = clean.errorCode;
          }
          if (kind === "tool" && clean.toolStatus) toolStatus = clean.toolStatus;
          if (kind === "tool" && clean.tool) toolName = clean.tool;
          if (kind === "tool" && clean.toolType) toolType = clean.toolType;
        },
        finish(outcome, details) {
          if (terminal) return false;
          terminal = true;
          flushProgress();
          const safeOutcome = ALLOWED_OUTCOMES.has(outcome) ? outcome : "unknown";
          const clean = safeDetail("progress", details);
          const finished = new Date();
          const durationMs = Math.max(0, finished.getTime() - started.getTime());
          const terminalCategory = clean.errorCategory ?? errorCategory;
          const terminalCode = clean.errorCode ?? errorCode;
          writeEvent("terminal", {
            ...(clean.phase ? { phase: clean.phase } : {}), outcome: safeOutcome, durationMs,
            ...(safeOutcome === "error" && terminalCategory ? { errorCategory: terminalCategory } : {}),
            ...(safeOutcome === "error" && terminalCode !== undefined ? { errorCode: terminalCode } : {}),
          });
          const span: CompletedSpan = {
            traceId, spanId, startNs: timestampNs(started), endNs: timestampNs(finished),
            durationMs, engine,
            outcome: safeOutcome,
            ...(model ? { model } : {}), ...(provider ? { provider } : {}),
            ...(sessionId ? { sessionId } : {}),
            ...(safeOutcome === "error" && terminalCategory ? { errorCategory: terminalCategory } : {}),
            ...(safeOutcome === "error" && terminalCode !== undefined ? { errorCode: terminalCode } : {}),
            ...(toolStatus ? { toolStatus } : {}),
            ...(toolName ? { toolName } : {}),
            ...(toolType ? { toolType } : {}),
            ...(context ? { context } : {}),
            ...(usage ? { usage } : {}),
          };
          queueSpan(span);
          return true;
        },
      };
    },
    flush,
    async status() {
      await writeChain;
      const rows = (await readFile(outboxPath, "utf8").catch(() => "")).split("\n").filter(Boolean);
      const pending = rows.reduce((count, row) => {
        try { return count + (CompletedSpanSchema.safeParse(JSON.parse(row) as unknown).success ? 1 : 0); }
        catch { return count; }
      }, 0);
      return { configured, pending, lastAcceptedAtMs, lastFailureAtMs, droppedEvents, localWriteFailures };
    },
  };
}
