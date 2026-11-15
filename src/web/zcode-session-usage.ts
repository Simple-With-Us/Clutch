/**
 * Z Code session usage, read from the engine's own model I/O log.
 *
 * Z Code writes one file per session into `~/.zcode/cli/rollout`, named
 * `model-io-<session id>.jsonl`, and every record in it is one model request
 * and response:  the model and provider the engine used, how long the response
 * took, and the provider's own token counters.
 *
 * Nothing here is estimated.  The rate is the engine's own output token count
 * over the engine's own duration, and the token counts are the engine's own.
 * The context window is NOT reported:  the log carries no window, and a
 * guessed window would put a wrong percentage in front of someone deciding
 * whether to start a fresh thread.  The percentage stays absent until the
 * window has a real source.
 */
import { lstat, open } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

import type { SessionUsage } from "./session-usage.ts";

/** How much of the tail of a log file is read. */
const TAIL_BYTES = 1 << 20;
/** The largest log file that is read whole when its tail holds no record. */
const MAX_WHOLE_FILE_BYTES = 32 << 20;
/**
 * A session id, as Z Code writes it.  This is the engine's own rule:  a
 * `sess_` id, or the legacy `session_` form, followed by the id body.
 */
const SESSION_ID = /^(?:sess|session)_[A-Za-z0-9._-]+$/;
/** The longest id this reader looks for.  The engine cuts its file names at 80
 *  characters anyway, so a longer id cannot name a different file. */
const MAX_SESSION_ID_LENGTH = 200;

/** The directory Z Code writes its model I/O logs in. */
export function zcodeSessionsRoot(home = homedir()): string {
  return join(home, ".zcode", "cli", "rollout");
}

/**
 * The file name Z Code gives a session's log.
 *
 * This is the engine's own rule:  anything that is not a letter, a digit, an
 * underscore or a hyphen becomes a hyphen, the ends are trimmed, and the name
 * is cut to 80 characters.  Reproducing it exactly is what makes the lookup
 * find the engine's file for every id it can produce.  It is also what keeps a
 * crafted id from escaping the log directory:  the result holds no dot and no
 * path separator.
 */
export function zcodeSessionFileName(sessionId: string): string {
  const safe = sessionId
    .replace(/[^a-zA-Z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
  return `model-io-${safe || "no-session"}.jsonl`;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function numberOr(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}

/**
 * The usage a Z Code record reports, or null when it reports none.
 *
 * The counters are the provider's, and `totalTokens` is the context that was
 * in play for that response:  Z Code's `inputTokens` already includes the
 * cached read, so it must not be added again.
 */
export function zcodeSessionUsage(record: unknown): SessionUsage | null {
  const row = asRecord(record);
  if (!row) return null;
  const response = asRecord(row.response);
  const usage = asRecord(response?.usage);
  if (!usage) return null;
  const inputTokens = numberOr(usage.inputTokens);
  const outputTokens = numberOr(usage.outputTokens);
  if (inputTokens === undefined && outputTokens === undefined) return null;
  const totalTokens = numberOr(usage.totalTokens);
  const cacheReadTokens = numberOr(usage.cacheReadTokens);
  const durationMs = numberOr(row.durationMs);
  const model = asRecord(row.model);
  const modelId = typeof model?.modelId === "string" ? model.modelId
    : typeof response?.modelId === "string" ? response.modelId
    : undefined;
  const providerId = typeof model?.providerId === "string" ? model.providerId : undefined;
  const completedAt = typeof row.completedAt === "string" ? Date.parse(row.completedAt) : Number.NaN;
  const rate = outputTokens !== undefined && durationMs !== undefined && durationMs > 0
    ? outputTokens / (durationMs / 1_000)
    : undefined;
  return {
    // The counters belong to one response, not to the whole session.
    basis: "latest-response",
    ...(modelId ? { model: modelId } : {}),
    ...(providerId ? { provider: providerId } : {}),
    inputTokens: inputTokens ?? 0,
    outputTokens: outputTokens ?? 0,
    ...(inputTokens === undefined ? { inputTokensReported: false as const } : {}),
    ...(outputTokens === undefined ? { outputTokensReported: false as const } : {}),
    totalTokens: totalTokens ?? (inputTokens ?? 0) + (outputTokens ?? 0),
    ...(cacheReadTokens !== undefined ? { cacheReadTokens } : {}),
    ...(rate !== undefined ? { responseTokensPerSecond: rate } : {}),
    ...(durationMs !== undefined ? { completionDurationMs: durationMs } : {}),
    ...(Number.isFinite(completedAt) ? { updatedAtMs: completedAt } : {}),
  };
}

/**
 * The last record in a chunk of the log that carries usage.
 *
 * The engine appends to the file while it runs, so the last line can be half
 * written.  A line that does not parse is skipped, and the search keeps going
 * back until a record with usage is found.
 */
function lastUsageRecord(text: string, skipFirstLine: boolean): unknown | null {
  const lines = text.split("\n");
  for (let index = lines.length - 1; index >= (skipFirstLine ? 1 : 0); index -= 1) {
    const line = lines[index]?.trim();
    if (!line) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    const row = asRecord(parsed);
    if (!row) continue;
    if (asRecord(row.response)?.usage) return parsed;
  }
  return null;
}

async function readTail(handle: Awaited<ReturnType<typeof open>>, size: number, window: number): Promise<string> {
  const buffer = Buffer.alloc(window);
  // A read is allowed to come back short, so the tail is filled in a loop:
  // stopping early would leave the newest record outside the buffer and the
  // reader would report an older one as the latest.
  let read = 0;
  while (read < window) {
    const { bytesRead } = await handle.read(buffer, read, window - read, size - window + read);
    if (bytesRead === 0) break;
    read += bytesRead;
  }
  return buffer.toString("utf8");
}

async function readLastUsageRecord(path: string, size: number): Promise<unknown | null> {
  const handle = await open(path, "r");
  try {
    const window = Math.min(size, TAIL_BYTES);
    const text = await readTail(handle, size, window);
    const record = lastUsageRecord(text, size > window);
    if (record) return record;
    if (size <= window) return null;
    // The last record is bigger than the tail window, so the whole file is
    // read, up to a cap:  a log this large is not a session transcript.
    if (size > MAX_WHOLE_FILE_BYTES) return null;
    const whole = await readTail(handle, size, size);
    return lastUsageRecord(whole, false);
  } finally {
    await handle.close();
  }
}

interface CachedUsage {
  size: number;
  mtimeMs: number;
  usage: SessionUsage | null;
}

const cache = new Map<string, CachedUsage>();

/**
 * The usage of one Z Code session, or null when the engine has not written
 * any for it.
 *
 * The file grows as the session runs, so the answer is cached against the
 * file's size and mtime:  an unchanged file is not read again.
 */
export async function readZcodeSessionUsage(
  sessionId: string,
  options: { root?: string } = {},
): Promise<SessionUsage | null> {
  if (!sessionId || sessionId.length > MAX_SESSION_ID_LENGTH || !SESSION_ID.test(sessionId)) return null;
  const root = options.root ?? zcodeSessionsRoot();
  const path = join(root, zcodeSessionFileName(sessionId));
  let info: Awaited<ReturnType<typeof lstat>>;
  try {
    info = await lstat(path);
  } catch {
    return null;
  }
  // A symlink is not the engine's own file, so it is not read.
  if (!info.isFile() || info.isSymbolicLink()) return null;
  const cached = cache.get(path);
  if (cached && cached.size === info.size && cached.mtimeMs === info.mtimeMs) return cached.usage;
  let usage: SessionUsage | null = null;
  try {
    usage = zcodeSessionUsage(await readLastUsageRecord(path, info.size));
  } catch {
    usage = null;
  }
  cache.set(path, { size: info.size, mtimeMs: info.mtimeMs, usage });
  return usage;
}

/** Forget the cached answers, so a test reads the file again. */
export function clearZcodeUsageCache(): void {
  cache.clear();
}
