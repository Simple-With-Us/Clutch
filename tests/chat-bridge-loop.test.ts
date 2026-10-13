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
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
  chatPort = await freePort();

  sidecar = spawn(TSX, [BRIDGE], { env: sidecarEnv(tokenFile), stdio: ["ignore", "pipe", "pipe"] });
  sidecar.stderr?.on("data", () => undefined);
  await waitFor(`http://127.0.0.1:${chatPort}/clutch/v1/health`, { Authorization: `Bearer ${CHAT_TOKEN}` });
}, 60000);

function sidecarEnv(tokenFile: string): NodeJS.ProcessEnv {
  return {
    ...process.env,
    CLUTCH_CHAT_PORT: String(chatPort),
    CLUTCH_CHAT_TOKEN_FILE: tokenFile,
    CLUTCH_TAILNET_HOST: "loopback-test.ts.net",
    CLUTCH_CHAT_LAUNCHER_DEEPSEEK: join(process.cwd(), "tests", "fixtures", "chat-bridge-stub.mjs"),
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
});
