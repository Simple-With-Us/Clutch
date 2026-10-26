/**
 * Run a turn in the dsh host.
 *
 * The dsh-hosted engines (DeepSeek, MiniMax) live in the host: it owns their
 * threads, their plan, their tool calls and their approval requests.  The
 * sidecar drives that runtime over the host contract, so a native client sees
 * the same turn the web canvas sees, and the two are one interface rather
 * than two.
 *
 * The event stream is opened before the prompt is sent, so no event of the
 * turn is missed, and the turn ends with the host's own `turn/end` event.
 */

import { randomUUID } from "node:crypto";
import { DshHostClient } from "./dshHostClient.ts";
import { dshHostEventToUpdate } from "./dshHostSessions.ts";
import type { SessionUpdate } from "./sessionUpdates.ts";

/** One image to send with a prompt. */
export interface DshHostImage {
  readonly mediaType: string;
  readonly data: string;
  readonly name?: string;
}

/** How a turn ended, in the vocabulary the clients already speak. */
export interface DshHostTurnResult {
  readonly stopReason: string;
}

/** Read one record out of an unknown value, or null. */
function readRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

/**
 * The host's reason for ending a turn, in the clients' vocabulary.
 *
 * The host names the reasons its agent loop knows; the clients know ACP's
 * three, and show anything else as the turn's ending.  A turn that completed
 * is the only one that reads as a normal end.
 */
function turnEndReason(value: unknown): string {
  const reason = readRecord(value);
  const kind = typeof reason?.["kind"] === "string" ? (reason["kind"] as string) : "";
  if (kind === "completed") return "end_turn";
  if (kind === "aborted") return "cancelled";
  return kind || "end_turn";
}

/**
 * Open a thread in the host.
 *
 * The host names every session it owns, so a thread the sidecar starts is a
 * host thread: it shows up in the host's own list, it survives a restart of
 * the sidecar, and the next turn can resume it.
 */
export async function createDshHostSession(
  client: DshHostClient,
  options: { readonly cwd: string; readonly agentPreset?: string },
): Promise<string> {
  const value = await client.call("session/create", {
    cwd: options.cwd,
    ...(options.agentPreset ? { agentPreset: options.agentPreset } : {}),
  });
  const sessionId = readRecord(value)?.["sessionId"];
  if (typeof sessionId !== "string" || sessionId.length === 0) {
    throw new Error("the host created a session without naming it");
  }
  return sessionId;
}

/**
 * Run one turn in the host and report what it produced.
 *
 * The turn's events arrive on the session's own stream: the transcript, the
 * plan, and the tool calls are all translated into the one vocabulary the
 * clients render, so a DeepSeek thread and a MiniMax Code thread look the
 * same to the phone.
 */
export async function runDshHostTurn(
  client: DshHostClient,
  options: {
    readonly sessionId: string;
    readonly prompt: string;
    readonly images?: readonly DshHostImage[];
    readonly onUpdate: (update: SessionUpdate) => void;
    readonly signal?: AbortSignal;
  },
): Promise<DshHostTurnResult> {
  const { sessionId, prompt, onUpdate } = options;
  const stream = client.stream(
    "session/follow",
    {
      address: { kind: "session", sessionId },
      // The opening window is the thread's history, which the client already
      // has; this turn is read from the live events alone.
      maxMessages: 0,
    },
    // A cancelled turn must not leave the host holding the session open for
    // a stream nobody reads.
    options.signal ? { signal: options.signal } : {},
  );
  const iterator = stream[Symbol.asyncIterator]();

  let settleTurn!: (reason: string) => void;
  let failure: Error | null = null;
  const finished = new Promise<string>((resolve) => {
    settleTurn = resolve;
  });

  const pump = (async (): Promise<void> => {
    try {
      for (;;) {
        const step = await iterator.next();
        if (step.done) break;
        const frame = readRecord(step.value);
        if (!frame) continue;
        // The opening snapshot is the thread's history, not this turn.
        if (frame["type"] === "snapshot") continue;
        const inner = frame["type"] === "event" ? readRecord(frame["event"]) : frame;
        const type = inner?.["type"];
        if (type === "turn/end") {
          settleTurn(turnEndReason(readRecord(inner?.["data"])?.["reason"]));
          return;
        }
        const update = dshHostEventToUpdate(sessionId, inner);
        if (update) onUpdate(update);
      }
      // The stream ended without the turn ending: the host dropped it.
      settleTurn("cancelled");
    } catch (err) {
      failure = err instanceof Error ? err : new Error(String(err));
      settleTurn("cancelled");
    }
  })();

  const content: Array<Record<string, unknown>> = [{ type: "text", text: prompt }];
  for (const image of options.images ?? []) {
    content.push({
      type: "image",
      mediaType: image.mediaType,
      data: image.data,
      ...(image.name ? { name: image.name } : {}),
    });
  }

  const abort = (): void => settleTurn("cancelled");
  options.signal?.addEventListener("abort", abort, { once: true });
  try {
    await client.call("session/prompt", {
      requestId: `clutch-${randomUUID()}`,
      sessionId,
      mode: "queue",
      content,
    });
    const stopReason = await finished;
    if (failure) throw failure;
    return { stopReason };
  } finally {
    options.signal?.removeEventListener("abort", abort);
    // Stops the host from holding the session open for a stream nobody
    // reads.  The wait is bounded: a stream that does not end on its own
    // must not hold the turn open after the owner stopped it.
    await Promise.race([iterator.return?.(), deadline(CLEANUP_TIMEOUT_MS)]);
    await Promise.race([pump.catch(() => undefined), deadline(CLEANUP_TIMEOUT_MS)]);
  }
}

/** How long the turn waits for its own cleanup before letting go. */
const CLEANUP_TIMEOUT_MS = 250;

/** A promise that settles after the given time, or immediately when raced. */
function deadline(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    timer.unref?.();
  });
}
