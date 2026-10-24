/**
 * Real per-session token usage, read from the engine's own session log.
 *
 * Why the log and not a guess:  the engine writes its accounting to
 * `$DSH_HOME/sessions/<encoded-cwd>/<session-id>/session.v3.jsonl.zstd`, and
 * those records are the only place the true `contextWindow`, `inputTokens`,
 * `outputTokens`, `totalTokens` and `cacheReadTokens` exist.  A
 * `characters / 4` estimate is wrong often enough to mislead, so nothing here
 * ever invents a number — when the log is missing, unreadable, or written by a
 * runtime without zstd, the result is `null` and the UI says "not reported".
 *
 * Two record shapes carry what we need:
 *
 *   request/context   {provider, model, contextWindow}   (the denominator)
 *   assistant/message {data.usage, time}                 (the numerator)
 *
 * `usage.totalTokens` is the occupancy of the window:  it is
 * `inputTokens + cacheReadTokens + outputTokens`, so it is directly
 * comparable to `contextWindow`.
 */

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import * as nodeZlib from "node:zlib";

import { z } from "zod";

/** One engine-reported accounting record.  Every field is optional because the
 *  engine omits what a given provider does not return. */
export interface SessionUsage {
  provider?: string;
  model?: string;
  /** The model's total context window, as the engine reported it. */
  contextWindow?: number;
  inputTokens: number;
  outputTokens: number;
  /** Context occupancy in tokens: input + cacheRead + output. */
  totalTokens: number;
  cacheReadTokens?: number;
  /** Engine event time of the usage record, in ms since the epoch. */
  updatedAtMs?: number;
  /** Output tokens per second, measured between two real engine records.
   *  Absent unless both records carried a timestamp that advanced. */
  outputTokensPerSecond?: number;
}

/** How far back to scan for the newest records.  A session log is append-only,
 *  so the tail always holds the latest usage; `request/context` is only written
 *  near the start of a session, so it gets a whole-file fallback. */
const TAIL_LINES = 4000;

/**
 * True when this Node can decode the engine's logs.
 *
 * `zstdDecompressSync` landed in Node 22.15 / 23.8, and package.json still
 * allows `>=22.0.0`, so an older runtime is a real possibility.  We degrade to
 * "no usage reported" there rather than failing the request.
 */
export function zstdAvailable(): boolean {
  return typeof (nodeZlib as { zstdDecompressSync?: unknown }).zstdDecompressSync === "function";
}

function inflate(raw: Buffer): string | null {
  const fn = (nodeZlib as { zstdDecompressSync?: (b: Buffer) => Buffer }).zstdDecompressSync;
  if (typeof fn !== "function") return null;
  try {
    return fn(raw).toString("utf8");
  } catch {
    return null;
  }
}

function parseJson(line: string): Record<string, unknown> | null {
  const trimmed = line.trim();
  if (!trimmed.startsWith("{")) return null;
  try {
    const value: unknown = JSON.parse(trimmed);
    return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** Shape of one session-log record we trust enough to read.  Parsing with
 *  zod instead of casting means a malformed line is skipped, never trusted. */
const RequestContextRecordSchema = z.object({
  type: z.literal("request/context"),
  time: z.number().optional(),
  data: z
    .object({
      provider: z.string().optional(),
      model: z.string().optional(),
      contextWindow: z.number().optional(),
    })
    .optional(),
});

const AssistantMessageRecordSchema = z.object({
  type: z.literal("assistant/message"),
  time: z.number().optional(),
  data: z
    .object({
      usage: z
        .object({
          inputTokens: z.number().optional(),
          outputTokens: z.number().optional(),
          totalTokens: z.number(),
          cacheReadTokens: z.number().optional(),
        })
        .optional(),
    })
    .optional(),
});

/** Pull `{provider, model, contextWindow}` out of one `request/context` line. */
function contextFrom(obj: Record<string, unknown>): SessionUsage | null {
  const parsed = RequestContextRecordSchema.safeParse(obj);
  if (!parsed.success) return null;
  const data = parsed.data.data;
  const contextWindow = data?.contextWindow;
  const provider = data?.provider;
  const model = data?.model;
  if (contextWindow === undefined && provider === undefined && model === undefined) return null;
  const out: SessionUsage = { inputTokens: 0, outputTokens: 0, totalTokens: 0 };
  if (provider !== undefined) out.provider = provider;
  if (model !== undefined) out.model = model;
  if (contextWindow !== undefined) out.contextWindow = contextWindow;
  return out;
}

/** Pull the accounting record out of one `assistant/message` line. */
function usageFrom(obj: Record<string, unknown>): SessionUsage | null {
  const parsed = AssistantMessageRecordSchema.safeParse(obj);
  if (!parsed.success) return null;
  const usage = parsed.data.data?.usage;
  if (!usage) return null;
  const out: SessionUsage = {
    inputTokens: usage.inputTokens ?? 0,
    outputTokens: usage.outputTokens ?? 0,
    totalTokens: usage.totalTokens,
  };
  if (usage.cacheReadTokens !== undefined) out.cacheReadTokens = usage.cacheReadTokens;
  if (parsed.data.time !== undefined) out.updatedAtMs = parsed.data.time;
  return out;
}

/**
 * Extract usage from already-decompressed session-log text.
 *
 * Split out from the file reading so the parsing rules are testable without
 * zstd fixtures:  newest usage record wins, newest `request/context` wins.
 */
export function extractUsageFromLogText(text: string): SessionUsage | null {
  const lines = text.split("\n");
  const tailStart = Math.max(0, lines.length - TAIL_LINES);
  let usage: SessionUsage | null = null;

  for (let i = lines.length - 1; i >= tailStart && !usage; i--) {
    const line = lines[i] ?? "";
    if (!line.includes('"usage"')) continue;
    const obj = parseJson(line);
    if (obj) usage = usageFrom(obj);
  }

  // `request/context` is written once near the head of a session, so a long
  // session's tail no longer holds it.  Scan the tail, then fall back to the
  // newest occurrence anywhere in the file.
  let context: SessionUsage | null = null;
  for (let i = lines.length - 1; i >= tailStart && !context; i--) {
    const line = lines[i] ?? "";
    if (!line.includes("request/context")) continue;
    const obj = parseJson(line);
    if (obj) context = contextFrom(obj);
  }
  if (!context) {
    const at = text.lastIndexOf('"request/context"');
    if (at >= 0) {
      // `at` lands in the middle of the line, on the type value.  Rewind to the
      // start of that line so the slice is a whole JSON object, then stop at the
      // newline so trailing records cannot corrupt it.
      const start = text.lastIndexOf("\n", at) + 1;
      const end = text.indexOf("\n", at);
      const obj = parseJson(text.slice(start, end < 0 ? undefined : end));
      if (obj) context = contextFrom(obj);
    }
  }

  if (!usage && !context) return null;
  const merged: SessionUsage = usage ?? { inputTokens: 0, outputTokens: 0, totalTokens: 0 };
  if (context?.provider !== undefined) merged.provider = context.provider;
  if (context?.model !== undefined) merged.model = context.model;
  if (context?.contextWindow !== undefined) merged.contextWindow = context.contextWindow;
  return merged;
}

/** Locate the engine's `session.v3.jsonl.zstd` for one session id.
 *
 *  The log sits at `<sessions-root>/<encoded-cwd>/<sessionId>/`.  The
 *  intermediate directory name is a lossy encoding of the working directory,
 *  so the session id is matched directly rather than reconstructed. */
export function sessionLogPath(dshHome: string, sessionId: string): string | null {
  const root = join(dshHome, "sessions");
  if (!existsSync(root)) return null;
  let groups: string[];
  try {
    groups = readdirSync(root);
  } catch {
    return null;
  }
  for (const group of groups) {
    if (group === "acp") continue;
    const candidate = join(root, group, sessionId, "session.v3.jsonl.zstd");
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/**
 * Tokens per second between two engine records.
 *
 * Deliberately strict:  a missing timestamp, a non-advancing clock, or an
 * output count that went backwards (a compaction, or a provider that resets
 * its counters) all yield `undefined` rather than a misleading figure.
 */
export function outputTokensPerSecond(current: SessionUsage, previous?: SessionUsage): number | undefined {
  if (!previous) return undefined;
  const t0 = previous.updatedAtMs;
  const t1 = current.updatedAtMs;
  if (t0 === undefined || t1 === undefined) return undefined;
  const seconds = (t1 - t0) / 1000;
  if (!(seconds > 0)) return undefined;
  const delta = current.outputTokens - previous.outputTokens;
  if (delta < 0) return undefined;
  const rate = delta / seconds;
  return Number.isFinite(rate) ? rate : undefined;
}

/**
 * Occupancy as a percentage of the model's window, or `undefined` when either
 * half is unknown.  A context window of zero would make the division
 * meaningless, so it is refused rather than reported as infinite.
 */
export function contextUsedPercent(usage: Pick<SessionUsage, "totalTokens" | "contextWindow">): number | undefined {
  const { totalTokens, contextWindow } = usage;
  if (!Number.isFinite(totalTokens) || !Number.isFinite(contextWindow)) return undefined;
  if (!contextWindow || contextWindow <= 0) return undefined;
  return (totalTokens / contextWindow) * 100;
}

/** Cache keyed by path, invalidated by the log's own mtime and size.  A session
 *  log only changes while that session is running, so repeat reads are free. */
interface CacheEntry {
  mtimeMs: number;
  size: number;
  value: SessionUsage | null;
}

const cache = new Map<string, CacheEntry>();

export function clearUsageCache(): void {
  cache.clear();
}

/**
 * Read the newest real usage record for one session, or `null` when the log is
 * absent or unreadable.  Never throws, and never estimates.
 */
export function readSessionUsage(dshHome: string, sessionId: string): SessionUsage | null {
  if (!sessionId || !zstdAvailable()) return null;
  const logPath = sessionLogPath(dshHome, sessionId);
  if (!logPath) return null;

  let mtimeMs: number;
  let size: number;
  try {
    const st = statSync(logPath);
    mtimeMs = st.mtimeMs;
    size = st.size;
  } catch {
    return null;
  }

  const hit = cache.get(logPath);
  if (hit && hit.mtimeMs === mtimeMs && hit.size === size) return hit.value;

  let value: SessionUsage | null = null;
  try {
    const text = inflate(readFileSync(logPath));
    if (text !== null) value = extractUsageFromLogText(text);
  } catch {
    value = null;
  }
  cache.set(logPath, { mtimeMs, size, value });
  return value;
}

/** Attach the measured rate from the previous read to a fresh reading. */
export function withRate(current: SessionUsage, previous?: SessionUsage): SessionUsage {
  const rate = outputTokensPerSecond(current, previous);
  return rate === undefined ? current : { ...current, outputTokensPerSecond: rate };
}