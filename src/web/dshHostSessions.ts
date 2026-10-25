/**
 * Reading the dsh host's threads and their history.
 *
 * The dsh host owns the session log for the agents it runs, and that log is
 * the same store the ACP bridge reads, because both share `$CLUTCH_HOME/dsh`.
 * The host, however, exposes it as a session event graph rather than as a
 * transcript, so this module translates one into the other.
 *
 * The translation is deliberately narrow: the clients render four kinds, and
 * only those four are produced.  A tool call becomes a `tool_call` with the
 * tool's name as its title, and its result becomes a `tool_call_update` with
 * an empty text — the same convention the ACP path uses, where an empty title
 * tells the client to keep the name it already shows for that call.
 */

import type { SessionUpdate } from "./sessionUpdates.ts";
import type { DshHostClient } from "./dshHostClient.ts";

/** One thread as the clients see it, whatever engine owns it. */
export interface SessionSummary {
  readonly sessionId: string;
  readonly cwd?: string;
  readonly title?: string;
  readonly updatedAt?: string;
}

/** Read one property of an object, or null when it is not an object. */
function readRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value !== "object" || value === null) return null;
  return value as Record<string, unknown>;
}

/** The ISO-8601 form of an epoch-millisecond stamp, or null. */
function isoFromEpochMs(value: unknown): string | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  try {
    return new Date(value).toISOString();
  } catch {
    return null;
  }
}

/**
 * The title a session carries, when it has one.
 *
 * The host's `SessionSummary` has no top-level title: the title is a
 * projection value, so a session that has never been titled simply has none.
 */
function titleFromProjections(projections: unknown): string | undefined {
  const hints = readRecord(projections);
  const values = readRecord(hints?.["values"]);
  const title = values?.["title"];
  if (typeof title !== "string") return undefined;
  return title.trim().length > 0 ? title : undefined;
}

/**
 * Normalize the host's `session/list` value into the summary shape.
 *
 * The host returns every visible session and ignores the cursor, so the list
 * is capped here rather than on the wire.
 */
export function dshHostSessionSummaries(value: unknown, limit = 100): SessionSummary[] {
  const items = readRecord(value)?.["items"];
  if (!Array.isArray(items)) return [];
  const out: SessionSummary[] = [];
  for (const item of items) {
    const row = readRecord(item);
    const sessionId = row?.["sessionId"];
    if (typeof sessionId !== "string" || sessionId.length === 0) continue;
    const cwd = row?.["cwd"];
    const title = titleFromProjections(row?.["projections"]);
    const updatedAt = isoFromEpochMs(row?.["updatedAt"]);
    out.push({
      sessionId,
      ...(typeof cwd === "string" && cwd.length > 0 ? { cwd } : {}),
      ...(title !== undefined ? { title } : {}),
      ...(updatedAt !== null ? { updatedAt } : {}),
    });
    if (out.length >= limit) break;
  }
  return out;
}

/** The text of a message's content blocks, joined by newlines. */
function contentText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    const row = readRecord(block);
    if (row?.["type"] !== "text") continue;
    const text = row["text"];
    if (typeof text === "string" && text.length > 0) parts.push(text);
  }
  return parts.join("\n");
}

/**
 * The text of a tool result, and whether it failed.
 *
 * A tool result carries its failure twice: as an error identity beside the
 * message, and as `isError` on the result block.  Either one means failure.
 */
function toolResultText(data: Record<string, unknown>): { text: string; failed: boolean } {
  const message = readRecord(data["message"]);
  const blocks = message?.["content"];
  const first = Array.isArray(blocks) ? readRecord(blocks[0]) : null;
  const text = contentText(first?.["content"]);
  const failed = data["error"] !== undefined || first?.["isError"] === true;
  return { text, failed };
}

/**
 * Translate one host event into the transcript vocabulary.
 *
 * Returns null for the events the clients do not render: turn and step
 * boundaries, assistant attempts that committed nothing, system prompts, and
 * every plugin event this build does not know.
 */
export function dshHostEventToUpdate(
  sessionId: string,
  event: unknown,
): SessionUpdate | null {
  const row = readRecord(event);
  const type = row?.["type"];
  const data = readRecord(row?.["data"]);
  if (typeof type !== "string" || !data) return null;

  if (type === "user/message") {
    const text = contentText(data["content"]);
    return text.length > 0 ? { sessionId, kind: "user_message_chunk", text } : null;
  }

  if (type === "assistant/message") {
    const message = readRecord(data["message"]);
    const text = contentText(message?.["content"]);
    return text.length > 0 ? { sessionId, kind: "agent_message_chunk", text } : null;
  }

  if (type === "tool/call") {
    const callId = data["callId"];
    const name = data["name"];
    if (typeof callId !== "string" || typeof name !== "string") return null;
    return {
      sessionId,
      kind: "tool_call",
      text: name,
      toolCallId: callId,
      toolStatus: "running",
    };
  }

  if (type === "tool/result") {
    const message = readRecord(data["message"]);
    const blocks = message?.["content"];
    const first = Array.isArray(blocks) ? readRecord(blocks[0]) : null;
    const callId = first?.["toolCallId"];
    if (typeof callId !== "string") return null;
    const result = toolResultText(data);
    return {
      sessionId,
      kind: "tool_call_update",
      // An empty title tells the client to keep the name it already shows.
      text: result.text.slice(0, 500),
      toolCallId: callId,
      toolStatus: result.failed ? "failed" : "completed",
    };
  }

  return null;
}

/**
 * Translate a run of host history records into the transcript vocabulary.
 *
 * A record is `{ type: "event", event: { type, seq, time, data } }`; the
 * wrapper is unwrapped here and the inner event is translated.
 */
export function dshHostHistoryUpdates(sessionId: string, records: unknown): SessionUpdate[] {
  if (!Array.isArray(records)) return [];
  const out: SessionUpdate[] = [];
  for (const record of records) {
    const row = readRecord(record);
    const inner = row?.["type"] === "event" ? row["event"] : row;
    const update = dshHostEventToUpdate(sessionId, inner);
    if (update) out.push(update);
  }
  return out;
}

/** List the host's threads. */
export async function listDshHostSessions(
  client: DshHostClient,
  options: { readonly limit?: number; readonly cwd?: string } = {},
): Promise<SessionSummary[]> {
  const value = await client.call("session/list", { _request: {} });
  const limit = options.limit ?? 100;
  const summaries = dshHostSessionSummaries(value, limit);
  if (!options.cwd) return summaries;
  return summaries.filter((row) => row.cwd === options.cwd);
}

/**
 * Read one thread's history from the host.
 *
 * The history rides the `session/follow` stream: its opening snapshot carries
 * the whole committed log, and the stream then stays open for live events.
 * The client reads the snapshot and cancels, so a replay costs one stream
 * rather than a page walk.
 */
export async function loadDshHostHistory(
  client: DshHostClient,
  options: { readonly sessionId: string; readonly limit?: number },
): Promise<SessionUpdate[]> {
  const maxMessages = options.limit ?? 200;
  const stream = client.stream("session/follow", {
    address: { kind: "session", sessionId: options.sessionId },
    maxMessages,
  });
  for await (const frame of stream) {
    const row = readRecord(frame);
    if (row?.["type"] !== "snapshot") continue;
    const records = row["records"];
    return dshHostHistoryUpdates(options.sessionId, records);
  }
  return [];
}
