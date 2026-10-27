/**
 * Full-loop sidecar test: a real `chat-bridge.ts` child process serves SSE
 * while its deepseek engine points at a stub bridge script and its
 * CometChat relay points at a local stub server. Proves the wiring no unit
 * test can: HTTP auth gates, the ACP update fan-out into both SSE and the
 * relay, and the relay's create-plus-flush over real HTTP.
 *
 * Everything here is local and credential-free: dummy CometChat values, a
 * 127.0.0.1 stub, throwaway ports. Nothing reaches the network.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { z } from "zod";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

interface CcCall {
  method: string;
  path: string;
  headers: { apikey: unknown; onBehalfOf: unknown };
  body: unknown;
}

const ccCalls: CcCall[] = [];
let ccServer: Server;
let ccPort = 0;
let sidecar: ChildProcess | null = null;
let chatPort = 0;
let tokenFile = "";
/** Isolated so the loop test never writes the developer's real metadata. */
let metaFile = "";
/** Where the stub records what the sidecar did to the engine. */
let stubLogFile = "";
const CHAT_TOKEN = `loop-test-token-${"x".repeat(48)}`;
const TSX = join(process.cwd(), "node_modules", ".bin", "tsx");
const BRIDGE = join(process.cwd(), "src", "web", "chat-bridge.ts");

function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => {
      const addr = s.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      s.close(() => resolve(port));
    });
  });
}

function readBody(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        resolve(null);
      }
    });
  });
}

async function waitFor(url: string, headers: Record<string, string>, timeoutMs = 30000): Promise<void> {
  const start = Date.now();
  for (;;) {
    try {
      const res = await fetch(url, { headers });
      if (res.status === 200) return;
    } catch {
      /* not up yet */
    }
    if (Date.now() - start > timeoutMs) throw new Error(`timed out waiting for ${url}`);
    await new Promise((r) => setTimeout(r, 200));
  }
}

beforeAll(async () => {
  ccServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const body = await readBody(req);
    ccCalls.push({
      method: req.method ?? "?",
      path: new URL(req.url ?? "/", "http://x").pathname,
      headers: { apikey: req.headers.apikey, onBehalfOf: req.headers.onbehalfof },
      body,
    });
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ id: 101 }));
  });
  await new Promise<void>((r) => ccServer.listen(0, "127.0.0.1", r));
  ccPort = (ccServer.address() as { port: number }).port;

  const dir = mkdtempSync(join(tmpdir(), "chat-loop-"));
  tokenFile = join(dir, "chat-token");
  writeFileSync(tokenFile, `${CHAT_TOKEN}\n`, { mode: 0o600 });
  metaFile = join(dir, "session-meta.json");
  stubLogFile = join(dir, "stub-log.jsonl");
  chatPort = await freePort();

  sidecar = spawn(TSX, [BRIDGE], { env: sidecarEnv(tokenFile), stdio: ["ignore", "pipe", "pipe"] });
  sidecar.stderr?.on("data", (c) => { if (process.env.CHAT_LOOP_DEBUG) process.stderr.write(c); });
  await waitFor(`http://127.0.0.1:${chatPort}/clutch/v1/health`, { Authorization: `Bearer ${CHAT_TOKEN}` });
}, 60000);

function sidecarEnv(tokenFile: string): NodeJS.ProcessEnv {
  return {
    ...process.env,
    CLUTCH_CHAT_PORT: String(chatPort),
    CLUTCH_CHAT_TOKEN_FILE: tokenFile,
    CLUTCH_SESSION_META_FILE: metaFile,
    CLUTCH_DSH_HOME: join(tmpdir(), "chat-loop-absent-dsh-home"),
    CLUTCH_TAILNET_HOST: "loopback-test.ts.net",
    CLUTCH_CHAT_LAUNCHER_DEEPSEEK: join(process.cwd(), "tests", "fixtures", "chat-bridge-stub.mjs"),
    CLUTCH_CHAT_LAUNCHER_MCODE: join(process.cwd(), "tests", "fixtures", "chat-bridge-stub.mjs"),
    CHAT_BRIDGE_STUB_LOG: stubLogFile,
    COMETCHAT_APP_ID: "loop",
    COMETCHAT_REGION: "us",
    COMETCHAT_AUTH_KEY: "loop-auth-key",
    COMETCHAT_REST_API_KEY: "loop-rest-key",
    COMETCHAT_AGENT_UID: "clutch-agent",
    COMETCHAT_API_BASE: `http://127.0.0.1:${ccPort}/v3`,
  };
}

afterAll(() => {
  sidecar?.kill("SIGKILL");
  if (ccServer?.listening) ccServer.close();
});

/** What the stub saw, oldest first. */
function stubLog(): Array<Record<string, unknown>> {
  if (!stubLogFile) return [];
  try {
    return readFileSync(stubLogFile, "utf8")
      .split("\n")
      .filter((line) => line.trim().length > 0)
      .map((line) => JSON.parse(line) as Record<string, unknown>);
  } catch {
    return [];
  }
}

/** How many permission answers the stub has seen so far. */
function stubAnswerCount(): number {
  return stubLog().filter((entry) => entry["event"] === "permission-answered").length;
}

/** Wait for the stub to report one more permission answer than it had. */
async function waitForStubAnswer(before: number, timeoutMs = 20000): Promise<Record<string, unknown> | null> {
  const start = Date.now();
  for (;;) {
    const answered = stubLog().filter((entry) => entry["event"] === "permission-answered")[before];
    if (answered) return answered;
    if (Date.now() - start > timeoutMs) return null;
    await new Promise((r) => setTimeout(r, 100));
  }
}

function chatHeaders(): Record<string, string> {
  return { Authorization: `Bearer ${CHAT_TOKEN}`, "Content-Type": "application/json" };
}

async function postChat(body: unknown): Promise<{ status: number; text: string }> {
  const res = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/chat`, {
    method: "POST",
    headers: chatHeaders(),
    body: JSON.stringify(body),
  });
  return { status: res.status, text: await res.text() };
}

describe("chat sidecar full loop", () => {
  it("serves the MiniMax Code remote shell without exposing its token", async () => {
    const res = await fetch(`http://127.0.0.1:${chatPort}/minimax-code/?token=${CHAT_TOKEN}`);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("MiniMax Code Remote");
    expect(html).toContain("/clutch/v1/sessions?engine=mcode");
    expect(html).not.toContain(CHAT_TOKEN);
  });

  it("lists, loads, and continues an existing MiniMax Code ACP thread", async () => {
    const listed = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/sessions?engine=mcode`, { headers: chatHeaders() });
    expect(listed.status).toBe(200);
    const listBody = (await listed.json()) as { sessions: Array<{ sessionId: string; title: string; cwd: string }> };
    expect(listBody.sessions).toEqual([
      expect.objectContaining({ sessionId: "mcode-existing-1", title: "Existing MiniMax thread", cwd: "/tmp/project" }),
    ]);

    const loaded = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/sessions/load`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ engine: "mcode", sessionId: "mcode-existing-1", cwd: "/tmp/project" }),
    });
    expect(loaded.status).toBe(200);
    const loadBody = (await loaded.json()) as {
      sessionId: string;
      remoteSessionId: string;
      history: Array<{ kind: string; text: string }>;
    };
    expect(loadBody.remoteSessionId).toBe("mcode-existing-1");
    expect(loadBody.history).toEqual([
      expect.objectContaining({ kind: "user_message_chunk", text: "existing question" }),
      expect.objectContaining({ kind: "agent_message_chunk", text: "existing answer" }),
    ]);

    const continued = await postChat({
      engine: "mcode",
      sessionId: loadBody.sessionId,
      prompt: "continue the thread",
      cwd: "/tmp/project",
    });
    expect(continued.status).toBe(200);
    expect(continued.text).toContain("stub-answer");
    expect(continued.text).toMatch(/event: done[\s\S]*endTurn/);

    const transient = await postChat({
      engine: "mcode",
      sessionId: loadBody.sessionId,
      prompt: "transient-error",
      cwd: "/tmp/project",
    });
    expect(transient.text).toMatch(/event: error[\s\S]*temporary provider failure/);

    const recovered = await postChat({
      engine: "mcode",
      sessionId: loadBody.sessionId,
      prompt: "after-transient",
      cwd: "/tmp/project",
    });
    expect(recovered.text).toContain("stub-answer");
    expect(recovered.text).not.toContain("loaded thread was detached");
  }, 60000);

  it("serves chat-config with the relay coordinates", async () => {
    const res = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/chat-config`, { headers: chatHeaders() });
    expect(res.status).toBe(200);
    const json = (await res.json()) as {
      chatPort: number;
      cometchat: { appId: string; region: string; authKey: string; agentUid: string } | null;
    };
    expect(json.chatPort).toBe(chatPort);
    expect(json.cometchat?.appId).toBe("loop");
    expect(json.cometchat?.agentUid).toBe("clutch-agent");
  });

  it("streams a stub turn over SSE and mirrors it into CometChat", async () => {
    const { status, text } = await postChat({
      prompt: "say stub",
      model: "DeepSeek-V4.1-Pro",
      cwd: "/tmp",
      relay: { receiver: "user-9", receiverType: "user" },
    });
    expect(status).toBe(200);
    expect(text).toContain("event: start");
    expect(text).toContain("event: message");
    expect(text).toContain("stub-answer");
    expect(text).toMatch(/event: done[\s\S]*endTurn/);
    // The plan travels with the turn, so the client can show what the engine
    // is working on.
    expect(text).toContain("event: plan");
    expect(text).toContain("Read the failing test");

    const posts = ccCalls.filter((c) => c.method === "POST" && c.path === "/v3/messages");
    expect(posts.length).toBe(1);
    expect(posts[0]?.headers).toMatchObject({ apikey: "loop-rest-key", onBehalfOf: "clutch-agent" });
    expect(posts[0]?.body).toMatchObject({
      receiver: "user-9",
      receiverType: "user",
      category: "message",
      type: "text",
    });
    const puts = ccCalls.filter((c) => c.method === "PUT");
    expect(puts.length).toBeGreaterThanOrEqual(1);
    expect(puts[puts.length - 1]?.path).toBe("/v3/messages/101");
  }, 60000);

  it("waits for the client's answer to a permission request", async () => {
    // The code engines send their prompt as content blocks, and the stub
    // bridge asks for a permission before it answers.  The sidecar has to
    // hold that request until the client answers it, rather than answering
    // it on the owner's behalf.
    const res = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/chat`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ prompt: "say stub", engine: "mcode", cwd: "/tmp", permissions: "ask" }),
    });
    expect(res.status).toBe(200);
    const reader = res.body?.getReader();
    expect(reader).toBeTruthy();
    const decoder = new TextDecoder();
    let seen = "";
    let requestId = "";
    let chatId = "";
    while (!seen.includes("event: permission")) {
      const chunk = await reader!.read();
      if (chunk.done) break;
      seen += decoder.decode(chunk.value, { stream: true });
      const start = /event: start\ndata: (\{.*\})/.exec(seen);
      if (start) chatId = (JSON.parse(start[1]) as { sessionId: string }).sessionId;
      const permission = /event: permission\ndata: (\{.*\})/.exec(seen);
      if (permission) {
        requestId = (JSON.parse(permission[1]) as { requestId: string }).requestId;
      }
    }
    expect(chatId).not.toBe("");
    expect(requestId).not.toBe("");
    expect(seen).toContain("allow-once");

    const answered = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/permissions`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ sessionId: chatId, requestId, optionId: "allow-once" }),
    });
    expect(answered.status).toBe(200);
    expect(await answered.json()).toEqual({ ok: true });

    // The stub only finishes the turn when the answer says allow-once, so
    // the answer really did reach the engine.
    let rest = "";
    while (!rest.includes("event: done")) {
      const chunk = await reader!.read();
      if (chunk.done) break;
      rest += decoder.decode(chunk.value, { stream: true });
    }
    expect(rest).toContain("stub-answer");
    expect(rest).toMatch(/event: done[\s\S]*endTurn/);
  }, 60000);

  it("refuses an answer for a request the turn did not raise", async () => {
    // The request ids are process-wide and predictable, so an answer must be
    // checked against the requests this turn owns: a stale card from another
    // turn must not be able to answer this one.
    const res = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/chat`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ prompt: "say stub", engine: "mcode", cwd: "/tmp", permissions: "ask" }),
    });
    expect(res.status).toBe(200);
    const reader = res.body?.getReader();
    const decoder = new TextDecoder();
    let seen = "";
    let requestId = "";
    let chatId = "";
    while (!seen.includes("event: permission")) {
      const chunk = await reader!.read();
      if (chunk.done) break;
      seen += decoder.decode(chunk.value, { stream: true });
      const start = /event: start\ndata: (\{.*\})/.exec(seen);
      if (start) chatId = (JSON.parse(start[1]) as { sessionId: string }).sessionId;
      const permission = /event: permission\ndata: (\{.*\})/.exec(seen);
      if (permission) requestId = (JSON.parse(permission[1]) as { requestId: string }).requestId;
    }
    expect(chatId).not.toBe("");
    expect(requestId).not.toBe("");

    const foreign = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/permissions`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ sessionId: chatId, requestId: "perm-999999", optionId: "allow-once" }),
    });
    expect(foreign.status).toBe(404);

    // The real answer still works, so the refused one did not consume it.
    const answered = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/permissions`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ sessionId: chatId, requestId, optionId: "allow-once" }),
    });
    expect(answered.status).toBe(200);
  }, 60000);

  it("refuses an answer that names another turn's request", async () => {
    const answersBefore = stubAnswerCount();
    // Two turns are blocked on the same engine at once.  Their request ids
    // are process-wide, so answering turn A's request through turn B's
    // session would hand turn B's client the power to answer turn A's
    // question.  The answer is refused, and the engine is left waiting.
    const first = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/chat`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ prompt: "say stub", engine: "mcode", cwd: "/tmp", permissions: "ask" }),
    });
    const firstReader = first.body?.getReader();
    const decoder = new TextDecoder();
    let firstSeen = "";
    let firstRequestId = "";
    let firstChatId = "";
    while (!firstSeen.includes("event: permission")) {
      const chunk = await firstReader!.read();
      if (chunk.done) break;
      firstSeen += decoder.decode(chunk.value, { stream: true });
      const start = /event: start\ndata: (\{.*\})/.exec(firstSeen);
      if (start) firstChatId = (JSON.parse(start[1]) as { sessionId: string }).sessionId;
      const permission = /event: permission\ndata: (\{.*\})/.exec(firstSeen);
      if (permission) firstRequestId = (JSON.parse(permission[1]) as { requestId: string }).requestId;
    }
    expect(firstRequestId).not.toBe("");

    const second = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/chat`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ prompt: "say stub again", engine: "mcode", cwd: "/tmp", permissions: "ask" }),
    });
    const secondReader = second.body?.getReader();
    let secondSeen = "";
    let secondChatId = "";
    while (!secondSeen.includes("event: permission")) {
      const chunk = await secondReader!.read();
      if (chunk.done) break;
      secondSeen += decoder.decode(chunk.value, { stream: true });
      const start = /event: start\ndata: (\{.*\})/.exec(secondSeen);
      if (start) secondChatId = (JSON.parse(start[1]) as { sessionId: string }).sessionId;
    }
    expect(secondChatId).not.toBe("");
    expect(secondChatId).not.toBe(firstChatId);

    const crossed = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/permissions`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ sessionId: secondChatId, requestId: firstRequestId, optionId: "allow-once" }),
    });
    expect(crossed.status).toBe(404);

    // The engine was not answered behind the refused request's back.
    await new Promise((r) => setTimeout(r, 500));
    expect(stubAnswerCount()).toBe(answersBefore);

    await firstReader!.cancel();
    await secondReader!.cancel();
  }, 60000);

  it("refuses an option the engine never offered", async () => {
    // An option id the engine did not offer would be forwarded to a blocked
    // engine, which rejects it and leaves the turn stuck.  It is refused at
    // the door instead, and the request stays open for a real answer.
    const res = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/chat`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ prompt: "say stub", engine: "mcode", cwd: "/tmp", permissions: "ask" }),
    });
    expect(res.status).toBe(200);
    const reader = res.body?.getReader();
    const decoder = new TextDecoder();
    let seen = "";
    let requestId = "";
    let chatId = "";
    while (!seen.includes("event: permission")) {
      const chunk = await reader!.read();
      if (chunk.done) break;
      seen += decoder.decode(chunk.value, { stream: true });
      const start = /event: start\ndata: (\{.*\})/.exec(seen);
      if (start) chatId = (JSON.parse(start[1]) as { sessionId: string }).sessionId;
      const permission = /event: permission\ndata: (\{.*\})/.exec(seen);
      if (permission) requestId = (JSON.parse(permission[1]) as { requestId: string }).requestId;
    }
    expect(requestId).not.toBe("");

    const unknown = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/permissions`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ sessionId: chatId, requestId, optionId: "not-an-option" }),
    });
    expect(unknown.status).toBe(400);

    const answered = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/permissions`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ sessionId: chatId, requestId, optionId: "allow-once" }),
    });
    expect(answered.status).toBe(200);
    expect(await answered.json()).toEqual({ ok: true });
  }, 60000);

  it("releases a blocked engine when the turn ends without an answer", async () => {
    // The engine waits on the answer, so a turn that ends must let it go
    // instead of leaving it blocked forever on a question nobody can answer.
    const res = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/chat`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ prompt: "say stub", engine: "mcode", cwd: "/tmp", permissions: "ask" }),
    });
    expect(res.status).toBe(200);
    const reader = res.body?.getReader();
    const decoder = new TextDecoder();
    let seen = "";
    while (!seen.includes("event: permission")) {
      const chunk = await reader!.read();
      if (chunk.done) break;
      seen += decoder.decode(chunk.value, { stream: true });
    }
    expect(seen).toContain("event: permission");
    const answersBefore = stubAnswerCount();

    // Stopping the turn is what a native client does: the Stop button.
    const start = /event: start\ndata: (\{.*\})/.exec(seen);
    const chatId = start ? (JSON.parse(start[1]) as { sessionId: string }).sessionId : "";
    expect(chatId).not.toBe("");
    const cancelled = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/chat/cancel`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ sessionId: chatId }),
    });
    expect(cancelled.status).toBe(200);

    const answered = await waitForStubAnswer(answersBefore);
    expect(answered).not.toBeNull();
    // The sidecar's own fallback is the allow-once it has always sent.
    expect(answered?.["optionId"]).toBe("allow-once");
  }, 60000);

  it("refuses an answer for a request that is not there", async () => {
    const res = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/permissions`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ sessionId: "no-such-session", requestId: "perm-999", optionId: "allow-once" }),
    });
    expect(res.status).toBe(404);

    const missing = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/permissions`, {
      method: "POST",
      headers: chatHeaders(),
      body: JSON.stringify({ requestId: "perm-999" }),
    });
    expect(missing.status).toBe(400);
  });

  it("a second bridge on the same port yields quietly", async () => {
    // start-web.sh and start-web.ts both launch the sidecar; the loser of
    // the bind must exit 0 without disturbing the winner.
    const twin = spawn(TSX, [BRIDGE], { env: sidecarEnv(tokenFile), stdio: ["ignore", "pipe", "pipe"] });
    const code = await new Promise<number | null>((resolve) => {
      const timer = setTimeout(() => {
        twin.kill("SIGKILL");
        resolve(null);
      }, 20000);
      twin.on("exit", (c) => {
        clearTimeout(timer);
        resolve(c);
      });
    });
    expect(code).toBe(0);
    const res = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/health`, {
      headers: { Authorization: `Bearer ${CHAT_TOKEN}` },
    });
    expect(res.status).toBe(200);
  }, 60000);

  it("still completes the turn when the relay backend is down", async () => {    ccServer.close();
    await new Promise((r) => setTimeout(r, 200));
    const { status, text } = await postChat({
      prompt: "say stub",
      model: "DeepSeek-V4.1-Pro",
      cwd: "/tmp",
      relay: { receiver: "user-9", receiverType: "user" },
    });
    expect(status).toBe(200);
    expect(text).toMatch(/event: done[\s\S]*endTurn/);
  }, 60000);

  it("reports a missing mcode executable without crashing the sidecar", async () => {
    const missingPort = await freePort();
    const dir = mkdtempSync(join(tmpdir(), "chat-missing-mcode-"));
    const missingTokenFile = join(dir, "chat-token");
    writeFileSync(missingTokenFile, `${CHAT_TOKEN}\n`, { mode: 0o600 });
    const env = sidecarEnv(missingTokenFile);
    env.CLUTCH_CHAT_PORT = String(missingPort);
    delete env.CLUTCH_CHAT_LAUNCHER_MCODE;
    env.CLUTCH_MCODE_CLI = "clutch-test-missing-mcode-executable";
    const missingSidecar = spawn(TSX, [BRIDGE], { env, stdio: ["ignore", "pipe", "pipe"] });
    try {
      await waitFor(`http://127.0.0.1:${missingPort}/clutch/v1/health`, { Authorization: `Bearer ${CHAT_TOKEN}` });
      const sessions = await fetch(`http://127.0.0.1:${missingPort}/clutch/v1/sessions?engine=mcode`, {
        headers: { Authorization: `Bearer ${CHAT_TOKEN}` },
      });
      expect(sessions.status).toBe(502);
      const health = await fetch(`http://127.0.0.1:${missingPort}/clutch/v1/health`, {
        headers: { Authorization: `Bearer ${CHAT_TOKEN}` },
      });
      expect(health.status).toBe(200);
    } finally {
      missingSidecar.kill("SIGKILL");
    }
  }, 60000);
});

describe("project and archive routes", () => {
  const metaUrl = (): string => `http://127.0.0.1:${chatPort}/clutch/v1/session-meta`;
  const projectsUrl = (): string => `http://127.0.0.1:${chatPort}/clutch/v1/projects`;

  // Validate the sidecar's response envelopes before the test reads them:
  // a shape change should fail here, at the boundary, not inside an expect.
  const TestApiResponseSchema = z
    .object({
      projects: z.array(z.unknown()).optional(),
      sessions: z.record(z.string(), z.unknown()).optional(),
      project: z.record(z.string(), z.unknown()).optional(),
      created: z.boolean().optional(),
      entry: z.record(z.string(), z.unknown()).optional(),
      ok: z.boolean().optional(),
      error: z.string().optional(),
    })
    .strict();

  async function meta(method: string, url: string, body?: unknown) {
    const res = await fetch(url, {
      method,
      headers: chatHeaders(),
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return { status: res.status, json: TestApiResponseSchema.parse(await res.json()) };
  }

  it("starts empty and stays behind the chat token", async () => {
    const anon = await fetch(metaUrl());
    expect(anon.status).toBe(401);

    const got = await meta("GET", metaUrl());
    expect(got.status).toBe(200);
    expect(got.json.projects).toEqual([]);
    expect(got.json.sessions).toEqual({});
  });

  it("creates a project and assigns a thread to it", async () => {
    const created = await meta("POST", projectsUrl(), { name: "  Clutch   Work  " });
    expect(created.status).toBe(201);
    const project = created.json.project as { id: string; name: string };
    expect(project.name).toBe("Clutch Work");

    const assigned = await meta("PUT", metaUrl(), { sessionId: "session-a", projectId: project.id });
    expect(assigned.status).toBe(200);
    const sessions = assigned.json.sessions as Record<string, { projectId?: string }>;
    expect(sessions["session-a"]?.projectId).toBe(project.id);

    // It survives a fresh read:  this is the point of the store existing.
    const reread = await meta("GET", metaUrl());
    const rereadSessions = reread.json.sessions as Record<string, { projectId?: string }>;
    expect(rereadSessions["session-a"]?.projectId).toBe(project.id);
  });

  it("returns the same project for the same name instead of duplicating it", async () => {
    const first = await meta("POST", projectsUrl(), { name: "Repeatable" });
    const second = await meta("POST", projectsUrl(), { name: "repeatable" });
    expect(first.json.created).toBe(true);
    expect(second.json.created).toBe(false);
    expect((second.json.project as { id: string }).id).toBe((first.json.project as { id: string }).id);
  });

  it("archives and then restores a thread", async () => {
    const archived = await meta("PUT", metaUrl(), { sessionId: "session-archive", archived: true });
    expect(archived.status).toBe(200);
    expect((archived.json.entry as { archived?: boolean }).archived).toBe(true);

    const restored = await meta("PUT", metaUrl(), { sessionId: "session-archive", archived: false });
    const sessions = restored.json.sessions as Record<string, unknown>;
    // Un-archiving clears the record entirely rather than leaving a tombstone.
    expect(sessions["session-archive"]).toBeUndefined();
  });

  it("clears an assignment with an explicit null", async () => {
    const projects = (await meta("GET", metaUrl())).json.projects as { id: string }[];
    const id = projects[0]?.id;
    expect(id).toBeTruthy();
    const cleared = await meta("PUT", metaUrl(), { sessionId: "session-a", projectId: null });
    const sessions = cleared.json.sessions as Record<string, { projectId?: string }>;
    expect(sessions["session-a"]?.projectId).toBeUndefined();
  });

  it("rejects a dangling project, a bad body and an empty update", async () => {
    expect((await meta("PUT", metaUrl(), { sessionId: "s", projectId: "prj_nope" })).status).toBe(400);
    expect((await meta("PUT", metaUrl(), { projectId: "prj_nope" })).status).toBe(400);
    expect((await meta("PUT", metaUrl(), { sessionId: "s" })).status).toBe(400);
    expect((await meta("PUT", metaUrl(), { sessionId: "s", archived: "yes" })).status).toBe(400);
    expect((await meta("POST", projectsUrl(), { name: "   " })).status).toBe(400);
    expect((await meta("POST", projectsUrl(), {})).status).toBe(400);
  });

  it("answers a literal null body with 400 on every JSON route and stays up", async () => {
    // `null` is valid JSON, so it passes the parse and used to reach a
    // property read inside the async handler, which ended the bridge.
    expect((await meta("PUT", metaUrl(), null)).status).toBe(400);
    expect((await meta("POST", projectsUrl(), null)).status).toBe(400);
    for (const path of ["/clutch/v1/sessions/load", "/clutch/v1/chat", "/clutch/v1/chat/cancel"]) {
      for (const body of ["null", "[]", "7"]) {
        const res = await fetch(`http://127.0.0.1:${chatPort}${path}`, {
          method: "POST",
          headers: chatHeaders(),
          body,
        });
        expect(res.status, `${path} ${body}`).toBe(400);
      }
    }
    const health = await fetch(`http://127.0.0.1:${chatPort}/clutch/v1/health`, { headers: chatHeaders() });
    expect(health.status).toBe(200);
  });

  it("deleting a project clears the assignments that pointed at it", async () => {
    const made = await meta("POST", projectsUrl(), { name: "Doomed" });
    const id = (made.json.project as { id: string }).id;
    await meta("PUT", metaUrl(), { sessionId: "session-doomed", projectId: id });

    const res = await fetch(`${projectsUrl()}/${encodeURIComponent(id)}`, {
      method: "DELETE",
      headers: chatHeaders(),
    });
    expect(res.status).toBe(200);
    const json = TestApiResponseSchema.parse(await res.json());
    expect(json.sessions?.["session-doomed"]).toBeUndefined();

    const again = await fetch(`${projectsUrl()}/${encodeURIComponent(id)}`, {
      method: "DELETE",
      headers: chatHeaders(),
    });
    expect(again.status).toBe(404);
  });
});
