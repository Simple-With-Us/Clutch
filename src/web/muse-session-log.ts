import { constants } from "node:fs";
import { lstat, open, readdir, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

import type { SessionUpdate } from "./sessionUpdates.ts";

const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_LOG_BYTES = 2 * 1024 * 1024;
const HEAD_BYTES = 96 * 1024;
const MAX_LINE_BYTES = 256 * 1024;
const MAX_LINES = 5_000;
const MAX_UPDATES = 500;
const MAX_TEXT_CHARS = 8_000;
const MAX_TOTAL_TEXT_CHARS = 120_000;
const MAX_CACHE_ENTRIES = 32;
const MAX_SUMMARY_BYTES = 256 * 1024;
const MAX_SUMMARY_CACHE_ENTRIES = 256;
const MAX_LOCATION_CACHE_ENTRIES = 4_096;

export interface MuseSessionUsage {
  /** Totals from unique, provider-reported attribution records only. */
  inputTokens?: number;
  outputTokens?: number;
  cachedTokens?: number;
  /** False when bounds or malformed rows kept part of the log unread. */
  totalsComplete: boolean;
  /** The latest valid per-call duration, including provider and network latency. */
  completionDurationMs: number | null;
  /** Output tokens divided by the matching whole-response duration, not generation-only time. */
  responseTokensPerSecond: number | null;
  responseRateBasis: "whole-response-including-latency";
  /** The logs do not report generation-only timing. */
  generationOnlyTokensPerSecond: null;
  /** The observed log schema does not report these values. */
  contextOccupancyTokens: null;
  generationTokensPerSecond: null;
  attributionCount: number;
}

export interface MuseSessionLog {
  sessionId: string;
  modelId?: string;
  providerId?: string;
  workspaceRoot?: string;
  name?: string;
  transcript: SessionUpdate[];
  /** True when source bounds or transcript display limits omit preview content. */
  transcriptTruncated: boolean;
  usage: MuseSessionUsage;
  /** True when bounded reads, line limits, or malformed rows omit source records. */
  truncated: boolean;
}

export interface MuseSessionLogOptions {
  sessionsRoot?: string;
  maxBytes?: number;
  maxLines?: number;
}

interface InternalMuseSessionLogOptions extends MuseSessionLogOptions {
  includeTranscript?: boolean;
}

interface ParsedRecord {
  value: Record<string, unknown>;
  sequence: number;
}

const cache = new Map<string, { result: MuseSessionLog; mtimeMs: number; size: number }>();
const summaryCache = new Map<string, { result: MuseSessionLog; mtimeMs: number; size: number }>();
const locationCache = new Map<string, string>();

/** Muse stores sessions below XDG_DATA_HOME, or ~/.local/share by default. */
export function museSessionsRoot(env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  const xdgDataHome = env.XDG_DATA_HOME?.trim();
  const dataHome = xdgDataHome && isAbsolute(xdgDataHome) ? xdgDataHome : join(home, ".local", "share");
  return join(dataHome, "muse", "sessions");
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function boundedText(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  if (!text) return null;
  return text.length > MAX_TEXT_CHARS ? `${text.slice(0, MAX_TEXT_CHARS)}…` : text;
}

function parseJsonRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value !== "string" || value.length > MAX_LINE_BYTES) return null;
  try {
    return asRecord(JSON.parse(value));
  } catch {
    return null;
  }
}

function recordSequence(record: Record<string, unknown>, fallback: number): number {
  const sequence = record.sequence;
  return typeof sequence === "number" && Number.isSafeInteger(sequence) && sequence >= 0
    ? sequence
    : fallback;
}

/**
 * Expand verified modern records and actual retained-frame child rows without
 * interpreting arbitrary child JSON.  Frame children arrive in record_json and
 * must themselves be payload_type/payload records.
 */
function collectRecords(value: unknown, out: ParsedRecord[], fallback: number, depth = 0): boolean {
  if (depth > 3) return false;
  const row = asRecord(value);
  if (!row) return false;
  if (typeof row.payload_type === "string" && asRecord(row.payload)) {
    out.push({ value: row, sequence: recordSequence(row, fallback) });
  }

  if (typeof row.retained_frame !== "string") {
    return typeof row.payload_type !== "string" || asRecord(row.payload) !== null;
  }
  const children = row.children;
  if (!Array.isArray(children)) return false;
  let valid = true;
  for (const [index, childValue] of children.entries()) {
    const child = asRecord(childValue);
    if (!child) { valid = false; continue; }
    const decoded = parseJsonRecord(child.record_json);
    if (decoded && typeof decoded.payload_type === "string" && asRecord(decoded.payload)) {
      if (!collectRecords(decoded, out, fallback + index, depth + 1)) valid = false;
    } else {
      valid = false;
    }
  }
  return valid;
}

function getPayloadRecord(payload: Record<string, unknown>): Record<string, unknown> | null {
  return asRecord(payload.record);
}

function addUsage(
  target: { inputTokens?: number; outputTokens?: number; cachedTokens?: number; seen: Set<string>; count: number },
  raw: unknown,
): void {
  const event = asRecord(raw);
  if (event?.kind !== "goal_usage_attribution") return;
  const attribution = asRecord(event.record);
  if (!attribution || attribution.usage_family !== "provider" || typeof attribution.usage_id !== "string") return;
  const usageId = attribution.usage_id.trim();
  const quantity = asRecord(attribution.quantity);
  if (!usageId || !quantity || quantity.unit !== "tokens" || quantity.reported !== true || target.seen.has(usageId)) return;
  target.seen.add(usageId);
  target.count += 1;
  for (const [field, key] of [
    ["inputTokens", "input_tokens"],
    ["outputTokens", "output_tokens"],
    ["cachedTokens", "cached_tokens"],
  ] as const) {
    const value = quantity[key];
    if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) {
      target[field] = (target[field] ?? 0) + value;
    }
  }
}

/** Parse bounded Muse session JSONL into metadata, preview updates, and reported usage. */
export function parseMuseSessionLog(
  contents: string,
  sessionId: string,
  options: Pick<MuseSessionLogOptions, "maxBytes" | "maxLines"> & { includeTranscript?: boolean } = {},
): MuseSessionLog {
  const maxBytes = Math.max(1, Math.min(options.maxBytes ?? MAX_LOG_BYTES, MAX_LOG_BYTES));
  const maxLines = Math.max(1, Math.min(options.maxLines ?? MAX_LINES, MAX_LINES));
  const bytes = Buffer.from(contents, "utf8");
  const truncated = bytes.byteLength > maxBytes;
  const bounded = truncated ? bytes.subarray(0, maxBytes).toString("utf8") : contents;
  const allLines = bounded.split(/\r?\n/);
  const lineLimitTriggered = allLines.slice(maxLines).some((line) => line.length > 0);
  const lines = lineLimitTriggered && maxLines > 1
    ? [...allLines.slice(0, Math.max(1, Math.floor(maxLines / 4))), ...allLines.slice(-(maxLines - Math.max(1, Math.floor(maxLines / 4))))]
    : lineLimitTriggered
      ? allLines.slice(-maxLines)
      : allLines.slice(0, maxLines);
  const records: ParsedRecord[] = [];
  let unreadableRow = false;
  let oversizedRow = false;
  let incompleteFrame = false;
  for (const [index, line] of lines.entries()) {
    if (Buffer.byteLength(line, "utf8") > MAX_LINE_BYTES) {
      oversizedRow = true;
      continue;
    }
    if (!line.trim()) continue;
    let value: unknown;
    try {
      value = JSON.parse(line);
    } catch {
      unreadableRow = true;
      continue;
    }
    if (!collectRecords(value, records, index)) incompleteFrame = true;
  }

  records.sort((a, b) => a.sequence - b.sequence);
  const sourceTruncated = truncated || lineLimitTriggered || unreadableRow || oversizedRow || incompleteFrame;
  const result: MuseSessionLog = {
    sessionId,
    transcript: [],
    transcriptTruncated: sourceTruncated && options.includeTranscript !== false,
    usage: {
      completionDurationMs: null,
      responseTokensPerSecond: null,
      responseRateBasis: "whole-response-including-latency",
      generationOnlyTokensPerSecond: null,
      contextOccupancyTokens: null,
      generationTokensPerSecond: null,
      totalsComplete: false,
      attributionCount: 0,
    },
    truncated: sourceTruncated,
  };
  const usage: { inputTokens?: number; outputTokens?: number; cachedTokens?: number; seen: Set<string>; count: number } = {
    seen: new Set<string>(),
    count: 0,
  };
  const completedCallIds = new Set<string>();
  let transcriptChars = 0;
  const transcriptText = (value: unknown): string | null => {
    const text = boundedText(value);
    if (typeof value === "string" && value.trim().length > MAX_TEXT_CHARS) result.transcriptTruncated = true;
    return text;
  };
  const append = (update: SessionUpdate | null): void => {
    if (!options.includeTranscript && options.includeTranscript !== undefined) return;
    if (!update) return;
    const text = update.text.length > MAX_TOTAL_TEXT_CHARS ? update.text.slice(0, MAX_TOTAL_TEXT_CHARS) : update.text;
    if (text.length !== update.text.length) result.transcriptTruncated = true;
    while (result.transcript.length >= MAX_UPDATES || transcriptChars + text.length > MAX_TOTAL_TEXT_CHARS) {
      const removed = result.transcript.shift();
      if (!removed) break;
      transcriptChars -= removed.text.length;
      result.transcriptTruncated = true;
    }
    result.transcript.push({ ...update, text });
    transcriptChars += text.length;
  };

  for (const [recordIndex, { value }] of records.entries()) {
    const type = value.payload_type;
    const payload = asRecord(value.payload);
    if (!payload || typeof type !== "string") continue;

    if (type === "runtime.session.metadata") {
      const metadata = getPayloadRecord(payload);
      if (metadata) {
        if (typeof metadata.model_id === "string" && metadata.model_id) result.modelId = metadata.model_id;
        if (typeof metadata.provider_id === "string" && metadata.provider_id) result.providerId = metadata.provider_id;
        if (typeof metadata.workspace_root === "string" && metadata.workspace_root) result.workspaceRoot = metadata.workspace_root;
      }
      continue;
    }
    if (type === "run.model.configured") {
      const model = getPayloadRecord(payload);
      if (model) {
        if (typeof model.model_id === "string" && model.model_id) result.modelId = model.model_id;
        if (typeof model.provider_id === "string" && model.provider_id) result.providerId = model.provider_id;
      }
      continue;
    }
    if (type === "session.name.changed") {
      if (typeof payload.new_name === "string") {
        const name = boundedText(payload.new_name);
        if (name) result.name = name;
        else delete result.name;
      }
      continue;
    }

    const event = asRecord(payload.event);
    if (!event || typeof event.kind !== "string") continue;
    if (event.kind === "model_completed") {
      const sequence = value.sequence;
      const callId = typeof value.id === "string"
        ? value.id
        : typeof sequence === "number" && Number.isSafeInteger(sequence)
          ? `sequence:${sequence}`
          : `record:${recordIndex}`;
      const modelUsage = asRecord(event.usage);
      const duration = event.duration_ms;
      const outputTokens = modelUsage?.output_tokens;
      if (!completedCallIds.has(callId)) {
        completedCallIds.add(callId);
        if (typeof duration === "number" && Number.isSafeInteger(duration) && duration > 0) {
          result.usage.completionDurationMs = duration;
          result.usage.responseTokensPerSecond = null;
          if (typeof outputTokens === "number" && Number.isSafeInteger(outputTokens) && outputTokens >= 0) {
            result.usage.responseTokensPerSecond = outputTokens / (duration / 1_000);
          }
        }
      }
    }
    if (event.kind === "user_prompt_display") {
      const text = transcriptText(event.prompt);
      if (text) append({ sessionId, kind: "user_message_chunk", text });
    } else if (event.kind === "assistant_message_committed") {
      const text = transcriptText(event.text);
      if (text) append({ sessionId, kind: "agent_message_chunk", text });
    } else if (event.kind === "assistant_tool_calls_committed" && Array.isArray(event.tool_calls)) {
      for (const rawCall of event.tool_calls) {
        const call = asRecord(rawCall);
        const callId = typeof call?.call_id === "string" ? call.call_id : call?.id;
        const name = transcriptText(call?.name);
        if (typeof callId === "string" && name) append({ sessionId, kind: "tool_call", text: name, toolCallId: callId, toolStatus: "running" });
      }
    } else if (event.kind === "tool_result_batch_committed" && Array.isArray(event.results)) {
      for (const rawResult of event.results) {
        const item = asRecord(rawResult);
        const text = transcriptText(item?.text);
        if (typeof item?.tool_call_id === "string" && text) {
          append({ sessionId, kind: "tool_call_update", text, toolCallId: item.tool_call_id, toolStatus: "completed" });
        }
      }
    }
    addUsage(usage, event);
  }

  if (usage.count > 0) {
    result.usage = {
      ...(usage.inputTokens !== undefined ? { inputTokens: usage.inputTokens } : {}),
      ...(usage.outputTokens !== undefined ? { outputTokens: usage.outputTokens } : {}),
      ...(usage.cachedTokens !== undefined ? { cachedTokens: usage.cachedTokens } : {}),
      completionDurationMs: result.usage.completionDurationMs,
      responseTokensPerSecond: result.usage.responseTokensPerSecond,
      responseRateBasis: "whole-response-including-latency",
      generationOnlyTokensPerSecond: null,
      contextOccupancyTokens: null,
      generationTokensPerSecond: null,
      totalsComplete: !result.truncated,
      attributionCount: usage.count,
    };
  } else {
    result.usage.totalsComplete = !result.truncated;
  }
  return result;
}

function validDatePath(year: string, month: string, day: string): boolean {
  if (!/^\d{4}$/.test(year) || !/^\d{2}$/.test(month) || !/^\d{2}$/.test(day)) return false;
  const date = new Date(`${year}-${month}-${day}T00:00:00.000Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === `${year}-${month}-${day}`;
}

function isInside(root: string, path: string): boolean {
  return path === root || path.startsWith(`${root}${sep}`);
}

/** Find a session file only below YYYY/MM/DD/<strict UUID>, rejecting symlinks. */
export async function findMuseSessionLog(
  sessionId: string,
  sessionsRoot = museSessionsRoot(),
): Promise<string | null> {
  if (!SESSION_ID.test(sessionId)) return null;
  const rootPath = resolve(sessionsRoot);
  try {
    const rootStat = await lstat(rootPath);
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) return null;
    const root = await realpath(rootPath);
    const cacheKey = `${root}\u0000${sessionId}`;
    const cachedPath = locationCache.get(cacheKey);
    if (cachedPath && await isSafeSessionPath(root, sessionId, cachedPath)) return cachedPath;
    if (cachedPath) locationCache.delete(cacheKey);
    const years = await readdir(root, { withFileTypes: true });
    let visited = 0;
    for (const yearEntry of years) {
      if (!/^\d{4}$/.test(yearEntry.name) || !yearEntry.isDirectory() || yearEntry.isSymbolicLink()) continue;
      const yearPath = join(root, yearEntry.name);
      for (const monthEntry of await readdir(yearPath, { withFileTypes: true })) {
        if (!/^\d{2}$/.test(monthEntry.name) || !monthEntry.isDirectory() || monthEntry.isSymbolicLink()) continue;
        const monthPath = join(yearPath, monthEntry.name);
        for (const dayEntry of await readdir(monthPath, { withFileTypes: true })) {
          if (!dayEntry.isDirectory() || dayEntry.isSymbolicLink() || !validDatePath(yearEntry.name, monthEntry.name, dayEntry.name)) continue;
          const dayPath = join(monthPath, dayEntry.name);
          for (const sessionEntry of await readdir(dayPath, { withFileTypes: true })) {
            visited += 1;
            if (visited > 20_000) return null;
            if (sessionEntry.name !== sessionId || !sessionEntry.isDirectory() || sessionEntry.isSymbolicLink()) continue;
            const candidate = join(dayPath, sessionId, "session.jsonl");
            if (!await isSafeSessionPath(root, sessionId, candidate)) continue;
            locationCache.set(cacheKey, candidate);
            while (locationCache.size > MAX_LOCATION_CACHE_ENTRIES) locationCache.delete(locationCache.keys().next().value!);
            return candidate;
          }
        }
      }
    }
  } catch {
    return null;
  }
  return null;
}

async function isSafeSessionPath(root: string, sessionId: string, path: string): Promise<boolean> {
  if (!isInside(root, path)) return false;
  const parts = relative(root, path).split(sep);
  if (parts.length !== 5 || !validDatePath(parts[0]!, parts[1]!, parts[2]!) || parts[3] !== sessionId || parts[4] !== "session.jsonl") return false;
  let parent = root;
  for (const part of parts.slice(0, 4)) {
    parent = join(parent, part);
    const stat = await lstat(parent).catch(() => null);
    if (!stat?.isDirectory() || stat.isSymbolicLink()) return false;
  }
  const stat = await lstat(path).catch(() => null);
  if (!stat?.isFile() || stat.isSymbolicLink()) return false;
  const canonical = await realpath(path).catch(() => null);
  return canonical === path && isInside(root, canonical);
}

function sameFileIdentity(left: { dev: number; ino: number }, right: { dev: number; ino: number }): boolean {
  return left.dev === right.dev && left.ino === right.ino;
}

async function readBounded(
  path: string,
  size: number,
  maxBytes: number,
  identity: { dev: number; ino: number },
  validatePath: () => Promise<boolean>,
): Promise<string | null> {
  const handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const actual = await handle.stat();
    if (!actual.isFile() || actual.size !== size || !sameFileIdentity(actual, identity)) return null;
    if (!await validatePath()) return null;
    const current = await lstat(path).catch(() => null);
    if (!current?.isFile() || current.isSymbolicLink() || !sameFileIdentity(current, identity)) return null;
    if (size <= maxBytes) {
      const whole = Buffer.alloc(size);
      const read = await handle.read(whole, 0, size, 0);
      if (read.bytesRead !== size) return null;
      return whole.subarray(0, read.bytesRead).toString("utf8");
    }
    const headSize = Math.min(HEAD_BYTES, Math.max(1, maxBytes - 1));
    const tailSize = Math.min(Math.max(0, size - headSize), maxBytes - headSize - 1);
    const head = Buffer.alloc(headSize);
    const first = await handle.read(head, 0, headSize, 0);
    const chunks = [head.subarray(0, first.bytesRead)];
    if (tailSize > 0) {
      const tail = Buffer.alloc(tailSize);
      const last = await handle.read(tail, 0, tailSize, size - tailSize);
      chunks.push(tail.subarray(0, last.bytesRead));
    }
    return Buffer.concat([chunks[0]!, Buffer.from("\n"), chunks[1] ?? Buffer.alloc(0)]).toString("utf8");
  } finally {
    await handle.close();
  }
}

/** Read a bounded preview from disk; this never starts Muse or invokes ACP. */
export async function readMuseSessionLog(
  sessionId: string,
  options: InternalMuseSessionLogOptions = {},
): Promise<MuseSessionLog | null> {
  const sessionsRoot = options.sessionsRoot ?? museSessionsRoot();
  const path = await findMuseSessionLog(sessionId, sessionsRoot);
  if (!path) return null;
  try {
    const root = await realpath(sessionsRoot);
    if (!isInside(root, path) || !await isSafeSessionPath(root, sessionId, path)) return null;
    const stat = await lstat(path);
    if (!stat.isFile() || stat.isSymbolicLink()) return null;
    const maxBytes = Math.max(1, Math.min(options.maxBytes ?? MAX_LOG_BYTES, MAX_LOG_BYTES));
    const maxLines = Math.max(1, Math.min(options.maxLines ?? MAX_LINES, MAX_LINES));
    const cacheKey = `${path}\u0000${stat.dev}:${stat.ino}:${maxBytes}:${maxLines}:${options.includeTranscript === false ? "summary" : "full"}`;
    const cached = cache.get(cacheKey);
    if (cached?.mtimeMs === stat.mtimeMs && cached.size === stat.size) return structuredClone(cached.result);
    const contents = await readBounded(path, stat.size, maxBytes, stat, () => isSafeSessionPath(root, sessionId, path));
    if (contents === null) return null;
    const parsed = parseMuseSessionLog(contents, sessionId, {
      maxBytes,
      maxLines,
      ...(options.includeTranscript !== undefined ? { includeTranscript: options.includeTranscript } : {}),
    });
    parsed.truncated ||= stat.size > maxBytes;
    parsed.usage.totalsComplete = !parsed.truncated;
    for (const key of [...cache.keys()]) if (key.startsWith(`${path}\u0000`)) cache.delete(key);
    cache.set(cacheKey, { result: structuredClone(parsed), mtimeMs: stat.mtimeMs, size: stat.size });
    while (cache.size > MAX_CACHE_ENTRIES) cache.delete(cache.keys().next().value!);
    return parsed;
  } catch {
    return null;
  }
}

/** Read and cache a compact sidebar summary from at most 256 KiB of session log data. */
export async function readMuseSessionSummary(
  sessionId: string,
  options: Pick<MuseSessionLogOptions, "sessionsRoot"> = {},
): Promise<MuseSessionLog | null> {
  const sessionsRoot = options.sessionsRoot ?? museSessionsRoot();
  const path = await findMuseSessionLog(sessionId, sessionsRoot);
  if (!path) return null;
  try {
    const root = await realpath(sessionsRoot);
    if (!isInside(root, path) || !await isSafeSessionPath(root, sessionId, path)) return null;
    const stat = await lstat(path);
    if (!stat.isFile() || stat.isSymbolicLink()) return null;
    const cacheKey = `${path}\u0000${stat.dev}:${stat.ino}:summary`;
    const cached = summaryCache.get(cacheKey);
    if (cached?.mtimeMs === stat.mtimeMs && cached.size === stat.size) {
      return structuredClone(cached.result);
    }
    const summary = await readMuseSessionLog(sessionId, {
      sessionsRoot,
      maxBytes: MAX_SUMMARY_BYTES,
      includeTranscript: false,
    });
    if (!summary) return null;
    const compact = { ...summary, transcript: [], transcriptTruncated: false };
    compact.usage.totalsComplete = !compact.truncated;
    for (const key of [...summaryCache.keys()]) if (key.startsWith(`${path}\u0000`)) summaryCache.delete(key);
    summaryCache.set(cacheKey, { result: structuredClone(compact), mtimeMs: stat.mtimeMs, size: stat.size });
    while (summaryCache.size > MAX_SUMMARY_CACHE_ENTRIES) summaryCache.delete(summaryCache.keys().next().value!);
    return compact;
  } catch {
    return null;
  }
}
