/**
 * The host's end of the Live Activity push relay.
 *
 * A Live Activity is updated by the app while the app is in the foreground.
 *  A phone that has put the app in the background stops updating it, and the
 * island then says something that is no longer true.  The relay is what keeps
 * it true:  the sidecar knows which threads are waiting on the owner and
 * which are running, and it pushes that state to the phone the activity
 * belongs to.
 *
 * Three parts live here:
 *
 *   - the store of the phone's registrations (which activity, which device,
 *     which push token), kept in `$CLUTCH_HOME/activity-tokens.json`;
 *   - the builder of the content state, which mirrors the phone's own split
 *     of waiting and running work;
 *   - the relay, which decides when a push is worth making.
 *
 * What the payload may carry is the whole point of the feature, so the rules
 * are narrow:  counts, thread titles and a status, and nothing about the
 * request itself.  A tool name, a reason, a call id, a working directory, a
 * command and a diff never reach a surface the owner sees without opening
 * the app, so the builder writes the fields it knows and copies nothing.
 */

import { chmodSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { dirname } from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";

import { z } from "zod";

import type { ApnsEnvironment, ApnsPushResult } from "./apnsClient.ts";

/** The route the phone registers its push tokens on. */
export const ACTIVITY_TOKENS_PATH = "/clutch/v1/activity-tokens";

/** How many registrations the host keeps. */
export const MAX_ACTIVITY_TOKENS = 64;

/** How long a push token is good for, as the phone tells it. */
const MAX_TOKEN_LENGTH = 512;

/**
 * The shortest interval between two pushes to the same token.
 *
 * A turn can report itself many times a second, and the phone's state only
 * changes when the counts or the threads change, so the pushes are coalesced
 * into one every two seconds.
 */
export const ACTIVITY_PUSH_MIN_INTERVAL_MS = 2_000;

/** The retries a transiently failing push gets before the relay waits for the next state change. */
export const ACTIVITY_PUSH_TRANSIENT_RETRIES = 2;

/** The base wait between retry attempts, doubled per attempt. */
export const ACTIVITY_PUSH_RETRY_BASE_MS = 15_000;

/**
 * Whether APNs said "the same push may go through later".
 *
 * Zero is the transport failure the client reports for a socket that never
 * answered, 429 is Apple's throttle and 503 is its own server;  anything
 * else, 410 for an unregistered token above all, says the push itself is
 * the problem and a retry would fail the same way.
 */
export function isTransientPushStatus(status: number): boolean {
  return status === 0 || status === 429 || status === 503;
}

/** The attributes type the payload names. */
export const ACTIVITY_ATTRIBUTES_TYPE = "ClutchActivityAttributes";

/**
 * Seconds between the Unix epoch and Apple's default Date reference.
 *
 * ActivityKit decodes the content-state of a push with its standard
 * strategies, and the standard strategy for a `Date` is seconds since
 * 2001-01-01.  The host stamps `updatedAt` on that scale so the phone
 * reads the moment the host meant; a custom Codable here would be
 * ignored by the system, not honoured.
 */
export const APPLE_REFERENCE_DATE_OFFSET_SECONDS = 978_307_200;

/** One registration, as the phone sends it. */
export const ActivityTokenRegistrationSchema = z
  .object({
    deviceUid: z.string().min(1).max(200),
    activityId: z.string().min(1).max(200),
    pushToken: z.string().regex(/^[0-9a-fA-F]+$/).min(64).max(MAX_TOKEN_LENGTH),
    environment: z.enum(["Sandbox", "Production"]),
    sessionId: z.string().min(1).max(200),
    attributes: z.record(z.string(), z.unknown()).optional(),
    // Proof of possession:  the push token the phone already holds, so a
    // bearer holder cannot overwrite another phone's registration without
    // knowing its token.  Optional on first registration; required to
    // replace one that is already stored.
    previousPushToken: z.string().optional(),
  })
  .strict();

/** The body that takes a registration away again. */
export const ActivityTokenRemovalSchema = z
  .object({
    deviceUid: z.string().min(1).max(200),
    activityId: z.string().min(1).max(200),
    sessionId: z.string().min(1).max(200).optional(),
    // Proof of possession:  the push token being removed, so a bearer holder
    // cannot silence another phone's activity without knowing its token.
    pushToken: z.string().optional(),
  })
  .strict();

/** One registration, as the host keeps it. */
export interface ActivityTokenRegistration {
  /** The phone this registration belongs to. */
  readonly deviceUid: string;
  /** The Live Activity the token pushes to. */
  readonly activityId: string;
  /** The push token, in hex.  A secret:  never logged, never echoed. */
  readonly pushToken: string;
  /** Which APNs the token belongs to. */
  readonly environment: ApnsEnvironment;
  /** The phone's own session, so a later launch can tell a new one from an old one. */
  readonly sessionId: string;
  /** The activity's static attributes, as the phone registered them. */
  readonly attributes: Record<string, unknown>;
  /** When the registration was last written, in epoch milliseconds. */
  readonly updatedAt: number;
}

/** The shape of the file the registrations live in. */
interface ActivityTokenFile {
  version: 1;
  tokens: ActivityTokenRegistration[];
}

/** Read one registration off disk, or null when it is not usable. */
function parseRegistration(value: unknown): ActivityTokenRegistration | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  const parsed = ActivityTokenRegistrationSchema.safeParse({
    deviceUid: row["deviceUid"],
    activityId: row["activityId"],
    pushToken: row["pushToken"],
    environment: row["environment"],
    sessionId: row["sessionId"],
    ...(row["attributes"] && typeof row["attributes"] === "object" && !Array.isArray(row["attributes"])
      ? { attributes: row["attributes"] }
      : {}),
  });
  if (!parsed.success) return null;
  const updatedAt = typeof row["updatedAt"] === "number" && Number.isFinite(row["updatedAt"]) ? row["updatedAt"] : 0;
  return {
    ...parsed.data,
    attributes: parsed.data.attributes ?? {},
    updatedAt,
  };
}

/** The key one registration is known by. */
function registrationKey(deviceUid: string, activityId: string): string {
  return `${deviceUid}|${activityId}`;
}

/**
 * The registrations the host keeps.
 *
 * The file holds push tokens, so it is written the way a secret is written:
 * owner-only, through a temporary file and a rename, so a crash never leaves
 * a half-written file behind.  The list is bounded, and the oldest
 * registration is the one that goes, because a phone that stopped pairing
 * should not keep a slot forever.
 */
export class ActivityTokenStore {
  constructor(
    private readonly file: string,
    private readonly maxEntries: number = MAX_ACTIVITY_TOKENS,
    private readonly now: () => number = Date.now,
  ) {}

  /** Every registration the host holds. */
  list(): ActivityTokenRegistration[] {
    let raw: string;
    try {
      raw = readFileSync(this.file, "utf8");
    } catch {
      return [];
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return [];
    }
    const tokens = (parsed as { tokens?: unknown } | null)?.tokens;
    if (!Array.isArray(tokens)) return [];
    const out: ActivityTokenRegistration[] = [];
    for (const entry of tokens) {
      const registration = parseRegistration(entry);
      if (registration) out.push(registration);
    }
    return out;
  }

  /** Write one registration, replacing the one it supersedes. */
  put(
    registration: Omit<ActivityTokenRegistration, "updatedAt" | "attributes"> & {
      updatedAt?: number;
      attributes?: Record<string, unknown>;
    },
  ): ActivityTokenRegistration {
    const entry: ActivityTokenRegistration = {
      deviceUid: registration.deviceUid,
      activityId: registration.activityId,
      pushToken: registration.pushToken,
      environment: registration.environment,
      sessionId: registration.sessionId,
      // The attributes type Clutch ships carries no stored attributes, so
      // the host pushes the empty set whatever the phone sent:  a field
      // the island can show never comes from the request body.
      attributes: {},
      updatedAt: registration.updatedAt ?? this.now(),
    };
    const kept = this.list().filter(
      (row) => registrationKey(row.deviceUid, row.activityId) !== registrationKey(entry.deviceUid, entry.activityId),
    );
    kept.push(entry);
    kept.sort((left, right) => left.updatedAt - right.updatedAt);
    this.write(kept.slice(Math.max(0, kept.length - this.maxEntries)));
    return entry;
  }

  /** Take one registration away.  Returns whether there was one. */
  remove(deviceUid: string, activityId: string): boolean {
    const all = this.list();
    const kept = all.filter(
      (row) => registrationKey(row.deviceUid, row.activityId) !== registrationKey(deviceUid, activityId),
    );
    if (kept.length === all.length) return false;
    this.write(kept);
    return true;
  }

  /** Write the registrations out, atomically and owner-only. */
  private write(tokens: ActivityTokenRegistration[]): void {
    const body = `${JSON.stringify({ version: 1, tokens } satisfies ActivityTokenFile, null, 2)}\n`;
    mkdirSync(dirname(this.file), { recursive: true, mode: 0o700 });
    const tmp = `${this.file}.${process.pid}.${randomBytes(6).toString("hex")}`;
    writeFileSync(tmp, body, { mode: 0o600 });
    try {
      renameSync(tmp, this.file);
    } catch {
      try {
        unlinkSync(tmp);
      } catch {
        /* the temporary file is already gone */
      }
      throw new Error("the activity token file could not be written");
    }
    // The rename moves the temporary file into place whole, so the file
    // carries the owner-only mode it was written with; the chmod is the
    // same belt at the braces for a filesystem that changed it between.
    try {
      chmodSync(this.file, 0o600);
    } catch {
      /* the file is owner-only on every platform Clutch runs on */
    }
  }
}

/** One approval the engine is waiting on. */
export interface ActivityThreadApproval {
  /** The host the approval came from. */
  readonly hostId: string;
  /** The thread the approval belongs to. */
  readonly sessionId: string;
  /** The request the approval is about. */
  readonly requestId: string;
  /** The thread's name, and nothing else about the request. */
  readonly title: string;
}

/** One turn that is running. */
export interface ActivityThreadRun {
  /** The host the run belongs to. */
  readonly hostId: string;
  /** The thread the run belongs to. */
  readonly sessionId: string;
  /** The thread's name, and nothing else about the turn. */
  readonly title: string;
}

/** One session as the island shows it. */
export interface ActivitySessionSummary {
  readonly id: string;
  readonly title: string;
  readonly status: "waiting" | "running";
}

/** The state the Live Activity carries. */
export interface ActivityContentState {
  readonly waitingCount: number;
  readonly runningCount: number;
  readonly sessions: ActivitySessionSummary[];
  /** When the state was written, in seconds since 2001-01-01 — Apple's default Date coding. */
  readonly updatedAt: number;
}

/** The key a thread is known by:  the host and the session. */
export function activityThreadKey(hostId: string, sessionId: string): string {
  return `${hostId}|${sessionId}`;
}

/**
 * The waiting and the running work, with the overlap taken out.
 *
 * This mirrors the phone's own split (see `ClutchActivityWork`):  a thread
 * that is waiting on the owner is blocked, not working, so it is counted
 * once, as waiting; and a thread that waits on two requests is one thread
 * and one row.
 */
export function splitActivityThreads(
  approvals: readonly ActivityThreadApproval[],
  runs: readonly ActivityThreadRun[],
): { waiting: ActivityThreadApproval[]; running: ActivityThreadRun[] } {
  const waiting: ActivityThreadApproval[] = [];
  const waitingThreads = new Set<string>();
  for (const approval of approvals) {
    const key = activityThreadKey(approval.hostId, approval.sessionId);
    if (waitingThreads.has(key)) continue;
    waitingThreads.add(key);
    waiting.push(approval);
  }
  const running = runs.filter((run) => !waitingThreads.has(activityThreadKey(run.hostId, run.sessionId)));
  return { waiting, running };
}

/**
 * The state the island shows.
 *
 * The counts are the totals, so a summary never lies about how much is
 * waiting because only three sessions fit.  The sessions are the ones that
 * matter first (an approval before a run), and there are three of them,
 * because the island shows three lines and a fourth would be a line nobody
 * reads.
 */
export function buildActivityContentState(
  approvals: readonly ActivityThreadApproval[],
  runs: readonly ActivityThreadRun[],
  updatedAtSeconds: number,
): ActivityContentState {
  const { waiting, running } = splitActivityThreads(approvals, runs);
  const sessions: ActivitySessionSummary[] = [
    ...waiting.map((approval) => ({ id: approval.sessionId, title: approval.title, status: "waiting" as const })),
    ...running.map((run) => ({ id: run.sessionId, title: run.title, status: "running" as const })),
  ].slice(0, 3);
  return {
    waitingCount: waiting.length,
    runningCount: running.length,
    sessions,
    // The argument is Unix seconds; the wire is Apple's reference-date
    // seconds (see APPLE_REFERENCE_DATE_OFFSET_SECONDS).
    updatedAt: updatedAtSeconds - APPLE_REFERENCE_DATE_OFFSET_SECONDS,
  };
}

/** The payload of one Live Activity push. */
export interface LiveActivityPushPayload {
  readonly aps: {
    readonly event: "update" | "end";
    readonly timestamp: number;
    readonly "dismissal-date"?: number;
    readonly "attributes-type": string;
    readonly attributes: Record<string, unknown>;
    readonly "content-state": ActivityContentState;
  };
}

/**
 * Build the payload of one Live Activity push.
 *
 * The payload is written field by field:  nothing is copied out of an
 * arbitrary object, so a tool name or a working directory has no way into it
 * even when the state it is built from carries one.
 */
export function buildLiveActivityPayload(input: {
  readonly event: "update" | "end";
  readonly timestampSeconds: number;
  readonly dismissalDateSeconds?: number;
  readonly attributes: Record<string, unknown>;
  readonly contentState: ActivityContentState;
}): LiveActivityPushPayload {
  return {
    aps: {
      event: input.event,
      timestamp: input.timestampSeconds,
      ...(input.dismissalDateSeconds === undefined ? {} : { "dismissal-date": input.dismissalDateSeconds }),
      "attributes-type": ACTIVITY_ATTRIBUTES_TYPE,
      attributes: input.attributes,
      "content-state": input.contentState,
    },
  };
}

/**
 * What the state compares as.
 *
 * The timestamp is not part of the comparison:  it records when the state was
 * written, not what it says, and a state that says the same thing is not
 * worth a push.
 */
export function comparableActivityState(state: ActivityContentState): string {
  return JSON.stringify({
    waitingCount: state.waitingCount,
    runningCount: state.runningCount,
    sessions: state.sessions,
  });
}

/** What the sidecar knows about the work, as the relay sees it. */
export interface ActivitySnapshot {
  readonly approvals: ActivityThreadApproval[];
  readonly runs: ActivityThreadRun[];
}

/** How a push is made. */
export interface ActivityPushSender {
  sendLiveActivity(request: {
    readonly deviceToken: string;
    readonly environment: ApnsEnvironment;
    readonly payload: LiveActivityPushPayload;
    readonly expirationSeconds?: number;
    readonly priority?: 5 | 10;
  }): Promise<ApnsPushResult>;
}

/** How the relay is wired to the rest of the sidecar. */
export interface ActivityPushRelayOptions {
  /** Where the registrations live. */
  readonly store: ActivityTokenStore;
  /** What the sidecar knows about the work. */
  readonly snapshot: () => ActivitySnapshot | Promise<ActivitySnapshot>;
  /** How a push is made;  none means the relay is disabled. */
  readonly sender?: ActivityPushSender | null;
  /** Whether the relay pushes at all. */
  readonly enabled?: boolean;
  /** The clock, so the relay can be tested. */
  readonly now?: () => number;
  /** The shortest interval between two pushes to the same token. */
  readonly minIntervalMs?: number;
  /** The retries a transiently failing push gets. */
  readonly retryLimit?: number;
  /** The base wait between retry attempts;  doubled per attempt. */
  readonly retryBaseMs?: number;
  /** Where the relay's own diagnostics go. */
  readonly onLog?: (message: string) => void;
}

/**
 * The relay.
 *
 * It pushes when the sidecar's knowledge moved, it coalesces the pushes, and
 * it does not push a state the phone already has.  It never logs a token:
 * the diagnostics carry counts and statuses only.
 */
export class ActivityPushRelay {
  /** The state each token was last sent. */
  private readonly lastSent = new Map<string, string>();

  /** When each token was last pushed to. */
  private readonly lastSentAt = new Map<string, number>();

  /** The push that is waiting for the interval to pass, per token. */
  private readonly pending = new Map<string, ReturnType<typeof setTimeout>>();

  /** The state a waiting push will carry, per token. */
  private readonly pendingPayloads = new Map<string, { registration: ActivityTokenRegistration; payload: LiveActivityPushPayload; comparable: string }>();

  /** The retries spent per token, so a persistent failure stops hammering. */
  private readonly attempts = new Map<string, number>();

  /** The state each token's retry count belongs to:  a new state re-arms it. */
  private readonly attemptState = new Map<string, string>();

  /** How many times cancelPending has superseded a token, per token.  A send
   *  whose generation no longer matches is stale and must not record lastSent. */
  private readonly generations = new Map<string, number>();

  /** The pushes that are in flight. */
  private readonly inFlight = new Set<Promise<void>>();

  constructor(private readonly options: ActivityPushRelayOptions) {}

  /** Whether the relay pushes. */
  get enabled(): boolean {
    return (this.options.enabled ?? true) && this.options.sender !== null && this.options.sender !== undefined;
  }

  /** The registrations the host holds. */
  list(): ActivityTokenRegistration[] {
    return this.options.store.list();
  }

  /** Write one registration down and tell the phone it is known. */
  register(
    registration: Omit<ActivityTokenRegistration, "updatedAt" | "attributes"> & {
      updatedAt?: number;
      attributes?: Record<string, unknown>;
      /** Proof of possession:  the token the phone already holds, required to
       *  replace a registration that is already stored. */
      previousPushToken?: string;
    },
  ): ActivityTokenRegistration {
    const key = registrationKey(registration.deviceUid, registration.activityId);
    const existing = this.options.store.list().find((row) => registrationKey(row.deviceUid, row.activityId) === key);
    if (existing) {
      // Replacing a stored registration requires proof the caller holds the
      // token it replaces:  a bearer holder cannot steer another phone's
      // pushes without knowing its push token.
      if (!registration.previousPushToken || registration.previousPushToken !== existing.pushToken) {
        throw new Error("registration is already held by another device");
      }
    }
    return this.options.store.put(registration);
  }

  /** Take one registration away. */
  unregister(deviceUid: string, activityId: string, pushToken?: string): boolean {
    const key = registrationKey(deviceUid, activityId);
    const existing = this.options.store.list().find((row) => registrationKey(row.deviceUid, row.activityId) === key);
    if (existing) {
      // Removing a stored registration requires proof the caller holds its
      // token:  a bearer holder cannot silence another phone's pushes
      // without knowing its push token.
      if (!pushToken || pushToken !== existing.pushToken) return false;
    }
    this.cancelPending(key);
    this.lastSent.delete(key);
    this.lastSentAt.delete(key);
    return this.options.store.remove(deviceUid, activityId);
  }

  /** Drop whatever push is waiting for one token, and its retry count. */
  private cancelPending(key: string): void {
    const timer = this.pending.get(key);
    if (timer) {
      clearTimeout(timer);
      this.pending.delete(key);
    }
    this.pendingPayloads.delete(key);
    this.attempts.delete(key);
    this.attemptState.delete(key);
    // A cancel supersedes any in-flight send:  its generation is bumped so a
    // late success cannot pin a superseded state on the token.
    this.generations.set(key, (this.generations.get(key) ?? 0) + 1);
  }

  /**
   * Push the current state to every phone that asked for it.
   *
   * Called when the sidecar's knowledge moved:  an approval arrived, one was
   * answered, a turn started or a turn ended.
   */
  async notify(): Promise<void> {
    if (!this.enabled) return;
    const registrations = this.options.store.list();
    if (registrations.length === 0) return;
    let snapshot: ActivitySnapshot;
    try {
      snapshot = await this.options.snapshot();
    } catch {
      this.log("activity push skipped: the work snapshot could not be read");
      return;
    }
    const now = this.options.now?.() ?? Date.now();
    const timestampSeconds = Math.floor(now / 1000);
    const contentState = buildActivityContentState(snapshot.approvals, snapshot.runs, timestampSeconds);
    const comparable = comparableActivityState(contentState);
    for (const registration of registrations) {
      const key = registrationKey(registration.deviceUid, registration.activityId);
      // A state the phone already has is not worth a push — and a waiting
      // push of an older state must not go out after the work moved back,
      // or the island ends on a state that is no longer true.
      if (this.lastSent.get(key) === comparable) {
        this.cancelPending(key);
        continue;
      }
      const payload = buildLiveActivityPayload({
        event: "update",
        timestampSeconds,
        // Hard-coded, not read off the registration:  ClutchActivityAttributes
        // has no stored fields, so the only attributes the push may carry are
        // none, whatever a phone once said.
        attributes: {},
        contentState,
      });
      this.schedule(registration, payload, comparable, now);
    }
  }

  /**
   * Waits for the pushes that are in flight.
   *
   * A caller that has to know the state has gone out waits for this, rather
   * than for a timer it cannot see.
   */
  async settled(): Promise<void> {
    while (this.inFlight.size > 0) {
      await Promise.all([...this.inFlight].map((push) => push.catch(() => undefined)));
    }
  }

  /**
   * Make one push, now or as soon as the interval allows.
   *
   * The interval keeps a busy turn from turning into a burst of pushes:  a
   * later change replaces the payload that waits, so the push that finally
   * goes out carries the newest state, not the one from when the wait began.
   */
  private schedule(
    registration: ActivityTokenRegistration,
    payload: LiveActivityPushPayload,
    comparable: string,
    now: number,
  ): void {
    const key = registrationKey(registration.deviceUid, registration.activityId);
    // A push carrying this state is already waiting:  it will carry the
    // newest state, so there is nothing to add.
    if (this.pendingPayloads.get(key)?.comparable === comparable) return;
    // A state the phone does not have yet starts its own attempt cycle.  A
    // state whose retries are already spent waits for a real change rather
    // than getting a fresh budget from every call that re-observes it.
    if (this.attemptState.get(key) !== comparable) {
      this.attempts.delete(key);
      this.attemptState.set(key, comparable);
    } else if ((this.attempts.get(key) ?? 0) >= (this.options.retryLimit ?? ACTIVITY_PUSH_TRANSIENT_RETRIES)) {
      return;
    }
    const minInterval = this.options.minIntervalMs ?? ACTIVITY_PUSH_MIN_INTERVAL_MS;
    const last = this.lastSentAt.get(key);
    // A newer state must not wait out a stale retry backoff: clear the old
    // timer and re-time on the min-interval so fresh state is never delayed.
    if (this.pendingPayloads.get(key)?.comparable !== comparable && this.pending.has(key)) {
      const existing = this.pending.get(key);
      if (existing) {
        clearTimeout(existing);
        this.pending.delete(key);
      }
    }
    const wait = last === undefined ? 0 : Math.max(0, minInterval - (now - last));
    this.pendingPayloads.set(key, { registration, payload, comparable });
    if (wait === 0) {
      void this.send(key);
      return;
    }
    // A push is already waiting for this token:  it will carry the newest
    // state, so there is nothing to add.
    if (this.pending.has(key)) return;
    const timer = setTimeout(() => {
      this.pending.delete(key);
      void this.send(key);
    }, wait);
    timer.unref?.();
    this.pending.set(key, timer);
  }

  /** Make the push that is waiting for one token. */
  private send(key: string): Promise<void> {
    const running = this.runSend(key);
    this.inFlight.add(running);
    const cleanup = (): void => {
      this.inFlight.delete(running);
    };
    // Both hands on the promise, so a rejection can never be dropped:  the
    // sidecar is an always-on process, and an unhandled rejection ends it.
    void running.then(cleanup, cleanup);
    return running.catch(() => undefined);
  }

  /** The push itself. */
  private async runSend(key: string): Promise<void> {
    const waiting = this.pendingPayloads.get(key);
    if (!waiting) return;
    // A cancel while this send was in flight supersedes it:  capture the
    // generation now so a late success cannot pin a superseded state.
    const generation = this.generations.get(key) ?? 0;
    this.pendingPayloads.delete(key);
    this.attemptState.set(key, waiting.comparable);
    this.lastSentAt.set(key, this.options.now?.() ?? Date.now());
    const sender = this.options.sender;
    if (!sender) return;
    try {
      const result = await sender.sendLiveActivity({
        deviceToken: waiting.registration.pushToken,
        environment: waiting.registration.environment,
        payload: waiting.payload,
        // Apple budgets Live Activity pushes, and the island only needs to
        // snap awake for the owner:  a state where something waits gets the
        // high priority, and routine movement rides the background class.
        priority: waiting.payload.aps["content-state"].waitingCount > 0 ? 10 : 5,
      });
      if (result.status === 200) {
        // A cancel superseded this send while it was in flight:  a stale
        // state must not land on the island.
        if ((this.generations.get(key) ?? 0) !== generation) return;
        this.lastSent.set(key, waiting.comparable);
        this.attempts.delete(key);
        this.attemptState.delete(key);
        return;
      }
      // The state was not delivered, so it is not remembered.
      this.log(`activity push failed status=${result.status} reason=${result.reason ?? "unknown"}`);
      if (isTransientPushStatus(result.status)) this.retryLater(key, waiting);
      else this.attempts.set(key, this.options.retryLimit ?? ACTIVITY_PUSH_TRANSIENT_RETRIES);
    } catch {
      // A throw is the transport never answering:  the same push may go
      // through later, so it joins the transient path.
      this.log("activity push failed");
      this.retryLater(key, waiting);
    }
  }

  /**
   * Queue one failed push again, if it may succeed and nothing newer waits.
   *
   * The wait doubles per attempt and the attempts are capped, so a
   * persistent failure settles back into "wait for the next state change"
   * instead of hammering Apple with the same payload.
   */
  private retryLater(key: string, waiting: { registration: ActivityTokenRegistration; payload: LiveActivityPushPayload; comparable: string }): void {
    const limit = this.options.retryLimit ?? ACTIVITY_PUSH_TRANSIENT_RETRIES;
    const attempt = this.attempts.get(key) ?? 0;
    if (attempt >= limit) return;
    // A newer state already queued or timed for this token carries its own
    // push;  retrying the older payload over it would put the island back.
    if (this.pendingPayloads.has(key) || this.pending.has(key)) return;
    this.attempts.set(key, attempt + 1);
    this.pendingPayloads.set(key, waiting);
    const base = this.options.retryBaseMs ?? ACTIVITY_PUSH_RETRY_BASE_MS;
    const timer = setTimeout(() => {
      this.pending.delete(key);
      void this.send(key);
    }, base * 2 ** attempt);
    timer.unref?.();
    this.pending.set(key, timer);
  }

  private log(message: string): void {
    this.options.onLog?.(message);
  }
}

/** Read one JSON body, with a bound on its size. */
function readJsonBody(req: IncomingMessage, limitBytes = 64 * 1024): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > limitBytes) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        reject(new Error("invalid JSON"));
      }
    });
    req.on("error", reject);
  });
}

/** Answer with one JSON body. */
function respond(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify(body));
}

/** Whether the request carries the sidecar's Bearer token. */
function bearerOk(authorization: string | undefined, token: string): boolean {
  const match = /^Bearer (.+)$/.exec((authorization ?? "").trim());
  if (!match || !match[1]) return false;
  const supplied = Buffer.from(match[1]);
  const expected = Buffer.from(token);
  return expected.length > 0 && supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

/**
 * The route the phone registers on.
 *
 * The registrations are the phone's own business, so they are behind the
 * same Bearer credential as the rest of the sidecar's API.  A refused
 * request is refused without saying why, and a refused body never carries a
 * push token:  the token is in the request, and a body that quotes it back
 * would put it in whatever the phone logs.
 */
export async function handleActivityTokensRequest(
  req: IncomingMessage,
  res: ServerResponse,
  pathname: string,
  token: string,
  relay: ActivityPushRelay,
): Promise<boolean> {
  if (pathname !== ACTIVITY_TOKENS_PATH) return false;
  if (!bearerOk(req.headers.authorization, token)) {
    respond(res, 401, { error: "unauthorized" });
    return true;
  }
  if (req.method !== "PUT" && req.method !== "DELETE") {
    respond(res, 405, { error: "use PUT or DELETE" });
    return true;
  }
  let body: unknown;
  try {
    body = await readJsonBody(req);
  } catch {
    respond(res, 400, { error: "invalid JSON body" });
    return true;
  }
  if (req.method === "PUT") {
    const parsed = ActivityTokenRegistrationSchema.safeParse(body);
    if (!parsed.success) {
      respond(res, 400, { error: "the registration body is not valid" });
      return true;
    }
    try {
      const registration: {
        deviceUid: string;
        activityId: string;
        pushToken: string;
        environment: typeof parsed.data.environment;
        sessionId: string;
        previousPushToken?: string;
      } = {
        deviceUid: parsed.data.deviceUid,
        activityId: parsed.data.activityId,
        pushToken: parsed.data.pushToken,
        environment: parsed.data.environment,
        sessionId: parsed.data.sessionId,
      };
      if (parsed.data.previousPushToken) registration.previousPushToken = parsed.data.previousPushToken;
      relay.register(registration);
    } catch {
      // The store file refused the write:  answer a static 500 and say no
      // more — the error's text is about the filesystem, not for the phone.
      respond(res, 500, { error: "the registration could not be stored" });
      return true;
    }
    respond(res, 200, { enabled: relay.enabled, registered: true });
    return true;
  }
  const parsed = ActivityTokenRemovalSchema.safeParse(body);
  if (!parsed.success) {
    respond(res, 400, { error: "the removal body is not valid" });
    return true;
  }
  let removed: boolean;
  try {
    removed = relay.unregister(parsed.data.deviceUid, parsed.data.activityId, parsed.data.pushToken);
  } catch {
    respond(res, 500, { error: "the registration could not be removed" });
    return true;
  }
  respond(res, 200, { enabled: relay.enabled, removed });
  return true;
}
