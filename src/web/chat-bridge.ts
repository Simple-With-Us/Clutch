#!/usr/bin/env node
/**
 * Clutch chat bridge — the native-chat SSE sidecar.
 *
 * `dsh web` exposes no REST API (its browser speaks the internal cordis
 * protocol), so native clients get this thin loopback server instead:
 *
 *   POST /clutch/v1/chat    {prompt, model?, sessionId?, cwd?} → SSE stream
 *   GET  /clutch/v1/health  liveness + advertised models
 *
 * SSE events: `message` {text}, `thought` {text}, `done`
 * {stopReason, sessionId}.  Each turn runs a real coding session through
 * the existing Python ACP bridges (DeepSeek via `scripts/dsh-acp.sh`,
 * MiniMax via `scripts/minimax-acp.sh`), so the phone gets the same tool
 * loop, workspace files, and sessions as the desktop — never a plain
 * cloud-chat downgrade.
 *
 * Security, mirroring `start-web.sh`:
 * - Binds 127.0.0.1 only.  Tailnet clients arrive through
 *   `tailscale serve` (see `scripts/chat-bridge.sh`).
 * - Every request must carry a trusted `Host` (loopback, this Mac's
 *   MagicDNS name, `CLUTCH_TAILNET_IPV4`, `CLUTCH_TRUSTED_HOSTS`) and a
 *   `Bearer` token minted at boot into `$CLUTCH_HOME/chat-token`
 *   (mode 600).  The token rides to the phone inside the pairing link.
 * - Logs carry lengths and ids only — never prompt text or tokens.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { clutchChatPort } from "../shared/ports.ts";
import { isTrustedHostHeader, tailnetDnsName, trustedAuthoritySet } from "./pair-link.ts";
import { CometChatRelay, cleanEnvValue, cometchatConfigFromEnv, createStreamSink, type StreamSink } from "./cometchat-relay.ts";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const HOST = "127.0.0.1";
const PORT = Number(clutchChatPort());
const CLUTCH_HOME = process.env.CLUTCH_HOME ?? join(homedir(), ".clutch");
const TOKEN_FILE = process.env.CLUTCH_CHAT_TOKEN_FILE ?? join(CLUTCH_HOME, "chat-token");

type Engine = "deepseek" | "minimax";

const LAUNCHERS: Record<Engine, string> = {
  // CLUTCH_CHAT_LAUNCHER_<ENGINE> overrides exist for the full-loop test,
  // which points the engines at a stub script. Production always uses the
  // shipped launchers below.
  deepseek: process.env.CLUTCH_CHAT_LAUNCHER_DEEPSEEK?.trim() || join(ROOT, "scripts", "dsh-acp.sh"),
  minimax: process.env.CLUTCH_CHAT_LAUNCHER_MINIMAX?.trim() || join(ROOT, "scripts", "minimax-acp.sh"),
};

function log(line: string): void {
  process.stderr.write(`chat-bridge: ${line}\n`);
}

/** Route a model id to its engine. Unknown prefixes default to DeepSeek. */
export function routeForModel(model: string | undefined, engine: string | undefined): Engine {
  if (engine === "minimax" || engine === "deepseek") return engine;
  if (typeof model === "string" && /^minimax/i.test(model.trim())) return "minimax";
  return "deepseek";
}

/** Load the Bearer token, minting and persisting it (mode 600) on first boot. */
export function loadOrMintToken(file: string = TOKEN_FILE): string {
  try {
    const saved = readFileSync(file, "utf8").trim();
    if (saved.length >= 32) return saved;
  } catch {
    /* fall through and mint */
  }
  mkdirSync(dirname(file), { recursive: true });
  const token = randomBytes(32).toString("hex");
  // start-web.sh and start-web.ts both spawn the sidecar, so two processes can
  // reach this mint concurrently.  Write through a temp file and rename so the
  // token file is only ever swapped atomically, never left half-written; then
  // re-read so a loser always serves the winner's token rather than the one it
  // minted and lost the race to overwrite.
  const tmp = `${file}.${process.pid}.${randomBytes(6).toString("hex")}`;
  writeFileSync(tmp, `${token}\n`, { mode: 0o600 });
  try {
    renameSync(tmp, file);
  } catch {
    /* another process won the rename; fall through to the re-read */
  }
  try {
    return readFileSync(file, "utf8").trim();
  } catch {
    return token;
  }
}

function bearerOk(req: IncomingMessage, token: string): boolean {
  const header = req.headers.authorization ?? "";
  const match = /^Bearer (.+)$/.exec(header.trim());
  if (!match || !match[1]) return false;
  const a = Buffer.from(match[1]);
  const b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
}

interface AcpUpdate {
  sessionId: string;
  kind: "agent_message_chunk" | "agent_thought_chunk";
  text: string;
}

/** Minimal JSON-RPC client over a bridge launcher's stdio. */
class Bridge {
  private child: ChildProcess | null = null;
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private onUpdate: ((u: AcpUpdate) => void) | null = null;
  private buffer = "";

  constructor(
    readonly engine: Engine,
    private env: NodeJS.ProcessEnv,
  ) {}

  setUpdateHandler(fn: (u: AcpUpdate) => void): void {
    this.onUpdate = fn;
  }

  private spawn(): void {
    const launcher = LAUNCHERS[this.engine];
    if (!existsSync(launcher)) throw new Error(`missing launcher ${launcher}`);
    this.child = spawn(launcher, [], { stdio: ["pipe", "pipe", "inherit"], env: this.env });
    this.child.stdout?.setEncoding("utf8");
    this.child.stdout?.on("data", (chunk: string) => this.feed(chunk));
    this.child.on("exit", () => {
      this.child = null;
      // Drop any partial line left by a mid-line crash; the next spawn starts
      // fresh instead of framing new stdout onto the old fragment.
      this.buffer = "";
      for (const [, p] of this.pending) p.reject(new Error("bridge exited"));
      this.pending.clear();
    });
  }

  private feed(chunk: string): void {
    this.buffer += chunk;
    let nl: number;
    while ((nl = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, nl).trim();
      this.buffer = this.buffer.slice(nl + 1);
      if (!line) continue;
      let msg: { id?: number; method?: string; params?: Record<string, unknown>; result?: unknown; error?: { message?: string } };
      try {
        msg = JSON.parse(line) as typeof msg;
      } catch {
        continue;
      }
      if (msg.method === "session/update") {
        const params = (msg.params ?? {}) as { sessionId?: unknown; update?: { sessionUpdate?: unknown; content?: { text?: unknown } } };
        const kind = params.update?.sessionUpdate;
        const text = params.update?.content?.text;
        if ((kind === "agent_message_chunk" || kind === "agent_thought_chunk") && typeof text === "string" && typeof params.sessionId === "string") {
          this.onUpdate?.({ sessionId: params.sessionId, kind, text });
        }
        continue;
      }
      if (typeof msg.id === "number") {
        const p = this.pending.get(msg.id);
        if (!p) continue;
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(String(msg.error.message ?? "bridge error")));
        else p.resolve(msg.result);
      }
    }
  }

  private send(method: string, params: Record<string, unknown>): Promise<unknown> {
    if (!this.child) this.spawn();
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.child?.stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`, (err) => {
        if (err) {
          this.pending.delete(id);
          reject(err);
        }
      });
    });
  }

  initialize(): Promise<unknown> {
    return this.send("initialize", { protocolVersion: 1 });
  }

  async newSession(cwd: string): Promise<string> {
    const result = (await this.send("session/new", { cwd, mcpServers: [] })) as { sessionId?: unknown };
    if (typeof result?.sessionId !== "string" || result.sessionId.length === 0) {
      throw new Error("bridge returned no sessionId");
    }
    return result.sessionId;
  }

  prompt(sessionId: string, text: string): Promise<{ stopReason: string }> {
    return this.send("session/prompt", { sessionId, prompt: text }) as Promise<{ stopReason: string }>;
  }

  cancel(sessionId: string): void {
    this.send("session/cancel", { sessionId }).catch(() => undefined);
  }
}

interface ChatSession {
  engine: Engine;
  bridgeSessionId: string;
  busy: boolean;
  stream: ((u: AcpUpdate) => void) | null;
}

function readJsonBody(req: IncomingMessage, limitBytes = 1_000_000): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > limitBytes) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
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

function sseSend(res: ServerResponse, event: string, data: unknown): void {
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

async function main(): Promise<void> {
  const token = loadOrMintToken();
  const tokenFingerprint = createHash("sha256").update(token).digest("hex").slice(0, 12);
  const tailnetHost = process.env.CLUTCH_TAILNET_HOST?.trim() || null;
  const extraHosts = (process.env.CLUTCH_TRUSTED_HOSTS ?? "").split(",");
  const ipv4 = process.env.CLUTCH_TAILNET_IPV4?.trim() || null;
  const allowed = trustedAuthoritySet([tailnetHost, ipv4, ...extraHosts], String(PORT));

  const bridges = new Map<Engine, Bridge>();
  const sessions = new Map<string, ChatSession>();
  const bridgeEnv = { ...process.env, CLUTCH_RUNTIME_ROOT: ROOT, DSH_PERMISSION_MODE: "danger-full-access" };
  // CometChat relay is additive: SSE stays the primary transport, and the
  // relay only runs when the backend is configured AND the caller names a
  // target. Backend-only key; never leaves this process.
  const ccConfig = cometchatConfigFromEnv();
  const ccRelay = ccConfig ? new CometChatRelay(ccConfig, { onLog: log }) : null;
  if (ccRelay) log("cometchat relay armed");

  function bridgeFor(engine: Engine): Bridge {
    let b = bridges.get(engine);
    if (!b) {
      b = new Bridge(engine, bridgeEnv);
      b.setUpdateHandler((u) => {
        const target = [...sessions.values()].find((s) => s.bridgeSessionId === u.sessionId && s.busy);
        target?.stream?.(u);
      });
      bridges.set(engine, b);
    }
    return b;
  }

  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? "/", `http://${HOST}:${PORT}`);
    if (!isTrustedHostHeader(req.headers.host, allowed)) {
      res.writeHead(403, { "content-type": "application/json" }).end(JSON.stringify({ error: "untrusted host" }));
      return;
    }
    if (!bearerOk(req, token)) {
      res.writeHead(401, { "content-type": "application/json" }).end(JSON.stringify({ error: "unauthorized" }));
      return;
    }

    if (req.method === "GET" && url.pathname === "/clutch/v1/health") {
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ ok: true, engines: ["deepseek", "minimax"] }));
      return;
    }

    if (req.method === "GET" && url.pathname === "/clutch/v1/chat-config") {
      // Everything the native tab needs after pairing: which chat port it
      // already reached, and the CometChat app coordinates (dev-grade Auth
      // Key for this try; server-minted user tokens are the follow-up).
      // Gated by the chat token like everything else here.
      const appId = cleanEnvValue(process.env.COMETCHAT_APP_ID) || null;
      const region = cleanEnvValue(process.env.COMETCHAT_REGION) || null;
      const authKey = cleanEnvValue(process.env.COMETCHAT_AUTH_KEY) || null;
      const agentUid = cleanEnvValue(process.env.COMETCHAT_AGENT_UID) || "clutch-agent";
      res.writeHead(200, { "content-type": "application/json" }).end(
        JSON.stringify({
          ok: true,
          chatPort: PORT,
          cometchat:
            appId && region && authKey
              ? { appId, region, authKey, agentUid }
              : null,
        }),
      );
      return;
    }

    if (req.method === "POST" && url.pathname === "/clutch/v1/chat") {
      let body: {
        prompt?: unknown;
        model?: unknown;
        engine?: unknown;
        sessionId?: unknown;
        cwd?: unknown;
        relay?: unknown;
      };
      try {
        body = (await readJsonBody(req)) as typeof body;
      } catch {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
        return;
      }
      const prompt = typeof body.prompt === "string" ? body.prompt.trim() : "";
      if (!prompt) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "prompt is required" }));
        return;
      }
      const engine = routeForModel(
        typeof body.model === "string" ? body.model : undefined,
        typeof body.engine === "string" ? body.engine : undefined,
      );
      const cwd = typeof body.cwd === "string" && body.cwd.length > 0 ? body.cwd : process.env.HOME ?? "/tmp";

      let chatId = typeof body.sessionId === "string" && body.sessionId.length > 0 ? body.sessionId : null;
      let session = chatId ? sessions.get(chatId) : undefined;
      if (!session || session.engine !== engine) {
        chatId = randomBytes(16).toString("hex");
        session = { engine, bridgeSessionId: "", busy: false, stream: null };
        sessions.set(chatId, session);
      }
      if (session.busy) {
        res.writeHead(409, { "content-type": "application/json" }).end(JSON.stringify({ error: "session busy", sessionId: chatId }));
        return;
      }

      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });
      sseSend(res, "start", { sessionId: chatId, engine });
      log(`chat start session=${chatId} engine=${engine} promptChars=${prompt.length}`);

      const active = session;
      active.busy = true;
      // Engine diagnostics ride the bridge as [stderr]-prefixed message
      // chunks (the Shellular-visible contract). On a polished surface they
      // are working detail, not the answer — route them to `thought` without
      // dropping anything.
      const route = (u: AcpUpdate): { event: "message" | "thought"; text: string } => {
        if (u.kind === "agent_thought_chunk" || u.text.startsWith("[stderr] ")) {
          return { event: "thought", text: u.text };
        }
        return { event: "message", text: u.text };
      };
      // Optional CometChat fan-out: {receiver, receiverType} names the
      // 1:1 or group the agent thread mirrors into.
      let sink: StreamSink | null = null;
      if (ccRelay && body.relay && typeof body.relay === "object") {
        const relay = body.relay as { receiver?: unknown; receiverType?: unknown };
        if (typeof relay.receiver === "string" && relay.receiver.length > 0 && (relay.receiverType === "user" || relay.receiverType === "group")) {
          sink = createStreamSink(ccRelay, { receiver: relay.receiver, receiverType: relay.receiverType });
          log(`chat relay session=${chatId} receiverType=${relay.receiverType}`);
        }
      }
      active.stream = (u) => {
        const r = route(u);
        sseSend(res, r.event, { text: r.text });
        sink?.onUpdate(u.kind, r.text);
      };
      let settled = false;
      const finish = (event: string, data: unknown): void => {
        if (settled) return;
        settled = true;
        active.busy = false;
        active.stream = null;
        sseSend(res, event, data);
        res.end();
      };
      req.on("close", () => {
        if (!settled && active.bridgeSessionId) {
          try {
            bridgeFor(engine).cancel(active.bridgeSessionId);
          } catch {
            /* already gone */
          }
          log(`chat cancel session=${chatId}`);
        }
        finish("done", { stopReason: "cancelled", sessionId: chatId });
      });

      try {
        const bridge = bridgeFor(engine);
        await bridge.initialize();
        if (!active.bridgeSessionId) {
          active.bridgeSessionId = await bridge.newSession(cwd);
          log(`chat session=${chatId} bridgeSession=${active.bridgeSessionId} cwdChars=${cwd.length}`);
        }
        const result = await bridge.prompt(active.bridgeSessionId, prompt);
        log(`chat end session=${chatId} stopReason=${result.stopReason}`);
        if (sink) {
          try {
            await sink.onDone();
          } catch (err) {
            // Relay failures must not break the SSE transport.
            log(`chat relay flush failed session=${chatId} message=${(err as Error).message.slice(0, 120)}`);
          }
        }
        finish("done", { stopReason: result.stopReason ?? "endTurn", sessionId: chatId });
      } catch (err) {
        log(`chat error session=${chatId} message=${(err as Error).message.slice(0, 120)}`);
        // The bridge child may have exited mid-turn, taking its session with
        // it.  Forget the id so the next turn mints a fresh one instead of
        // prompting a respawned child with a session it never knew about.
        active.bridgeSessionId = "";
        if (sink) {
          try {
            await sink.onDone();
          } catch {
            /* relay failures must not change the error surfaced to the client */
          }
        }
        finish("error", { message: (err as Error).message.slice(0, 300), sessionId: chatId });
      }
      return;
    }

    res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: "not found" }));
  });

  server.on("error", (err: Error & { code?: string }) => {
    // start-web.sh and start-web.ts both launch the sidecar; when both
    // entry points run, the second bind loses. That is fine — one bridge
    // serves the port — so yield quietly instead of crashing loudly.
    if ((err as { code?: string }).code === "EADDRINUSE") {
      log(`port busy, another bridge holds it`);
      process.exit(0);
    }
    log(`listen failed: ${err.message}`);
    process.exit(1);
  });
  server.listen(PORT, HOST, () => {
    log(`listening on ${HOST}:${PORT} (token fp ${tokenFingerprint})`);
  });
}

// Importing this module (tests, relay) must not bind the port or mint the
// token — only a direct run serves.
const invokedAs = process.argv[1];
if (invokedAs && import.meta.url === pathToFileURL(resolve(invokedAs)).href) {
  await main();
}
