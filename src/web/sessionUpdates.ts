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
  | "tool_call_update"
  | "plan";

/**
 * One entry in the engine's execution plan.
 *
 * The engine reports the whole plan every time it changes, so a client shows
 * the list it was given rather than patching the one it had.
 */
export interface PlanEntry {
  /** What the entry says, as the engine wrote it. */
  content: string;
  /** The engine's priority for the entry. */
  priority: "high" | "medium" | "low";
  /** Where the entry stands. */
  status: "pending" | "in_progress" | "completed";
}

/** One replayed transcript entry. */
export interface SessionUpdate {
  sessionId: string;
  kind: SessionUpdateKind;
  text: string;
  toolCallId?: string;
  toolStatus?: "running" | "completed" | "failed";
  /**
   * The call this one ran under.
   *
   * A tool that runs other tools is the parent of them, and the clients
   * show that as a tree: the children hang under the call that made them.
   */
  parentToolCallId?: string;
  /**
   * What the tool was asked to do, as the engine wrote it.
   *
   * The name says which tool ran; this says what it was asked, which is the
   * part a person reading the thread actually wants.
   */
  toolInput?: string;
  /** The plan entries, for a `plan` update.  An empty list means the plan is gone. */
  plan?: PlanEntry[];
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
          // The relation and the input belong to the call, so a later update
          // that does not carry them does not erase them.
          ...(entry.parentToolCallId ?? kept.parentToolCallId
            ? { parentToolCallId: entry.parentToolCallId ?? kept.parentToolCallId }
            : {}),
          ...(entry.toolInput ?? kept.toolInput ? { toolInput: entry.toolInput ?? kept.toolInput } : {}),
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
