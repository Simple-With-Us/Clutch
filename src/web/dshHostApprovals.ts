/**
 * Relaying the dsh host's approval requests to a client that can answer them.
 *
 * The host asks for approval through a waterfall: a tool wants something the
 * sandbox will not do on its own, and the host hands the question to every
 * client connected to its event stream.  The answer comes back over a unary
 * endpoint, correlated by the id the question carried.
 *
 * The sidecar is one of those clients, and it is the only one the native apps
 * can reach: they speak the sidecar's contract, never the host's.  So the
 * relay opens the host's event stream once, hands each approval to the turn
 * that owns it, and puts the client's decision back on the wire.
 *
 * A request that no turn owns is left alone.  The host serves the web canvas
 * from the same stream, so a question that belongs to a thread the owner is
 * driving in a browser is that browser's to answer; the sidecar answering it
 * would take the question away from the person looking at it.
 *
 * The host is a program on a version of its own, so every frame is parsed
 * against the shape the installed build declares rather than trusted: see
 * `tests/dsh-host-pinned.test.ts`.
 */

import { z } from "zod";

import {
  DSH_HOST_EVENT_RESULT_ENDPOINT,
  DSH_HOST_EVENT_STREAM_ENDPOINT,
} from "../shared/dshHostContract.ts";
import type { DshHostClient } from "./dshHostClient.ts";

/** The answers the host's approval waterfall accepts. */
export type HostApprovalOutcome = "allowed-once" | "rejected" | "cancelled" | "unavailable";

/** The event name the host asks an approval under. */
export const HOST_APPROVAL_EVENT = "approval/request";

/** One approval request the host is waiting on. */
export interface HostApproval {
  /** The id the answer must carry. */
  readonly eventId: string;
  /** The session the request belongs to; the host's agent id is its session id. */
  readonly agentId: string;
  /** The tool that wants the permission. */
  readonly toolName: string;
  /** The tool call the request is about, when the host named one. */
  readonly callId?: string;
  /** Why the tool wants the permission, in the host's words. */
  readonly reason?: string;
}

/** How the relay reaches the host. */
export type DshHostClientProvider = () => Promise<DshHostClient>;

/** How the relay is wired to the rest of the sidecar. */
export interface DshHostApprovalRelayOptions {
  /** The host client, fetched again when the host restarts. */
  readonly client: DshHostClientProvider;
  /** Called for every approval the host asks. */
  readonly onApproval: (approval: HostApproval) => void;
  /** Called when the host settled a request elsewhere, so a stale card can go. */
  readonly onSettled?: (eventId: string) => void;
  /** Where the relay's own diagnostics go. */
  readonly onLog?: (message: string) => void;
}

/** How long the relay waits before opening the event stream again. */
const RECONNECT_DELAY_MS = 2_000;

/** How long a caller waits for the host to open the event stream. */
const READY_TIMEOUT_MS = 5_000;

/** The opening frame, which names the generation later answers belong to. */
const ReadyFrameSchema = z
  .object({
    type: z.literal("ready"),
    clientId: z.string().min(1),
  })
  .loose();

/** One question the host is asking the clients. */
const WaterfallFrameSchema = z
  .object({
    type: z.literal("waterfall"),
    event: z.string().min(1),
    eventId: z.string().min(1),
    agentId: z.string().min(1),
    request: z.record(z.string(), z.unknown()),
  })
  .loose();

/** The frame that says a question is no longer waiting. */
const CancelFrameSchema = z
  .object({
    type: z.literal("cancel"),
    eventId: z.string().min(1),
  })
  .loose();

/** The part of an approval request the clients show. */
const ApprovalRequestSchema = z
  .object({
    toolName: z.string().min(1),
    callId: z.string().min(1).optional(),
    reason: z.string().optional(),
  })
  .loose();

/** Read one property of an object, or null when it is not an object. */
function readRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

/** The message of a failure, without a stack. */
function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** A promise that never settles on its own. */
function forever<T>(): { promise: Promise<T>; resolve(value: T): void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((settle) => {
    resolve = settle;
  });
  return { promise, resolve };
}

/**
 * The sidecar's end of the host's approval channel.
 *
 * One relay serves every host turn: the event stream is opened once and kept
 * open, because a question is asked of every connected client at once and a
 * per-turn stream would open a generation of its own for each one.
 */
export class DshHostApprovalRelay {
  /** The generation the answers belong to, per question. */
  private readonly generations = new Map<string, string>();

  private readonly stopped = forever<void>();

  /** Resolved when the host has named this stream's generation. */
  private readonly becameReady = forever<void>();

  /** Whether the relay was stopped. */
  private halted = false;

  private running: Promise<void> | null = null;

  private constructor(private readonly options: DshHostApprovalRelayOptions) {}

  /** Open the relay and start reading the host's events. */
  static start(options: DshHostApprovalRelayOptions): DshHostApprovalRelay {
    const relay = new DshHostApprovalRelay(options);
    relay.running = relay.loop();
    return relay;
  }

  /** Stop reading. The host is told the stream is no longer wanted. */
  stop(): void {
    this.halted = true;
    this.stopped.resolve();
  }

  /** Settles when the relay has stopped reading. */
  async done(): Promise<void> {
    await this.running;
  }

  /**
   * Wait until the host has named this stream's generation.
   *
   * A turn that starts before the relay is listening loses the questions the
   * host asks during it, so the caller waits for the opening frame.  The wait
   * is bounded: a host that never answers must not hold a turn hostage.
   */
  async ready(timeoutMs = READY_TIMEOUT_MS): Promise<boolean> {
    return Promise.race([
      this.becameReady.promise.then(() => true),
      new Promise<boolean>((resolve) => {
        const timer = setTimeout(() => resolve(false), timeoutMs);
        timer.unref?.();
      }),
    ]);
  }

  /**
   * Answer one question the host asked.
   *
   * The answer names the generation the question arrived in, because the host
   * only accepts an answer from a client that was actually given the
   * question.  A question that was already settled — by another client, or by
   * the host itself — is refused rather than sent again.
   */
  async answer(eventId: string, outcome: HostApprovalOutcome): Promise<boolean> {
    const generation = this.generations.get(eventId);
    if (!generation) return false;
    const client = await this.options.client();
    await client.call(DSH_HOST_EVENT_RESULT_ENDPOINT, {
      clientId: generation,
      eventId,
      outcome: { kind: "result", value: outcome },
    });
    this.generations.delete(eventId);
    return true;
  }

  /**
   * Read the host's events until the relay is stopped.
   *
   * The host is a separate process that may restart, so the stream is opened
   * again when it ends; the questions that were open when it ended are gone
   * with it, and their answers would be refused by the host anyway.
   */
  private async loop(): Promise<void> {
    while (true) {
      try {
        const client = await this.options.client();
        await this.read(client);
      } catch (err) {
        this.log(`approval relay stopped reading: ${messageOf(err)}`);
      }
      if (await this.settled()) return;
      await this.wait(RECONNECT_DELAY_MS);
    }
  }

  /** Read one generation of the host's event stream. */
  private async read(client: DshHostClient): Promise<void> {
    const stream = client.stream(DSH_HOST_EVENT_STREAM_ENDPOINT, {});
    const iterator = stream[Symbol.asyncIterator]();
    try {
      for (;;) {
        const step = await Promise.race([iterator.next(), this.stopped.promise.then(() => null)]);
        // The relay was stopped while the host had nothing to say.
        if (step === null) return;
        if (step.done) return;
        this.handle(step.value);
      }
    } finally {
      // Tells the host the stream is no longer wanted.
      await iterator.return?.();
    }
  }

  /** Read one frame from the host's event stream. */
  private handle(value: unknown): void {
    const row = readRecord(value);
    const type = row?.["type"];

    if (type === "ready") {
      const parsed = ReadyFrameSchema.safeParse(value);
      if (!parsed.success) return;
      this.generation = parsed.data.clientId;
      this.becameReady.resolve();
      this.log(`approval relay ready client=${parsed.data.clientId}`);
      return;
    }

    if (type === "waterfall") {
      const parsed = WaterfallFrameSchema.safeParse(value);
      if (!parsed.success) return;
      const frame = parsed.data;
      // Only approvals are relayed.  The host forwards other questions the
      // same way, and they belong to the client that asked for them.
      if (frame.event !== HOST_APPROVAL_EVENT) return;
      const request = ApprovalRequestSchema.safeParse(frame.request);
      if (!request.success) return;
      this.generations.set(frame.eventId, this.currentGeneration());
      this.options.onApproval({
        eventId: frame.eventId,
        agentId: frame.agentId,
        toolName: request.data.toolName,
        ...(request.data.callId ? { callId: request.data.callId } : {}),
        ...(request.data.reason ? { reason: request.data.reason } : {}),
      });
      return;
    }

    if (type === "cancel") {
      const parsed = CancelFrameSchema.safeParse(value);
      if (!parsed.success) return;
      // The question was settled elsewhere — by the web canvas, or by the
      // host itself — so the card the client is holding is stale.
      this.generations.delete(parsed.data.eventId);
      this.options.onSettled?.(parsed.data.eventId);
    }
  }

  /**
   * The generation the questions of this stream belong to.
   *
   * The host mints one id per event stream and hands it out in the opening
   * frame, so a question is answered by the generation that delivered it.
   */
  private currentGeneration(): string {
    return this.generation;
  }

  /** The generation of the event stream that is open now. */
  private generation = "";

  /** Whether the relay has been stopped. */
  private async settled(): Promise<boolean> {
    return this.halted;
  }

  /** Wait, unless the relay is stopped first. */
  private async wait(ms: number): Promise<void> {
    await Promise.race([
      new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, ms);
        timer.unref?.();
      }),
      this.stopped.promise,
    ]);
  }

  private log(message: string): void {
    this.options.onLog?.(message);
  }
}
