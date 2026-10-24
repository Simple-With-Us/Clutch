#!/usr/bin/env node
/**
 * Clutch chat bridge — the native-chat SSE sidecar.
 *
 * `dsh web` exposes no REST API (its browser speaks the internal cordis
 * protocol), so native clients get this thin loopback server instead:
 *
 *   POST /clutch/v1/chat    {prompt, model?, sessionId?, cwd?} → SSE stream
 *   POST /clutch/v1/chat/cancel {sessionId} → stop one in-flight turn
 *   GET  /clutch/v1/thread?uid=<deviceUid>&limit=<n> → agent thread bubbles
 *   GET  /clutch/v1/health  liveness, engines, and MiniMax Code availability
 *   GET  /clutch/v1/sessions?engine=mcode → MiniMax Code's own threads
 *   POST /clutch/v1/sessions/load          → replay one mcode thread
 *
 * SSE events: `message` {text}, `thought` {text}, `done`
 * {stopReason, sessionId}.  Each turn runs a real coding session through
 * the existing Python ACP bridges (DeepSeek via `scripts/dsh-acp.sh`,
 * MiniMax via `scripts/minimax-acp.sh`).  The MiniMax Code Remote is a
 * separate direct `mcode acp` client so its existing native threads remain
 * visible and resumable.  None of these paths is a plain cloud-chat downgrade.
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
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { z } from "zod";

import { clutchChatPort } from "../shared/ports.ts";
import { initClutchSettings } from "../shared/clutchSettings.ts";
import { isTrustedHostHeader, tailnetDnsName, trustedAuthoritySet } from "./pair-link.ts";
import { handleQuotasRequest } from "./quotas-route.ts";
import { handleInfisicalSettingsRequest } from "./infisical-route.ts";
import { CometChatRelay, cleanEnvValue, cometchatConfigFromEnv, createStreamSink, isThreadUid, THREAD_MESSAGE_LIMIT_DEFAULT, THREAD_MESSAGE_LIMIT_MAX, type StreamSink } from "./cometchat-relay.ts";
import { miniMaxCodeRemoteHtml } from "./minimax-code-remote.ts";
import { readSessionUsage, withRate, type SessionUsage } from "./session-usage.ts";
import {
  loadSessionMeta,
  newProjectId,
  normalizeProjectName,
  removeProject,
  saveSessionMeta,
  sessionMetaPath,
  upsertSession,
  type SessionMetaFile,
} from "./session-meta.ts";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const HOST = "127.0.0.1";
const PORT = Number(clutchChatPort());
const CLUTCH_HOME = process.env.CLUTCH_HOME ?? join(homedir(), ".clutch");
const TOKEN_FILE = process.env.CLUTCH_CHAT_TOKEN_FILE ?? join(CLUTCH_HOME, "chat-token");
/** Where the engine keeps its session logs — the only place real usage lives. */
const DSH_HOME = process.env.CLUTCH_DSH_HOME ?? join(CLUTCH_HOME, "dsh");
const SESSION_META_FILE = process.env.CLUTCH_SESSION_META_FILE ?? sessionMetaPath(CLUTCH_HOME);

type Engine = "deepseek" | "minimax" | "mcode";

interface Launcher {
  command: string;
  args: string[];
}

const defaultMcode = [
  join(homedir(), ".local", "bin", "mcode"),
  join(homedir(), ".minimax-code", "bin", "mcode"),
].find(existsSync) ?? "mcode";
const mcodeLauncherOverride = process.env.CLUTCH_CHAT_LAUNCHER_MCODE?.trim();

const LAUNCHERS: Record<Engine, Launcher> = {
  // CLUTCH_CHAT_LAUNCHER_<ENGINE> overrides exist for the full-loop test,
  // which points the engines at a stub script. Production always uses the
  // shipped launchers below.
  deepseek: { command: process.env.CLUTCH_CHAT_LAUNCHER_DEEPSEEK?.trim() || join(ROOT, "scripts", "dsh-acp.sh"), args: [] },
  minimax: { command: process.env.CLUTCH_CHAT_LAUNCHER_MINIMAX?.trim() || join(ROOT, "scripts", "minimax-acp.sh"), args: [] },
  mcode: mcodeLauncherOverride
    ? { command: mcodeLauncherOverride, args: [] }
    : { command: process.env.CLUTCH_MCODE_CLI?.trim() || defaultMcode, args: ["acp"] },
};

function log(line: string): void {
  process.stderr.write(`chat-bridge: ${line}\n`);
}

/** Route a model id to its engine. Unknown prefixes default to DeepSeek. */
export function routeForModel(model: string | undefined, engine: string | undefined): Engine {
  if (engine === "minimax" || engine === "deepseek" || engine === "mcode") return engine;
  if (typeof model === "string" && /^minimax/i.test(model.trim())) return "minimax";
  return "deepseek";
}

/**
 * Validates `GET /clutch/v1/thread` query: which device thread and how many
 * bubbles. UIDs stay app-scoped slugs so they cannot escape into paths.
 */export function parseThreadQuery(params: URLSearchParams): { uid: string; limit: number } | { error: string } {
  const uid = params.get("uid") ?? "";
  if (!isThreadUid(uid)) return { error: "uid is required" };
  return { uid, limit: parseLimitParam(params.get("limit"), THREAD_MESSAGE_LIMIT_DEFAULT, THREAD_MESSAGE_LIMIT_MAX) };
}

/** Bounded integer query param with a default; garbage means the default. */
export function parseLimitParam(raw: string | null, def: number, max: number): number {
  const text = (raw ?? "").trim();
  if (text === "") return def;
  const n = Number(text);
  if (!Number.isFinite(n)) return def;
  return Math.min(Math.max(Math.trunc(n), 1), max);
}

/** Newest first by `updatedAt`; entries without one sort last. Never mutates. */
export function sortSessionsByUpdated<T extends { updatedAt?: string }>(sessions: readonly T[]): T[] {
  return [...sessions].sort((a, b) => {
    if (!a.updatedAt && !b.updatedAt) return 0;
    if (!a.updatedAt) return 1;
    if (!b.updatedAt) return -1;
    if (a.updatedAt === b.updatedAt) return 0;
    return a.updatedAt < b.updatedAt ? 1 : -1;
  });
}

/** Last `limit` entries; the whole array when it already fits. */
export function sliceThreadHistory<T>(history: readonly T[], limit: number): T[] {
  if (history.length <= limit) return [...history];
  return history.slice(history.length - limit);
}

/**
 * The tailnet host a sidecar should trust: an explicit override wins, and
 * otherwise the MagicDNS name from `tailscale status --self --json`.  The
 * Mac launcher used to be the only place that detected this (for `dsh web`),
 * so a sidecar run on its own — a Linux MiniMax Code server, a manual
 * `chat-bridge.sh` — trusted loopback only and 403'd every phone request
 * until someone exported the name by hand.
 */
export function resolveTailnetHost(explicit: string | null | undefined, statusJson: unknown): string | null {
  const override = explicit?.trim();
  if (override) return override.toLowerCase();
  return tailnetDnsName(statusJson);
}

function readTailnetStatus(): Promise<unknown> {
  return new Promise((resolvePromise) => {
    const child = spawn("tailscale", ["status", "--self", "--json"], { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    child.stdout.on("data", (chunk: Buffer) => {
      out += chunk.toString("utf8");
    });
    child.on("error", () => resolvePromise(null));
    child.on("exit", () => {
      try {
        resolvePromise(JSON.parse(out));
      } catch {
        resolvePromise(null);
      }
    });
  });
}

/**
 * Detect this machine's tailnet name, retrying briefly: tailscaled routinely
 * starts after the sidecar on a fresh boot, and trusting loopback only until
 * the next restart is the failure this exists to avoid.
 */
async function detectTailnetHost(): Promise<string | null> {
  const explicit = process.env.CLUTCH_TAILNET_HOST?.trim();
  if (explicit) return explicit.toLowerCase();
  const waitMs = Number(process.env.CLUTCH_TAILNET_WAIT_SECONDS ?? 10) * 1000;
  const deadline = Date.now() + (Number.isFinite(waitMs) && waitMs >= 0 ? waitMs : 10_000);
  for (;;) {
    const host = resolveTailnetHost(null, await readTailnetStatus());
    if (host) return host;
    if (Date.now() >= deadline) return null;
    await new Promise((r) => setTimeout(r, 1000));
  }
}

/** Whether the direct MiniMax Code launcher is present on this machine. */
export function mcodeAvailable(launcher: Launcher = LAUNCHERS.mcode): boolean {
  return launcher.command.includes("/") ? existsSync(launcher.command) : true;
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
    try {
      unlinkSync(tmp);
    } catch {
      /* tmp may already be gone */
    }
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
  kind: "agent_message_chunk" | "agent_thought_chunk" | "user_message_chunk";
  text: string;
}

interface AcpSessionInfo {
  sessionId: string;
  cwd?: string;
  title?: string;
  updatedAt?: string;
  /** Real engine accounting, present only when the log could be read. */
  usage?: SessionUsage;
  /** Clutch-side Project assignment and archive state. */
  projectId?: string;
  archived?: boolean;
}

/** Read every session's real usage in one pass.  `readSessionUsage` caches per
 *  log mtime, so a refresh that finds nothing new costs nothing. */
export function attachUsage(sessions: readonly AcpSessionInfo[]): AcpSessionInfo[] {
  return sessions.map((session) => {
    const usage = readSessionUsage(DSH_HOME, session.sessionId);
    return usage ? { ...session, usage } : session;
  });
}

/** Apply Project/archive state, dropping archived threads unless asked for.
 *  An archived thread is still resumable — it is hidden from the default list,
 *  never deleted. */
export function applySessionMeta(
  sessions: readonly AcpSessionInfo[],
  meta: SessionMetaFile,
  includeArchived: boolean,
): AcpSessionInfo[] {
  const out: AcpSessionInfo[] = [];
  for (const session of sessions) {
    const entry = meta.sessions[session.sessionId];
    if (entry?.archived && !includeArchived) continue;
    out.push({
      ...session,
      ...(entry?.projectId ? { projectId: entry.projectId } : {}),
      ...(entry?.archived ? { archived: true } : {}),
    });
  }
  return out;
}

class BridgeProcessError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BridgeProcessError";
  }
}

/** Minimal JSON-RPC client over a bridge launcher's stdio. */
class Bridge {
  private child: ChildProcess | null = null;
  private initialized: Promise<unknown> | null = null;
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private onUpdate: ((u: AcpUpdate) => void) | null = null;
  private onProcessFailure: (() => void) | null = null;
  private buffer = "";

  constructor(
    readonly engine: Engine,
    private env: NodeJS.ProcessEnv,
  ) {}

  setUpdateHandler(fn: (u: AcpUpdate) => void): void {
    this.onUpdate = fn;
  }

  setProcessFailureHandler(fn: () => void): void {
    this.onProcessFailure = fn;
  }

  private spawn(): void {
    const launcher = LAUNCHERS[this.engine];
    if (launcher.command.includes("/") && !existsSync(launcher.command)) {
      throw new Error(`missing launcher ${launcher.command}`);
    }
    const child = spawn(launcher.command, launcher.args, { stdio: ["pipe", "pipe", "inherit"], env: this.env });
    this.child = child;
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      if (this.child === child) this.feed(chunk);
    });
    child.stdin?.on("error", (err) => {
      this.resetChild(child, new BridgeProcessError(`bridge stdin failed: ${err.message}`));
    });
    child.on("error", (err) => {
      this.resetChild(child, new BridgeProcessError(`bridge failed: ${err.message}`));
    });
    // `close` fires only once stdio has drained, so every buffered chunk is fed
    // before the reset below; `exit` would let trailing stdout repopulate the
    // buffer and frame the next spawn onto a fragment of this child.
    child.on("close", () => {
      this.resetChild(child, new BridgeProcessError("bridge exited"));
    });
  }

  private resetChild(child: ChildProcess, error: BridgeProcessError): void {
    // An `error` event is normally followed by `close`.  Guard by identity so
    // that delayed cleanup from the failed child cannot tear down its replacement.
    if (this.child !== child) return;
    this.child = null;
    this.initialized = null;
    // Drop any partial line left by a mid-line crash; the next spawn starts
    // fresh instead of framing new stdout onto the old fragment.
    this.buffer = "";
    this.onProcessFailure?.();
    for (const [, pending] of this.pending) pending.reject(error);
    this.pending.clear();
  }

  private feed(chunk: string): void {
    this.buffer += chunk;
    let nl: number;
    while ((nl = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, nl).trim();
      this.buffer = this.buffer.slice(nl + 1);
      if (!line) continue;
      let msg: { id?: number | string; method?: string; params?: Record<string, unknown>; result?: unknown; error?: { message?: string } };
      try {
        msg = JSON.parse(line) as typeof msg;
      } catch {
        continue;
      }
      if (msg.method === "session/request_permission" && msg.id !== undefined) {
        const options = Array.isArray(msg.params?.options)
          ? msg.params.options as Array<{ optionId?: unknown; kind?: unknown }>
          : [];
        const choice = options.find((option) => option?.kind === "allow_once")
          ?? options.find((option) => option?.kind === "reject_once" || option?.kind === "reject_always");
        const outcome = typeof choice?.optionId === "string"
          ? { outcome: "selected", optionId: choice.optionId }
          : { outcome: "cancelled" };
        this.child?.stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { outcome } })}\n`);
        continue;
      }
      if (msg.method && msg.id !== undefined) {
        this.child?.stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method not supported" } })}\n`);
        continue;
      }
      if (msg.method === "session/update") {
        const params = (msg.params ?? {}) as { sessionId?: unknown; update?: { sessionUpdate?: unknown; content?: { text?: unknown } } };
        const kind = params.update?.sessionUpdate;
        const text = params.update?.content?.text;
        if (
          (kind === "agent_message_chunk" || kind === "agent_thought_chunk" || kind === "user_message_chunk")
          && typeof text === "string"
          && typeof params.sessionId === "string"
        ) {
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
    const child = this.child;
    const stdin = child?.stdin;
    if (!child || !stdin) return Promise.reject(new BridgeProcessError("bridge stdin unavailable"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`, (err) => {
        if (err) {
          this.resetChild(child, new BridgeProcessError(`bridge write failed: ${err.message}`));
        }
      });
    });
  }

  initialize(): Promise<unknown> {
    if (!this.initialized) {
      const initialization = this.send("initialize", {
        protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
      });
      const tracked = initialization.catch((error) => {
        if (this.initialized === tracked) this.initialized = null;
        throw error;
      });
      this.initialized = tracked;
    }
    return this.initialized;
  }

  async newSession(cwd: string): Promise<string> {
    const result = (await this.send("session/new", { cwd, mcpServers: [] })) as { sessionId?: unknown };
    if (typeof result?.sessionId !== "string" || result.sessionId.length === 0) {
      throw new Error("bridge returned no sessionId");
    }
    return result.sessionId;
  }

  async listSessions(cwd?: string, limit: number = 100): Promise<AcpSessionInfo[]> {
    const cap = Math.min(Math.max(Math.trunc(limit) || 100, 1), 500);
    const sessions: AcpSessionInfo[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 20; page += 1) {
      const result = (await this.send("session/list", {
        ...(cwd ? { cwd } : {}),
        ...(cursor ? { cursor } : {}),
      })) as { sessions?: unknown; nextCursor?: unknown };
      if (!Array.isArray(result?.sessions)) break;
      for (const item of result.sessions) {
        if (!item || typeof item !== "object") continue;
        const row = item as Record<string, unknown>;
        if (typeof row.sessionId !== "string" || row.sessionId.length === 0) continue;
        sessions.push({
          sessionId: row.sessionId,
          ...(typeof row.cwd === "string" ? { cwd: row.cwd } : {}),
          ...(typeof row.title === "string" ? { title: row.title } : {}),
          ...(typeof row.updatedAt === "string" ? { updatedAt: row.updatedAt } : {}),
        });
        if (sessions.length >= cap) break;
      }
      if (sessions.length >= cap) break;
      if (typeof result.nextCursor !== "string" || result.nextCursor.length === 0) break;
      cursor = result.nextCursor;
    }
    return sessions;
  }

  loadSession(sessionId: string, cwd: string): Promise<unknown> {
    return this.send("session/load", { sessionId, cwd, mcpServers: [] });
  }

  prompt(sessionId: string, text: string): Promise<{ stopReason: string }> {
    const prompt = this.engine === "mcode" ? [{ type: "text", text }] : text;
    return this.send("session/prompt", { sessionId, prompt }) as Promise<{ stopReason: string }>;
  }

  cancel(sessionId: string): void {
    this.send("session/cancel", { sessionId }).catch(() => undefined);
  }
}

interface ChatSession {
  engine: Engine;
  bridgeSessionId: string;
  resumeSessionId: string | null;
  cwd: string;
  busy: boolean;
  stream: ((u: AcpUpdate) => void) | null;
}

/** Untrusted request bodies for the project/archive routes.  Strict so an
 *  unexpected field is rejected instead of silently ignored. */
const SessionMetaPatchSchema = z
  .object({
    sessionId: z.string({ error: "sessionId is required" }).min(1, "sessionId is required").max(200, "sessionId is required"),
    projectId: z
      .string({ error: "projectId must be a string or null" })
      .max(200, "projectId must be a string or null")
      .nullable()
      .optional(),
    archived: z.boolean({ error: "archived must be a boolean" }).optional(),
  })
  .strict()
  .refine((v) => v.projectId !== undefined || v.archived !== undefined, { message: "nothing to update" });

/** Most sessions enriched with log-derived usage per list request. */
const USAGE_ENRICH_CAP = 50;

const ProjectCreateSchema = z
  .object({
    name: z.string({ error: "project name is required" }),
  })
  .strict();

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
  // Clutch's own settings (Infisical is the sole source of truth).  The bridge
  // is a separate process from start-web.ts, so it initializes its own
  // instance; this is what backs the native Infisical settings panel.
  const settings = await initClutchSettings();
  const tokenFingerprint = createHash("sha256").update(token).digest("hex").slice(0, 12);
  const tailnetHost = await detectTailnetHost();
  if (!tailnetHost) log("no tailnet host detected; remote (Tailscale) requests will 403 until tailscale is up — set CLUTCH_TAILNET_HOST to override");
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
      b.setProcessFailureHandler(() => {
        for (const session of sessions.values()) {
          if (session.engine === engine) session.bridgeSessionId = "";
        }
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

    // The shell itself contains no session data.  It receives the boot token
    // in the URL, removes it from browser history, and uses it only as the
    // Bearer credential for the protected API below.
    if (req.method === "GET" && url.pathname === "/minimax-code/") {
      res.writeHead(200, {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "content-security-policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:",
      }).end(miniMaxCodeRemoteHtml());
      return;
    }
    if (!bearerOk(req, token)) {
      res.writeHead(401, { "content-type": "application/json" }).end(JSON.stringify({ error: "unauthorized" }));
      return;
    }

    if (req.method === "GET" && url.pathname === "/clutch/v1/health") {
      res.writeHead(200, { "content-type": "application/json" }).end(
        JSON.stringify({
          ok: true,
          engines: ["deepseek", "minimax", "mcode"],
          mcode: { available: mcodeAvailable() },
          tailnetHost,
        }),
      );
      return;
    }

    if (req.method === "POST" && url.pathname === "/clutch/v1/chat/cancel") {
      // Explicit stop from a native client (the Mac/iPhone Stop button).
      // Dropping the SSE connection already cancels through the `close`
      // handler below; this endpoint exists so a client can stop a turn
      // without tearing down its stream reader first.  Unknown sessions are
      // a no-op success — the turn the caller meant to stop is already gone.
      let body: { sessionId?: unknown };
      try {
        body = (await readJsonBody(req)) as typeof body;
      } catch {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
        return;
      }
      const chatId = typeof body.sessionId === "string" ? body.sessionId : "";
      const session = chatId ? sessions.get(chatId) : undefined;
      let cancelled = false;
      if (session?.bridgeSessionId) {
        try {
          bridgeFor(session.engine).cancel(session.bridgeSessionId);
          cancelled = true;
        } catch {
          /* bridge already gone */
        }
      }
      log(`chat cancel-request session=${chatId || "none"} cancelled=${cancelled}`);
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ ok: true, cancelled }));
      return;
    }

    // Clutch-owned settings surface (machine identity + managed key
    // write-through), consumed by the native Hosts and Settings sheet.
    if (await handleQuotasRequest(req, res, url.pathname, token)) return;
    if (await handleInfisicalSettingsRequest(req, res, url.pathname, { settings })) return;

    if (req.method === "GET" && url.pathname === "/clutch/v1/sessions") {
      if (url.searchParams.get("engine") !== "mcode") {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "session discovery requires engine=mcode" }));
        return;
      }
      try {
        const bridge = bridgeFor("mcode");
        await bridge.initialize();
        const requestedCwd = url.searchParams.get("cwd")?.trim() || undefined;
        const limit = parseLimitParam(url.searchParams.get("limit"), 50, 200);
        const includeArchived = url.searchParams.get("archived") === "include";
        // Archived threads are dropped after listing, so over-fetch candidates
        // (capped well past the page size) to keep `limit` visible rows when
        // possible, then trim back to the requested page size after filtering.
        const fetchLimit = includeArchived ? limit : Math.max(limit, 500);
        const listed = sortSessionsByUpdated(await bridge.listSessions(requestedCwd, fetchLimit));
        const page = applySessionMeta(listed, loadSessionMeta(SESSION_META_FILE), includeArchived).slice(0, limit);
        // Reading usage means a synchronous zstd log read per session, so cap
        // how many rows get enriched in one request; rows past the cap simply
        // report no usage (the UI already renders "not reported").
        const sessions = attachUsage(page.slice(0, USAGE_ENRICH_CAP)).concat(page.slice(USAGE_ENRICH_CAP));
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ sessions }));
      } catch (err) {
        log(`mcode list failed message=${(err as Error).message.slice(0, 120)}`);
        res.writeHead(502, { "content-type": "application/json" }).end(
          JSON.stringify({ error: (err as Error).message.slice(0, 300) }),
        );
      }
      return;
    }

    if (req.method === "POST" && url.pathname === "/clutch/v1/sessions/load") {
      let body: { engine?: unknown; sessionId?: unknown; cwd?: unknown; limit?: unknown };
      try {
        body = (await readJsonBody(req)) as typeof body;
      } catch {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
        return;
      }
      if (typeof body !== "object" || body === null || Array.isArray(body)) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "JSON body must be an object" }));
        return;
      }
      if (body.engine !== "mcode" || typeof body.sessionId !== "string" || body.sessionId.length === 0) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "engine=mcode and sessionId are required" }));
        return;
      }
      const cwd = typeof body.cwd === "string" && body.cwd.length > 0 ? body.cwd : process.env.HOME ?? "/tmp";
      const historyLimit =
        typeof body.limit === "number" || typeof body.limit === "string"
          ? parseLimitParam(String(body.limit), 200, 1000)
          : 200;
      const chatId = randomBytes(16).toString("hex");
      const history: AcpUpdate[] = [];
      const session: ChatSession = {
        engine: "mcode",
        bridgeSessionId: body.sessionId,
        resumeSessionId: body.sessionId,
        cwd,
        busy: true,
        stream: (update) => {
          if (history.length < 20_000) history.push(update);
        },
      };
      sessions.set(chatId, session);
      try {
        const bridge = bridgeFor("mcode");
        await bridge.initialize();
        await bridge.loadSession(body.sessionId, cwd);
        session.busy = false;
        session.stream = null;
        res.writeHead(200, { "content-type": "application/json" }).end(
          JSON.stringify({ sessionId: chatId, remoteSessionId: body.sessionId, history: sliceThreadHistory(history, historyLimit) }),
        );
      } catch (err) {
        sessions.delete(chatId);
        log(`mcode load failed session=${chatId} message=${(err as Error).message.slice(0, 120)}`);
        res.writeHead(502, { "content-type": "application/json" }).end(
          JSON.stringify({ error: (err as Error).message.slice(0, 300) }),
        );
      }
      return;
    }

    if (req.method === "GET" && url.pathname === "/clutch/v1/session-meta") {
      const meta = loadSessionMeta(SESSION_META_FILE);
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ projects: meta.projects, sessions: meta.sessions }));
      return;
    }

    // Project assignment and archiving.  Both are reversible and durable:  the
    // engine is never asked to move or rename a thread, so unarchiving brings
    // back exactly the session that was hidden.
    if (req.method === "PUT" && url.pathname === "/clutch/v1/session-meta") {
      let body: unknown;
      try {
        body = await readJsonBody(req);
      } catch {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
        return;
      }
      const parsed = SessionMetaPatchSchema.safeParse(body);
      if (!parsed.success) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: parsed.error.issues[0]?.message ?? "invalid request body" }));
        return;
      }
      const meta = loadSessionMeta(SESSION_META_FILE);
      const patch: { projectId?: string | null; archived?: boolean } = {};
      if (parsed.data.projectId !== undefined) {
        if (parsed.data.projectId === null || parsed.data.projectId === "") {
          patch.projectId = null;
        } else {
          // Refuse a project that does not exist rather than storing a
          // dangling id the UI could never render.
          if (!meta.projects.some((p) => p.id === parsed.data.projectId)) {
            res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "unknown project" }));
            return;
          }
          patch.projectId = parsed.data.projectId;
        }
      }
      if (parsed.data.archived !== undefined) {
        patch.archived = parsed.data.archived;
      }
      const entry = upsertSession(meta, parsed.data.sessionId, patch);
      try {
        saveSessionMeta(SESSION_META_FILE, meta);
      } catch (err) {
        res.writeHead(500, { "content-type": "application/json" }).end(JSON.stringify({ error: (err as Error).message.slice(0, 200) }));
        return;
      }
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ entry, projects: meta.projects, sessions: meta.sessions }));
      return;
    }

    if (req.method === "POST" && url.pathname === "/clutch/v1/projects") {
      let body: unknown;
      try {
        body = await readJsonBody(req);
      } catch {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
        return;
      }
      const parsed = ProjectCreateSchema.safeParse(body);
      if (!parsed.success) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: parsed.error.issues[0]?.message ?? "invalid request body" }));
        return;
      }
      const name = normalizeProjectName(parsed.data.name);
      if (!name) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "project name is required" }));
        return;
      }
      const meta = loadSessionMeta(SESSION_META_FILE);
      const existing = meta.projects.find((p) => p.name.toLowerCase() === name.toLowerCase());
      if (existing) {
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ project: existing, created: false }));
        return;
      }
      const project = { id: newProjectId(), name, createdAt: new Date().toISOString() };
      meta.projects.push(project);
      try {
        saveSessionMeta(SESSION_META_FILE, meta);
      } catch (err) {
        res.writeHead(500, { "content-type": "application/json" }).end(JSON.stringify({ error: (err as Error).message.slice(0, 200) }));
        return;
      }
      res.writeHead(201, { "content-type": "application/json" }).end(JSON.stringify({ project, created: true }));
      return;
    }

    if (req.method === "DELETE" && url.pathname.startsWith("/clutch/v1/projects/")) {
      let projectId: string;
      try {
        projectId = decodeURIComponent(url.pathname.slice("/clutch/v1/projects/".length)).trim();
      } catch {
        // Malformed percent-encoding (e.g. "%zz") throws URIError; that is a
        // bad request, not a reason to crash the bridge.
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid project id encoding" }));
        return;
      }
      if (!projectId) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "project id is required" }));
        return;
      }
      const meta = loadSessionMeta(SESSION_META_FILE);
      if (!removeProject(meta, projectId)) {
        res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: "unknown project" }));
        return;
      }
      try {
        saveSessionMeta(SESSION_META_FILE, meta);
      } catch (err) {
        res.writeHead(500, { "content-type": "application/json" }).end(JSON.stringify({ error: (err as Error).message.slice(0, 200) }));
        return;
      }
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ ok: true, projects: meta.projects, sessions: meta.sessions }));
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

    if (req.method === "GET" && url.pathname === "/clutch/v1/thread") {
      // Agent side of one device thread for native clients that cannot use
      // the kit SDK (notably the Mac target). Same chat-token gate as
      // everything else here; the CometChat key never leaves the server.
      const parsed = parseThreadQuery(url.searchParams);
      if ("error" in parsed) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: parsed.error }));
        return;
      }
      if (!ccRelay) {
        res.writeHead(501, { "content-type": "application/json" }).end(JSON.stringify({ error: "chat relay not configured" }));
        return;
      }
      try {
        const messages = await ccRelay.fetchThread(parsed.uid, parsed.limit);
        log(`chat thread uidChars=${parsed.uid.length} messages=${messages.length}`);
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ messages }));
      } catch (err) {
        log(`chat thread failed message=${(err as Error).message.slice(0, 120)}`);
        res.writeHead(502, { "content-type": "application/json" }).end(
          JSON.stringify({ error: (err as Error).message.slice(0, 300) }),
        );
      }
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
      // A literal `null` body parses fine and would then throw on `body.prompt`
      // inside this async handler, an unhandled rejection that ends the bridge.
      if (typeof body !== "object" || body === null || Array.isArray(body)) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "JSON body must be an object" }));
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
        session = { engine, bridgeSessionId: "", resumeSessionId: null, cwd, busy: false, stream: null };
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
        if (u.kind !== "user_message_chunk") sink?.onUpdate(u.kind, r.text);
      };
      let settled = false;
      // The resumable remote id rides every terminal event so a fresh turn
      // can be reloaded later (mcode threads live in the sidecar map only
      // until the process exits).
      const remoteId = (): string | null => active.resumeSessionId ?? (active.bridgeSessionId || null);
      // Live usage.  The engine writes its accounting to the session log as the
      // turn runs, so we re-read it on a timer and push only real records.
      // Nothing here estimates:  if the log has no usage yet, no event fires.
      let usageTimer: ReturnType<typeof setInterval> | null = null;
      let lastUsage: SessionUsage | null = null;
      const stopUsage = (): void => {
        if (usageTimer) clearInterval(usageTimer);
        usageTimer = null;
      };
      const finish = (event: string, data: unknown): void => {
        if (settled) return;
        settled = true;
        stopUsage();
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
        finish("done", { stopReason: "cancelled", sessionId: chatId, remoteSessionId: remoteId() });
      });

      try {
        const bridge = bridgeFor(engine);
        await bridge.initialize();
        if (!active.bridgeSessionId) {
          if (engine === "mcode" && active.resumeSessionId) {
            await bridge.loadSession(active.resumeSessionId, active.cwd);
            active.bridgeSessionId = active.resumeSessionId;
          } else {
            active.bridgeSessionId = await bridge.newSession(cwd);
            if (engine === "mcode") active.resumeSessionId = active.bridgeSessionId;
          }
          log(`chat session=${chatId} bridgeSession=${active.bridgeSessionId} cwdChars=${cwd.length}`);
        }
        if (engine === "mcode" && active.bridgeSessionId) {
          const sessionIdForUsage = active.bridgeSessionId;
          usageTimer = setInterval(() => {
            const fresh = readSessionUsage(DSH_HOME, sessionIdForUsage);
            if (!fresh) return;
            // Only re-announce when the engine actually wrote something new.
            if (lastUsage && fresh.updatedAtMs === lastUsage.updatedAtMs) return;
            const measured = withRate(fresh, lastUsage ?? undefined);
            lastUsage = fresh;
            if (!settled) sseSend(res, "usage", { sessionId: sessionIdForUsage, usage: measured });
          }, 1500);
          usageTimer.unref?.();
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
        finish("done", { stopReason: result.stopReason ?? "endTurn", sessionId: chatId, remoteSessionId: remoteId() });
      } catch (err) {
        log(`chat error session=${chatId} message=${(err as Error).message.slice(0, 120)}`);
        // Only process loss invalidates the child-local session state.  ACP
        // application errors (rate limits, provider failures) leave the native
        // thread attached.  A direct mcode session is reloaded after a respawn.
        if (err instanceof BridgeProcessError) active.bridgeSessionId = "";
        if (sink) {
          try {
            await sink.onDone();
          } catch {
            /* relay failures must not change the error surfaced to the client */
          }
        }
        finish("error", { message: (err as Error).message.slice(0, 300), sessionId: chatId, remoteSessionId: remoteId() });
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
