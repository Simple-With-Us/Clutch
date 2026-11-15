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

import { z } from "zod";

import type { SessionUsage } from "./session-usage.ts";

/** How much of the tail of a log file is read. */
const TAIL_BYTES = 1 << 20;
/**
 * The largest log file that is read whole when its tail holds no record.
 *
 * The read happens for at most a few sessions at a time, so this is the peak
 * transient cost of one sessions request.  A model I/O record that does not
 * fit in eight megabytes is not a record this reader can use.
 */
const MAX_WHOLE_FILE_BYTES = 8 << 20;
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

/**
 * An optional fact the engine may omit, write as `null`, or fill with a
 * non-number.  Only a real value is read;  anything else counts as "not
 * reported" for that one field, so one bad counter cannot hide the rest.
 */
const reportedNumber = z.number().finite().nonnegative().optional().catch(undefined);
const reportedString = z.string().optional().catch(undefined);

/** The provider's own counters for one response. */
const UsageSchema = z.object({
  inputTokens: reportedNumber,
  outputTokens: reportedNumber,
  totalTokens: reportedNumber,
  cacheReadTokens: reportedNumber,
  cacheWriteTokens: reportedNumber,
});

/**
 * One model I/O record, as Z Code writes it.
 *
 * The log is a file the engine appends to, so every field is optional:  a
 * record in flight carries no response yet.  Parsing with zod means a
 * malformed record is skipped rather than half-believed.
 */
const RecordSchema = z.object({
  durationMs: reportedNumber,
  completedAt: reportedString,
  model: z.object({
    modelId: reportedString,
    providerId: reportedString,
  }).optional().catch(undefined),
  response: z.object({
    modelId: reportedString,
    usage: UsageSchema,
  }).optional().catch(undefined),
});

/**
 * The usage a Z Code record reports, or null when it reports none.
 *
 * The counters are the provider's, and `totalTokens` is the context that was
 * in play for that response:  Z Code's `inputTokens` already includes the
 * cached read, so it must not be added again.
 */
export function zcodeSessionUsage(record: unknown): SessionUsage | null {
  const parsed = RecordSchema.safeParse(record);
  if (!parsed.success) return null;
  const row = parsed.data;
  const usage = row.response?.usage;
  if (!usage) return null;
  const inputTokens = usage.inputTokens;
  const outputTokens = usage.outputTokens;
  if (inputTokens === undefined && outputTokens === undefined) return null;
  const totalTokens = usage.totalTokens;
  const cacheReadTokens = usage.cacheReadTokens;
  const durationMs = row.durationMs;
  const modelId = row.model?.modelId ?? row.response?.modelId;
  const providerId = row.model?.providerId;
  const completedAt = row.completedAt === undefined ? Number.NaN : Date.parse(row.completedAt);
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
 * The newest usage in a chunk of the log.
 *
 * The engine appends to the file while it runs, so the last line can be half
 * written.  A line that does not parse is skipped, and the scan keeps going
 * back.  A record whose usage carries no real token count is skipped as well,
 * so an empty newer record cannot hide the counters in an older one.
 */
function lastUsageRecord(text: string, skipFirstLine: boolean): SessionUsage | null {
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
    const usage = zcodeSessionUsage(parsed);
    if (usage) return usage;
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

async function readLastUsage(path: string, size: number): Promise<SessionUsage | null> {
  const handle = await open(path, "r");
  try {
    const window = Math.min(size, TAIL_BYTES);
    const text = await readTail(handle, size, window);
    const usage = lastUsageRecord(text, size > window);
    if (usage) return usage;
    if (size <= window) return null;
    // The last record is bigger than the tail window, so more of the file is
    // read, up to a cap:  a log this large is not a session transcript.
    if (size > MAX_WHOLE_FILE_BYTES) return null;
    return lastUsageRecord(await readTail(handle, size, size), false);
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
    usage = await readLastUsage(path, info.size);
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
