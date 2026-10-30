import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { attachMuseAuthFailure } from "../src/web/muse-auth.ts";
import { safeMuseBridgeError } from "../src/web/chat-bridge.ts";

const TOKEN = `muse-auth-test-${"x".repeat(48)}`;
const TSX = join(process.cwd(), "node_modules", ".bin", "tsx");
const BRIDGE = join(process.cwd(), "src", "web", "chat-bridge.ts");
const FIXTURE = join(process.cwd(), "tests", "fixtures", "muse-auth-stub.mjs");
let sidecar: ChildProcess | null = null;
let port = 0;
let tokenFile = "";
let tempDir = "";
let stubLogFile = "";
let authFailureFile = "";
let stderr = "";

function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const value = typeof address === "object" && address ? address.port : 0;
      server.close(() => resolve(value));
    });
  });
}

async function waitFor(url: string, headers: Record<string, string>): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < 30_000) {
    try {
      const response = await fetch(url, { headers });
      if (response.status === 200) return;
    } catch {
      /* sidecar is not listening yet */
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("sidecar did not start");
}

function url(path: string): string { return `http://127.0.0.1:${port}${path}`; }
function headers(token = TOKEN): Record<string, string> { return { Authorization: `Bearer ${token}` }; }

async function jsonRequest(path: string, method = "GET", body?: unknown, token = TOKEN): Promise<Response> {
  return fetch(url(path), {
    method,
    headers: { ...headers(token), ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

function stubEvents(): Array<Record<string, unknown>> {
  try {
    return readFileSync(stubLogFile, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
  } catch {
    return [];
  }
}

async function waitForState(attemptId: string, state: string): Promise<Record<string, unknown>> {
  const started = Date.now();
  while (Date.now() - started < 5000) {
    const response = await jsonRequest(`/clutch/v1/auth/${attemptId}`);
    const value = await response.json() as Record<string, unknown>;
    if (value.state === state) return value;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Muse auth did not reach ${state}`);
}

async function waitForStubEvent(predicate: (event: Record<string, unknown>) => boolean): Promise<Record<string, unknown>> {
  const started = Date.now();
  while (Date.now() - started < 5000) {
    const event = stubEvents().find(predicate);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error("Muse auth fixture did not record the expected event");
}

beforeAll(async () => {
  tempDir = mkdtempSync(join(tmpdir(), "clutch-muse-auth-"));
  tokenFile = join(tempDir, "chat-token");
  stubLogFile = join(tempDir, "muse-auth-stub.jsonl");
  authFailureFile = join(tempDir, "muse-auth-failure.json");
  const launcher = join(tempDir, "muse-auth-stub.mjs");
  writeFileSync(launcher, readFileSync(FIXTURE), { mode: 0o755 });
  writeFileSync(tokenFile, `${TOKEN}\n`, { mode: 0o600 });
  port = await freePort();
  sidecar = spawn(TSX, [BRIDGE], {
    env: {
      ...process.env,
      CLUTCH_CHAT_PORT: String(port),
      CLUTCH_CHAT_TOKEN_FILE: tokenFile,
      CLUTCH_SESSION_META_FILE: join(tempDir, "session-meta.json"),
      CLUTCH_DSH_HOME: join(tempDir, "absent-dsh-home"),
      CLUTCH_TAILNET_HOST: "loopback-test.ts.net",
      CLUTCH_CHAT_LAUNCHER_MUSE: launcher,
      MUSE_AUTH_STUB_LOG: stubLogFile,
      MUSE_AUTH_STUB_FAILURE_FILE: authFailureFile,
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  sidecar.stderr?.on("data", (chunk) => { stderr += String(chunk); });
  await waitFor(url("/clutch/v1/health"), headers());
}, 60_000);

afterAll(() => {
  sidecar?.kill("SIGKILL");
});

describe("Muse auth sidecar endpoints", () => {
  it("preserves the safe actionable session-conflict message through repeated sanitization", () => {
    const mapped = safeMuseBridgeError({
      code: -32000,
      message: "This session is already being opened by another process: /private/path and provider diagnostics",
    });
    expect(mapped).toBe("This Muse thread is open in another process; choose another thread or wait until it is released.");
    expect(safeMuseBridgeError(Object.assign(new Error(mapped), { code: -32000 }))).toBe(mapped);
    expect(mapped).not.toContain("/private/path");
    expect(mapped).not.toContain("provider diagnostics");
  });

  it("attaches only allowlisted auth metadata to sanitized ACP errors", () => {
    const raw = {
      code: -32000,
      message: "Keychain access failed at https://private.example.test/callback?token=raw-secret",
      data: { providerToken: "raw-secret" },
    };
    const error = new Error(safeMuseBridgeError(raw));
    attachMuseAuthFailure(error, raw);

    expect(error.message).toBe("Muse request failed (ACP code -32000).");
    expect(error).toMatchObject({ museAuthFailure: { category: "keychain-access", code: -32000 } });
    expect(JSON.stringify(error)).not.toContain("private.example.test");
    expect(JSON.stringify(error)).not.toContain("raw-secret");
    expect(JSON.stringify(error)).not.toContain("Keychain access failed");
  });

  it("does not auto-authenticate a failed new session, then completes explicit device-code login", async () => {
    for (const [path, method, body] of [
      ["/clutch/v1/auth/start", "POST", { engine: "muse" }],
      ["/clutch/v1/auth/00000000-0000-4000-8000-000000000000", "GET", undefined],
      ["/clutch/v1/auth/00000000-0000-4000-8000-000000000000/answer", "POST", { action: "accept" }],
      ["/clutch/v1/auth/00000000-0000-4000-8000-000000000000", "DELETE", undefined],
    ] as const) {
      const unauthorized = await jsonRequest(path, method, body, "wrong-token");
      expect(unauthorized.status).toBe(401);
    }
    const badEngine = await jsonRequest("/clutch/v1/auth/start", "POST", { engine: "mcode" });
    expect(badEngine.status).toBe(400);

    const firstTurn = await jsonRequest("/clutch/v1/chat", "POST", { engine: "muse", prompt: "hello" });
    const firstEvents = await firstTurn.text();
    expect(firstEvents).toContain("Log in to Muse before opening a session.");
    expect(stubEvents().some((entry) => entry.method === "authenticate")).toBe(false);

    const start = await jsonRequest("/clutch/v1/auth/start", "POST", { engine: "muse" });
    expect(start.status).toBe(200);
    const started = await start.json() as { attemptId: string; state: string };
    expect(started.state).toBe("pending");
    const waiting = await waitForState(started.attemptId, "waiting");
    expect(waiting.url).toBe("https://login.example.test/device?flow=fixture");
    expect(waiting.message).toMatch(/device code/);
    const initialize = stubEvents().find((entry) => entry.method === "initialize");
    expect(initialize?.capabilities).toMatchObject({ elicitation: { url: {} } });
    const duplicate = await jsonRequest("/clutch/v1/auth/start", "POST", { engine: "muse" });
    expect(duplicate.status).toBe(409);
    expect(await duplicate.json()).toMatchObject({ attemptId: started.attemptId, state: "waiting" });

    const answered = await jsonRequest(`/clutch/v1/auth/${started.attemptId}/answer`, "POST", { action: "accept" });
    expect(answered.status).toBe(200);
    expect((await waitForState(started.attemptId, "complete")).state).toBe("complete");
    expect(stubEvents().some((entry) => entry.method === "authenticate" && entry.methodId === "muse-login")).toBe(true);
    expect(stubEvents().some((entry) => entry.method === "session/new")).toBe(true);
    expect(stderr).not.toContain("login.example.test");
  });

  it("preserves safe Keychain guidance after browser consent and hides raw ACP details", async () => {
    const fakeUrl = "https://private.example.test/callback?token=fixture-secret";
    const rawMessage = `Keychain access was denied for ${fakeUrl}`;
    writeFileSync(authFailureFile, JSON.stringify({
      code: -32000,
      message: rawMessage,
      data: { providerToken: "fixture-secret" },
    }));

    try {
      const start = await jsonRequest("/clutch/v1/auth/start", "POST", { engine: "muse" });
      expect(start.status).toBe(200);
      const started = await start.json() as { attemptId: string };
      await waitForState(started.attemptId, "waiting");

      const answered = await jsonRequest(`/clutch/v1/auth/${started.attemptId}/answer`, "POST", { action: "accept" });
      expect(answered.status).toBe(200);
      const failed = await waitForState(started.attemptId, "failed");
      const serialized = JSON.stringify(failed);
      expect(failed).toMatchObject({
        failureCategory: "keychain-access",
        failureCode: -32000,
        error: "Muse could not access the macOS Keychain.\u00A0 Check the credential's access settings for Muse Code, then try again.",
      });
      expect(serialized).not.toContain("private.example.test");
      expect(serialized).not.toContain("fixture-secret");
      expect(serialized).not.toContain("Keychain access was denied");
      expect(stderr).not.toContain("private.example.test");
      expect(stderr).not.toContain("fixture-secret");
      expect(stderr).not.toContain(rawMessage);
    } finally {
      if (existsSync(authFailureFile)) unlinkSync(authFailureFile);
    }
  });

  it("cancels the current URL request and rejects unknown attempt ids", async () => {
    const start = await jsonRequest("/clutch/v1/auth/start", "POST", { engine: "muse" });
    const started = await start.json() as { attemptId: string };
    await waitForState(started.attemptId, "waiting");

    const unknown = await jsonRequest("/clutch/v1/auth/00000000-0000-4000-8000-000000000000");
    expect(unknown.status).toBe(404);
    const canceled = await jsonRequest(`/clutch/v1/auth/${started.attemptId}`, "DELETE");
    expect(canceled.status).toBe(200);
    expect(await canceled.json()).toMatchObject({ state: "failed", error: "Muse sign-in was canceled." });
    await waitForStubEvent((entry) => entry.method === "elicitation/answer" && entry.action === "cancel");
  });
});
