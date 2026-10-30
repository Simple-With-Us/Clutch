import { beforeEach, describe, expect, it, vi } from "vitest";

import { MuseAuthController, type MuseAuthBridge, type MuseUrlElicitation } from "../src/web/muse-auth.ts";

class FakeMuseBridge implements MuseAuthBridge {
  methods: Array<{ id: string; name?: string; description?: string }> = [{ id: "muse-login" }];
  authCalls: string[] = [];
  answers: Array<{ requestId: number | string; action: "accept" | "cancel" }> = [];
  urlHandler: ((elicitation: MuseUrlElicitation) => boolean) | null = null;
  completeHandler: ((elicitationId: string) => void) | null = null;
  initializePromise: Promise<unknown> = Promise.resolve({});
  authenticatePromise: Promise<unknown> = new Promise(() => undefined);
  resolveAuthentication: (() => void) | null = null;
  rejectAuthentication: ((error: Error) => void) | null = null;

  initialize(): Promise<unknown> { return this.initializePromise; }
  authMethods() { return this.methods; }
  authenticate(methodId: string): Promise<unknown> {
    this.authCalls.push(methodId);
    return this.authenticatePromise;
  }
  answerElicitation(requestId: number | string, action: "accept" | "cancel"): boolean {
    this.answers.push({ requestId, action });
    return true;
  }
  setUrlElicitationHandler(handler: ((elicitation: MuseUrlElicitation) => boolean) | null): void {
    this.urlHandler = handler;
  }
  setElicitationCompleteHandler(handler: ((elicitationId: string) => void) | null): void {
    this.completeHandler = handler;
  }
  elicit(overrides: Partial<MuseUrlElicitation> = {}): boolean {
    return this.urlHandler?.({
      requestId: "request-1",
      elicitationId: "elicitation-1",
      url: "https://login.example.test/device",
      message: "Sign in with the displayed device code.",
      ...overrides,
    }) ?? false;
  }
  authenticateSuccessfully(): void { this.resolveAuthentication?.(); }
  failAuthentication(error: Error): void { this.rejectAuthentication?.(error); }

  constructor() {
    this.authenticatePromise = new Promise((resolve, reject) => {
      this.resolveAuthentication = () => resolve({});
      this.rejectAuthentication = reject;
    });
  }
}

describe("Muse ACP authentication", () => {
  beforeEach(() => vi.useRealTimers());

  it("starts only the advertised Muse method and waits for URL consent", async () => {
    const bridge = new FakeMuseBridge();
    const auth = new MuseAuthController(bridge);
    const started = await auth.start();

    expect(started.state).toBe("pending");
    expect(bridge.authCalls).toEqual(["muse-login"]);
    expect(bridge.elicit()).toBe(true);
    expect(auth.get(started.attemptId)).toMatchObject({ state: "waiting", url: "https://login.example.test/device" });
    expect(auth.answer(started.attemptId, "accept")).toMatchObject({ state: "waiting" });
    expect(bridge.answers).toEqual([{ requestId: "request-1", action: "accept" }]);
    bridge.completeHandler?.("elicitation-1");
    expect(auth.get(started.attemptId)).toMatchObject({ state: "waiting" });
    bridge.authenticateSuccessfully();
    await Promise.resolve();
    expect(auth.get(started.attemptId)).toMatchObject({ state: "complete" });
  });

  it("does not mark a URL completion notification complete when authenticate later fails", async () => {
    const bridge = new FakeMuseBridge();
    const auth = new MuseAuthController(bridge);
    const started = await auth.start();
    bridge.elicit();
    auth.answer(started.attemptId, "accept");
    bridge.completeHandler?.("elicitation-1");
    expect(auth.get(started.attemptId)).toMatchObject({ state: "waiting" });

    bridge.failAuthentication(new Error("provider rejected login"));
    await Promise.resolve();

    expect(auth.get(started.attemptId)).toMatchObject({ state: "failed", error: "Muse sign-in did not complete; please try again." });
  });

  it("rejects an unsupported method and an unsafe URL without forwarding either", async () => {
    const unsupported = new FakeMuseBridge();
    unsupported.methods = [{ id: "different-method" }];
    const unsupportedAuth = new MuseAuthController(unsupported);
    expect((await unsupportedAuth.start()).state).toBe("failed");
    expect(unsupported.authCalls).toEqual([]);

    const bridge = new FakeMuseBridge();
    const auth = new MuseAuthController(bridge);
    const started = await auth.start();
    expect(bridge.elicit({ url: "javascript:alert(1)" })).toBe(false);
    expect(bridge.elicit({ url: `https://login.example.test/${"x".repeat(2048)}` })).toBe(false);
    expect(auth.get(started.attemptId)).toMatchObject({ state: "pending" });
  });

  it("returns unknown for an unknown attempt and answers a user cancellation", async () => {
    const bridge = new FakeMuseBridge();
    const auth = new MuseAuthController(bridge);
    expect(auth.get("00000000-0000-4000-8000-000000000000")).toBeNull();
    const started = await auth.start();
    bridge.elicit();
    expect(auth.answer("00000000-0000-4000-8000-000000000000", "cancel")).toBeNull();
    expect(auth.cancel(started.attemptId)).toMatchObject({ state: "failed" });
    expect(bridge.answers).toEqual([{ requestId: "request-1", action: "cancel" }]);
  });

  it("preserves long opaque elicitation ids for completion matching and bounds oversized ids", async () => {
    vi.useFakeTimers();
    const bridge = new FakeMuseBridge();
    const auth = new MuseAuthController(bridge);
    const started = await auth.start();
    expect(bridge.elicit({ elicitationId: "x".repeat(4097) })).toBe(false);
    const id = "x".repeat(300);
    expect(bridge.elicit({ elicitationId: id })).toBe(true);
    auth.answer(started.attemptId, "accept");
    bridge.completeHandler?.(id);
    await vi.advanceTimersByTimeAsync(10 * 60 * 1000);
    expect(auth.get(started.attemptId)?.error).toBe("Muse reported the browser flow complete, but ACP sign-in timed out.");
  });

  it("cancels a pending URL elicitation when the attempt expires", async () => {
    vi.useFakeTimers();
    const bridge = new FakeMuseBridge();
    const auth = new MuseAuthController(bridge);
    const started = await auth.start();
    bridge.elicit();

    await vi.advanceTimersByTimeAsync(10 * 60 * 1000);

    expect(auth.get(started.attemptId)).toMatchObject({ state: "failed", error: "Muse sign-in expired; please try again." });
    expect(bridge.answers).toEqual([{ requestId: "request-1", action: "cancel" }]);
  });

  it("does not authenticate a stale attempt after expiry during initialize", async () => {
    vi.useFakeTimers();
    const bridge = new FakeMuseBridge();
    let finishInitialize!: (value: unknown) => void;
    bridge.initializePromise = new Promise((resolve) => { finishInitialize = resolve; });
    const auth = new MuseAuthController(bridge);
    const starting = auth.start();
    const attemptId = auth.activeSnapshot()!.attemptId;

    await vi.advanceTimersByTimeAsync(10 * 60 * 1000);
    finishInitialize({});
    const started = await starting;

    expect(started).toMatchObject({ attemptId, state: "failed" });
    expect(bridge.authCalls).toEqual([]);
  });

  it("does not let a stale initializer rejection fail its replacement attempt", async () => {
    const bridge = new FakeMuseBridge();
    let rejectFirstInitialize!: (error: Error) => void;
    bridge.initializePromise = new Promise((_, reject) => { rejectFirstInitialize = reject; });
    const auth = new MuseAuthController(bridge);
    const firstStart = auth.start();
    const firstId = auth.activeSnapshot()!.attemptId;
    auth.cancel(firstId);

    bridge.initializePromise = Promise.resolve({});
    const replacement = await auth.start();
    rejectFirstInitialize(new Error("stale initialize failure"));
    await firstStart;

    expect(auth.get(replacement.attemptId)).toMatchObject({ state: "pending" });
    expect(bridge.authCalls).toEqual(["muse-login"]);
  });

  it("does not claim canceling after acceptance revokes the browser flow", async () => {
    const bridge = new FakeMuseBridge();
    const auth = new MuseAuthController(bridge);
    const started = await auth.start();
    bridge.elicit();
    auth.answer(started.attemptId, "accept");

    expect(auth.cancel(started.attemptId)).toMatchObject({
      state: "failed",
      error: "Stopped waiting for Muse sign-in; the browser flow may still complete.",
    });
  });
});
