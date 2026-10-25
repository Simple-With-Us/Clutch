/**
 * The transcript vocabulary both engine backends speak.
 *
 * The native apps render one shape, whatever engine produced the thread.  The
 * ACP code engines already speak it; the dsh host's own session graph is
 * translated into it by `dshHostSessions.ts`, so a DeepSeek thread and a
 * MiniMax Code thread are indistinguishable to the client.
 *
 * The kinds match the ones ACP's `session/update` carries, because that is
 * what the clients already render.
 */

/** The kinds a transcript entry can carry. */
export type SessionUpdateKind =
  | "agent_message_chunk"
  | "agent_thought_chunk"
  | "user_message_chunk"
  | "tool_call"
  | "tool_call_update";

/** One replayed transcript entry. */
export interface SessionUpdate {
  sessionId: string;
  kind: SessionUpdateKind;
  text: string;
  toolCallId?: string;
  toolStatus?: "running" | "completed" | "failed";
}

/** ACP tool-call status as the clients render it. */
export function toolStatusOf(raw: unknown): "running" | "completed" | "failed" {
  switch (raw) {
    case "completed":
      return "completed";
    case "failed":
      return "failed";
    default:
      return "running"; // pending, in_progress, missing — still in flight
  }
}

/**
 * Collapse a replayed history's tool updates into one entry per call: the
 * first `tool_call` keeps its name, later updates only move its status.
 * Without this a single file write replays as a stack of identical cards.
 */
export function compactToolHistory(history: readonly SessionUpdate[]): SessionUpdate[] {
  const out: SessionUpdate[] = [];
  const byId = new Map<string, number>();
  for (const entry of history) {
    if (entry.kind === "tool_call" || entry.kind === "tool_call_update") {
      const id = entry.toolCallId ?? "";
      const existing = id ? byId.get(id) : undefined;
      const kept = existing !== undefined ? out[existing] : undefined;
      if (existing !== undefined && kept) {
        out[existing] = {
          ...kept,
          text: kept.text || entry.text,
          toolStatus: entry.toolStatus ?? kept.toolStatus ?? "running",
        };
        continue;
      }
      if (id) byId.set(id, out.length);
      out.push(entry);
      continue;
    }
    out.push(entry);
  }
  return out;
}
