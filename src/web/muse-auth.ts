import { randomUUID } from "node:crypto";

export type MuseAuthState = "pending" | "waiting" | "complete" | "failed";
export type MuseElicitationAction = "accept" | "cancel";
export type MuseAuthFailureCategory = "keychain-access" | "already-active" | "canceled" | "expired-or-declined" | "generic";

export interface MuseAuthFailureInfo {
  category: MuseAuthFailureCategory;
  code?: number;
}

export interface MuseAuthSnapshot {
  attemptId: string;
  state: MuseAuthState;
  url?: string;
  message?: string;
  error?: string;
  failureCategory?: MuseAuthFailureCategory;
  failureCode?: number;
}

export interface MuseAuthMethod {
  id: string;
  name?: string;
  description?: string;
}

export interface MuseUrlElicitation {
  requestId: number | string;
  elicitationId: string;
  url: string;
  message: string;
}

export interface MuseAuthBridge {
  initialize(): Promise<unknown>;
  authMethods(): MuseAuthMethod[];
  authenticate(methodId: string): Promise<unknown>;
  answerElicitation(requestId: number | string, action: MuseElicitationAction): boolean;
  setUrlElicitationHandler(handler: ((elicitation: MuseUrlElicitation) => boolean) | null): void;
  setElicitationCompleteHandler(handler: ((elicitationId: string) => void) | null): void;
}

interface ActiveMuseAuthAttempt {
  snapshot: MuseAuthSnapshot;
  elicitationId?: string;
  bridgeRequestId?: number | string;
  timer: ReturnType<typeof setTimeout>;
  acceptedUrl?: boolean;
  completionNotified?: boolean;
}

const ATTEMPT_TTL_MS = 10 * 60 * 1000;
const MAX_MESSAGE_LENGTH = 1000;
const GENERIC_AUTH_FAILURE = "Muse sign-in did not complete; please try again.";

const AUTH_FAILURE_COPY: Record<MuseAuthFailureCategory, string> = {
  "keychain-access": "Muse could not access the macOS Keychain.\u00A0 Check the credential's access settings for Muse Code, then try again.",
  "already-active": "A Muse sign-in is already in progress.\u00A0 Finish it before trying again.",
  canceled: "Muse sign-in was canceled.\u00A0 Try again if you still want to sign in.",
  "expired-or-declined": "Muse sign-in was declined or expired.\u00A0 Start a new sign-in attempt.",
  generic: GENERIC_AUTH_FAILURE,
};

/** Classify only the ACP error message and safe numeric code; never retain its raw payload. */
export function classifyMuseAuthFailure(error: unknown): MuseAuthFailureInfo {
  const row = error && typeof error === "object" ? error as { message?: unknown; code?: unknown } : {};
  const message = typeof row.message === "string" ? row.message : "";
  let category: MuseAuthFailureCategory = "generic";

  if (/keychain|errSecInteractionNotAllowed|interaction not allowed|user interaction is not allowed/i.test(message)) {
    category = "keychain-access";
  } else if (/(?:muse )?(?:login|sign[ -]?in) is already in progress|already active login/i.test(message)) {
    category = "already-active";
  } else if (/\b(cancelled|canceled|cancellation|cancelation)\b/i.test(message)) {
    category = "canceled";
  } else if (/\b(expired|declined|timed out)\b/i.test(message)) {
    category = "expired-or-declined";
  }

  return {
    category,
    ...(typeof row.code === "number" && Number.isSafeInteger(row.code) ? { code: row.code } : {}),
  };
}

/** Attach allowlisted metadata to a sanitized bridge error without copying provider text. */
export function attachMuseAuthFailure(error: Error, rawError: unknown): void {
  Object.assign(error, { museAuthFailure: classifyMuseAuthFailure(rawError) });
}

function museAuthFailureFrom(error: unknown): MuseAuthFailureInfo | null {
  if (!error || typeof error !== "object") return null;
  const candidate = (error as { museAuthFailure?: unknown }).museAuthFailure;
  if (!candidate || typeof candidate !== "object") return null;
  const row = candidate as { category?: unknown; code?: unknown };
  const categories: MuseAuthFailureCategory[] = ["keychain-access", "already-active", "canceled", "expired-or-declined", "generic"];
  if (typeof row.category !== "string" || !categories.includes(row.category as MuseAuthFailureCategory)) return null;
  return {
    category: row.category as MuseAuthFailureCategory,
    ...(typeof row.code === "number" && Number.isSafeInteger(row.code) ? { code: row.code } : {}),
  };
}

function urlForUser(raw: string): string | null {
  if (raw.length === 0 || raw.length > 2048) return null;
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:" || !url.hostname || url.username || url.password) return null;
    const canonical = url.toString();
    return canonical.length <= 2048 ? canonical : null;
  } catch {
    return null;
  }
}

/** Owns one explicit Muse sign-in attempt without retaining provider credentials. */
export class MuseAuthController {
  private active: ActiveMuseAuthAttempt | null = null;

  constructor(
    private readonly bridge: MuseAuthBridge,
  ) {
    bridge.setUrlElicitationHandler((elicitation) => this.receiveElicitation(elicitation));
    bridge.setElicitationCompleteHandler((elicitationId) => this.completeElicitation(elicitationId));
  }

  async start(): Promise<MuseAuthSnapshot> {
    if (this.active && (this.active.snapshot.state === "pending" || this.active.snapshot.state === "waiting")) {
      throw new Error("A Muse sign-in attempt is already active.");
    }
    this.clearActive();
    const attempt = {
      snapshot: { attemptId: randomUUID(), state: "pending" as const },
      timer: setTimeout(() => this.expire(attempt), ATTEMPT_TTL_MS),
    };
    attempt.timer.unref?.();
    this.active = attempt;

    try {
      await this.bridge.initialize();
      if (this.active !== attempt || attempt.snapshot.state !== "pending") return { ...attempt.snapshot };
      const method = this.bridge.authMethods().find((candidate) => candidate.id === "muse-login");
      if (!method) {
        this.failAttempt(attempt, "Muse did not offer a supported sign-in method.");
        return { ...attempt.snapshot };
      }
      void this.runAuthenticate(attempt);
    } catch {
      if (this.active === attempt && attempt.snapshot.state === "pending") {
        this.failAttempt(attempt, "Muse sign-in could not start; please try again.");
      }
    }
    return { ...attempt.snapshot };
  }

  get(attemptId: string): MuseAuthSnapshot | null {
    if (!this.active || this.active.snapshot.attemptId !== attemptId) return null;
    return { ...this.active.snapshot };
  }

  activeSnapshot(): MuseAuthSnapshot | null {
    if (!this.active || (this.active.snapshot.state !== "pending" && this.active.snapshot.state !== "waiting")) return null;
    return { ...this.active.snapshot };
  }

  answer(attemptId: string, action: MuseElicitationAction): MuseAuthSnapshot | null {
    const active = this.active;
    if (!active || active.snapshot.attemptId !== attemptId || active.snapshot.state !== "waiting" || active.bridgeRequestId === undefined) {
      return null;
    }
    if (!this.bridge.answerElicitation(active.bridgeRequestId, action)) return null;
    delete active.bridgeRequestId;
    if (action === "accept") active.acceptedUrl = true;
    else this.failAttempt(active, "Muse sign-in was canceled.", { category: "canceled" });
    return { ...active.snapshot };
  }

  cancel(attemptId: string): MuseAuthSnapshot | null {
    const active = this.active;
    if (!active || active.snapshot.attemptId !== attemptId) return null;
    if (active.bridgeRequestId !== undefined) {
      this.bridge.answerElicitation(active.bridgeRequestId, "cancel");
      delete active.bridgeRequestId;
    }
    this.failAttempt(
      active,
      active.acceptedUrl
        ? "Stopped waiting for Muse sign-in; the browser flow may still complete."
        : "Muse sign-in was canceled.",
      active.acceptedUrl ? undefined : { category: "canceled" },
    );
    return { ...active.snapshot };
  }

  bridgeFailed(): void {
    if (!this.active || this.active.snapshot.state === "complete" || this.active.snapshot.state === "failed") return;
    this.failAttempt(this.active, "Muse sign-in was interrupted; please try again.");
  }

  private async runAuthenticate(attempt: ActiveMuseAuthAttempt): Promise<void> {
    if (this.active !== attempt || attempt.snapshot.state !== "pending") return;
    try {
      await this.bridge.authenticate("muse-login");
      if (this.active === attempt && (attempt.snapshot.state === "pending" || attempt.snapshot.state === "waiting")) {
        attempt.snapshot.state = "complete";
        this.clearTimer(attempt);
      }
    } catch (error) {
      const currentState = attempt.snapshot.state as MuseAuthState;
      if (this.active === attempt && currentState !== "complete" && currentState !== "failed") {
        const failure = museAuthFailureFrom(error) ?? { category: "generic" as const };
        this.failAttempt(attempt, AUTH_FAILURE_COPY[failure.category], failure);
      }
    }
  }

  private receiveElicitation(elicitation: MuseUrlElicitation): boolean {
    const active = this.active;
    const safeUrl = urlForUser(elicitation.url);
    if (!active || active.snapshot.state !== "pending" || !safeUrl || !elicitation.elicitationId || elicitation.elicitationId.length > 4096) return false;
    active.elicitationId = elicitation.elicitationId;
    active.bridgeRequestId = elicitation.requestId;
    active.snapshot.url = safeUrl;
    active.snapshot.message = elicitation.message.slice(0, MAX_MESSAGE_LENGTH);
    active.snapshot.state = "waiting";
    return true;
  }

  private completeElicitation(elicitationId: string): void {
    const active = this.active;
    if (!active || active.elicitationId !== elicitationId || active.snapshot.state !== "waiting") return;
    active.completionNotified = true;
  }

  private expire(active: ActiveMuseAuthAttempt): void {
    if (this.active !== active || active.snapshot.state === "complete" || active.snapshot.state === "failed") return;
    if (active.bridgeRequestId !== undefined) {
      this.bridge.answerElicitation(active.bridgeRequestId, "cancel");
      delete active.bridgeRequestId;
    }
    this.failAttempt(
      active,
      active.acceptedUrl
        ? active.completionNotified
          ? "Muse reported the browser flow complete, but ACP sign-in timed out."
          : "Muse sign-in timed out; the browser flow may still complete."
        : "Muse sign-in expired; please try again.",
    );
  }

  private failAttempt(active: ActiveMuseAuthAttempt, message: string, failure?: MuseAuthFailureInfo): void {
    if (active.snapshot.state === "complete" || active.snapshot.state === "failed") return;
    active.snapshot = {
      attemptId: active.snapshot.attemptId,
      state: "failed",
      error: message,
      ...(failure ? { failureCategory: failure.category } : {}),
      ...(failure?.code !== undefined ? { failureCode: failure.code } : {}),
    };
    delete active.bridgeRequestId;
    this.clearTimer(active);
  }

  private clearActive(): void {
    if (this.active) this.clearTimer(this.active);
    this.active = null;
  }

  private clearTimer(active: ActiveMuseAuthAttempt): void {
    clearTimeout(active.timer);
  }
}

export function isMuseAuthAttemptId(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}
