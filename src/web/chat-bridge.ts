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
 * SSE events: `message` {text}, `thought` {text}, `tool`
 * {id, name, status}, `done` {stopReason, sessionId}.  Each turn runs a real coding session through
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

import { clutchChatPort } from "../shared/ports.ts";
import { initClutchSettings } from "../shared/clutchSettings.ts";
import { ENGINE_ORDER, isEngine, type Engine } from "../shared/engine-types.ts";
import { engineCatalog, resolveModelValue, type EngineCatalog } from "./engine-catalog.ts";
import { isTrustedHostHeader, tailnetDnsName, trustedAuthoritySet } from "./pair-link.ts";
import { handleQuotasRequest } from "./quotas-route.ts";
import { handleInfisicalSettingsRequest } from "./infisical-route.ts";
import { CometChatRelay, cleanEnvValue, cometchatConfigFromEnv, createStreamSink, isThreadUid, THREAD_MESSAGE_LIMIT_DEFAULT, THREAD_MESSAGE_LIMIT_MAX, type StreamSink } from "./cometchat-relay.ts";
import { miniMaxCodeRemoteHtml } from "./minimax-code-remote.ts";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const HOST = "127.0.0.1";
const PORT = Number(clutchChatPort());
const CLUTCH_HOME = process.env.CLUTCH_HOME ?? join(homedir(), ".clutch");
const TOKEN_FILE = process.env.CLUTCH_CHAT_TOKEN_FILE ?? join(CLUTCH_HOME, "chat-token");

interface Launcher {
  command: string;
  args: string[];
}

/**
 * Engines whose threads the native clients can list and resume.
 *
 * The dsh bridges (DeepSeek, MiniMax) keep no resumable session list of
 * their own, so discovery only makes sense for the code engines: MiniMax
 * Code and Muse Code, both of which speak ACP `session/list`.
 */
const CODE_ENGINES: Engine[] = ["mcode", "muse"];

const defaultMcode = [
  join(homedir(), ".local", "bin", "mcode"),
  join(homedir(), ".minimax-code", "bin", "mcode"),
].find(existsSync) ?? "mcode";
const mcodeLauncherOverride = process.env.CLUTCH_CHAT_LAUNCHER_MCODE?.trim();
const museLauncherOverride = process.env.CLUTCH_CHAT_LAUNCHER_MUSE?.trim();

const LAUNCHERS: Record<Engine, Launcher> = {
  // CLUTCH_CHAT_LAUNCHER_<ENGINE> overrides exist for the full-loop test,
  // which points the engines at a stub script. Production always uses the
  // shipped launchers below.
  deepseek: { command: process.env.CLUTCH_CHAT_LAUNCHER_DEEPSEEK?.trim() || join(ROOT, "scripts", "dsh-acp.sh"), args: [] },
  minimax: { command: process.env.CLUTCH_CHAT_LAUNCHER_MINIMAX?.trim() || join(ROOT, "scripts", "minimax-acp.sh"), args: [] },
  mcode: mcodeLauncherOverride
    ? { command: mcodeLauncherOverride, args: [] }
    : { command: process.env.CLUTCH_MCODE_CLI?.trim() || defaultMcode, args: ["acp"] },
  // Muse Code is not an ACP agent: `muse serve` speaks MSP and the community
  // adapter translates it to ACP on stdio.  The shipped launcher execs the
  // adapter directly, so there is no Python bridge for this engine.
  muse: museLauncherOverride
    ? { command: museLauncherOverride, args: [] }
    : { command: join(ROOT, "scripts", "muse-code-acp.sh"), args: [] },
};

/** Engines a phone or Mac can pick, in the order the picker shows them. */
export { ENGINE_ORDER, ENGINE_LABELS, isEngine, type Engine } from "../shared/engine-types.ts";

function log(line: string): void {
  process.stderr.write(`chat-bridge: ${line}\n`);
}

/** Route a model id to its engine. Unknown prefixes default to DeepSeek. */
export function routeForModel(model: string | undefined, engine: string | undefined): Engine {
  if (isEngine(engine)) return engine;
  // No engine named: the model id says which one it belongs to.
  const fromModel = engineForModelId(model);
  if (fromModel) return fromModel;
  return "deepseek";
}

/**
 * The engine a model id belongs to, when the model names its own engine.
 * `muse-wonder` and `muse-spark-1.3` are Muse models; `mcode-*` are
 * MiniMax Code's; everything else stays on the DeepSeek sidecar.
 */
export function engineForModelId(model: string | undefined): Engine | null {
  if (typeof model !== "string") return null;
  const id = model.trim().toLowerCase();
  if (!id) return null;
  if (id.startsWith("muse")) return "muse";
  if (id.startsWith("mcode")) return "mcode";
  if (id.startsWith("minimax")) return "minimax";
  if (id.startsWith("deepseek")) return "deepseek";
  return null;
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

/**
 * Whether Muse Code can run here.
 *
 * Two pieces are needed: the `muse` host binary, and the community ACP
 * adapter that translates Muse's MSP to ACP.  The adapter is usually a
 * global npm install, so its bin lands in the npm global prefix — on a
 * server that is `/usr/local/bin`, on a Mac it is under the Homebrew
 * prefix — and the launcher script searches the same places.
 */
export function museInstalled(
  env: Record<string, string | undefined> = process.env,
  candidates: { hosts?: string[]; adapters?: string[] } = {},
): boolean {
  // An explicit override only counts when the path is really there: a stale
  // variable must not make the catalog claim Muse Code is installed.
  const hostPaths = candidates.hosts ?? [
    "/usr/local/bin/muse",
    "/opt/homebrew/bin/muse",
    join(homedir(), ".local", "bin", "muse"),
  ];
  const adapterPaths = candidates.adapters ?? [
    "/usr/local/bin/muse-code-acp",
    "/opt/homebrew/bin/muse-code-acp",
    join(homedir(), ".local", "bin", "muse-code-acp"),
  ];
  const override = env.MUSE_CODE_EXECUTABLE?.trim();
  const host = (override && existsSync(override) ? override : undefined)
    || hostPaths.find(existsSync);
  if (!host) return false;
  const adapterOverride = env.MUSE_CODE_ACP_BIN?.trim();
  const adapter = (adapterOverride && existsSync(adapterOverride) ? adapterOverride : undefined)
    || adapterPaths.find(existsSync);
  return Boolean(adapter);
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
  kind: "agent_message_chunk" | "agent_thought_chunk" | "user_message_chunk" | "tool_call" | "tool_call_update";
  text: string;
  toolCallId?: string;
  toolStatus?: "running" | "completed" | "failed";
}

/** ACP tool-call status as the clients render it. */
export function toolStatusOf(raw: unknown): "running" | "completed" | "failed" {
  switch (raw) {
    case "completed": return "completed";
    case "failed": return "failed";
    default: return "running"; // pending, in_progress, missing — still in flight
  }
}

function toolContentText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    if (!block || typeof block !== "object") continue;
    const row = block as { type?: unknown; content?: { type?: unknown; text?: unknown }; path?: unknown };
    if (row.type === "content" && row.content?.type === "text" && typeof row.content.text === "string") {
      parts.push(row.content.text);
    } else if (row.type === "diff" && typeof row.path === "string") {
      parts.push(`Edited ${row.path}`);
    }
  }
  return parts.join("\n").slice(0, 2000);
}

/**
 * One ACP `session/update` as an `AcpUpdate`, or null for updates the
 * clients do not render (plan entries, mode changes, …).  Tool calls used
 * to be dropped here, so a remote thread showed prose with the actual work
 * invisible; they now ride through with their title and status, both live
 * (SSE `tool` events) and in replayed history.
 */
export function normalizeSessionUpdate(params: unknown): AcpUpdate | null {
  if (!params || typeof params !== "object") return null;
  const row = params as { sessionId?: unknown; update?: Record<string, unknown> };
  if (typeof row.sessionId !== "string" || !row.update || typeof row.update !== "object") return null;
  const update = row.update;
  const kind = update.sessionUpdate;
  if (kind === "agent_message_chunk" || kind === "agent_thought_chunk" || kind === "user_message_chunk") {
    const content = update.content as { text?: unknown } | undefined;
    if (typeof content?.text !== "string") return null;
    return { sessionId: row.sessionId, kind, text: content.text };
  }
  if (kind === "tool_call" || kind === "tool_call_update") {
    const titled = typeof update.title === "string" && update.title.length > 0 ? update.title : "";
    // An update often carries no title at all — just a new status.  Empty
    // text tells the client to keep the name it already shows for this
    // call instead of replacing it with a generic label.
    const text = titled || (kind === "tool_call" ? toolContentText(update.content) || (typeof update.kind === "string" ? update.kind : "Tool call") : toolContentText(update.content));
    return {
      sessionId: row.sessionId,
      kind,
      text: text.slice(0, 500),
      ...(typeof update.toolCallId === "string" ? { toolCallId: update.toolCallId } : {}),
      toolStatus: toolStatusOf(update.status),
    };
  }
  return null;
}

/**
 * Collapse a replayed history's tool updates into one entry per call: the
 * first `tool_call` keeps its name, later updates only move its status.
 * Without this a single file write replays as a stack of identical cards.
 */
export function compactToolHistory(history: readonly AcpUpdate[]): AcpUpdate[] {
  const out: AcpUpdate[] = [];
  const byId = new Map<string, number>();
  for (const entry of history) {
    if (entry.kind === "tool_call" || entry.kind === "tool_call_update") {
      const id = entry.toolCallId ?? "";
      const existing = id ? byId.get(id) : undefined;
      const kept = existing !== undefined ? out[existing] : undefined;
      if (existing !== undefined && kept) {
        out[existing] = {
          ...kept,
          text: kept.text || entry.text,
          toolStatus: entry.toolStatus ?? kept.toolStatus ?? "running",
        };
        continue;
      }
      if (id) byId.set(id, out.length);
      out.push(entry);
      continue;
    }
    out.push(entry);
  }
  return out;
}

interface AcpSessionInfo {
  sessionId: string;
  cwd?: string;
  title?: string;
  updatedAt?: string;
}

class BridgeProcessError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BridgeProcessError";
  }
}

/**
 * One image attached to a turn.
 *
 * ACP carries images as content blocks with base64 data, which is what both
 * code engines accept (`promptCapabilities.image` is true on MiniMax Code and
 * Muse Code).  The dsh bridges take a plain string, so an attachment there
 * rides as a path the agent opens with its own read tool.
 */
export interface PromptImage {
  mimeType: string;
  data: string;
  name?: string;
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
        const update = normalizeSessionUpdate(msg.params);
        if (update) this.onUpdate?.(update);
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

  /**
   * Switch the session's model or reasoning effort.
   *
   * ACP carries both as config options: `model` for the model choice, and a
   * per-engine effort option (`reasoning_effort` on dsh, `thinkingEffort` on
   * MiniMax Code, `reasoningEffort` on Muse Code).  An engine that does not
   * offer the option answers with an error, which is not fatal for the turn:
   * the caller keeps the session as it was and reports the refusal.
   */
  async setConfigOption(sessionId: string, configId: string, value: string): Promise<boolean> {
    try {
      await this.send("session/set_config_option", { sessionId, configId, value });
      return true;
    } catch {
      return false;
    }
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

  prompt(sessionId: string, text: string, images: PromptImage[] = []): Promise<{ stopReason: string }> {
    // ACP agents take content blocks; the dsh bridges take a plain string.
    // Muse Code rejects a bare string ("Invalid params"), so the code
    // engines get the block form every time.
    let prompt: unknown = text;
    if (this.engine === "mcode" || this.engine === "muse") {
      const blocks: unknown[] = [{ type: "text", text }];
      for (const image of images) {
        blocks.push({ type: "image", mimeType: image.mimeType, data: image.data });
      }
      prompt = blocks;
    } else if (images.length > 0) {
      // The dsh bridges have no image block: name the files instead, and
      // let the agent open them with its own read tool.
      const names = images.map((image) => image.name).filter(Boolean);
      if (names.length > 0) {
        prompt = `${text}\n\n${names.map((name) => `<attached-image path="${name}" />`).join("\n")}`;
      }
    }
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
  /** The model this session runs, as the client asked for it. */
  model?: string;
  /** The reasoning effort this session runs, as the client asked for it. */
  effort?: string;
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

/** The image MIME types the code engines accept. */
const IMAGE_MIME_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

/** One image per turn, and the bytes it carries. */
const MAX_IMAGE_BYTES = 6 * 1024 * 1024;

/**
 * The images attached to a turn.
 *
 * The client posts base64 data (an attachment is never a file path: the
 * phone has no shared filesystem with the server).  The size and the MIME
 * type are checked here so a bad attachment is refused before a model turn
 * is billed for it.
 */
export function parsePromptImages(raw: unknown): Array<{ mimeType: string; data: string; name?: string }> {
  if (!Array.isArray(raw)) return [];
  const images: Array<{ mimeType: string; data: string; name?: string }> = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const row = item as { mimeType?: unknown; data?: unknown; name?: unknown };
    const mimeType = typeof row.mimeType === "string" ? row.mimeType.trim().toLowerCase() : "";
    if (!IMAGE_MIME_TYPES.has(mimeType)) continue;
    const data = typeof row.data === "string" ? row.data.trim() : "";
    if (!data) continue;
    // The client sends raw base64; the byte count is what the engine caps.
    const bytes = Math.floor((data.length * 3) / 4);
    if (bytes > MAX_IMAGE_BYTES) continue;
    images.push({
      mimeType,
      data,
      ...(typeof row.name === "string" && row.name.length > 0 ? { name: row.name } : {}),
    });
  }
  return images;
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

  /**
   * Whether an engine's launcher and host binary are present here, so the
   * catalog can say "not installed" instead of failing on the first turn.
   */
  function engineAvailable(engine: Engine): boolean {
    const launcher = LAUNCHERS[engine];
    if (launcher.command.includes("/") && !existsSync(launcher.command)) return false;
    if (engine === "muse") return museInstalled();
    return true;
  }

  /** The catalog for this host, with the real launchers wired in. */
  async function catalog(): Promise<EngineCatalog> {
    return engineCatalog({
      launchers: LAUNCHERS,
      available: Object.fromEntries(ENGINE_ORDER.map((engine) => [engine, engineAvailable(engine)])) as Record<Engine, boolean>,
      probeCwd: process.env.HOME ?? "/tmp",
    });
  }

  /**
   * Apply the client's model and effort choices to a session.
   *
   * Both are ACP config options, and every engine spells them differently,
   * so the catalog is what maps a requested model to the wire value.  A
   * refusal is reported but never fatal: the turn still runs with the
   * engine's own default, which is better than refusing to answer.
   */
  async function applySessionChoices(
    bridge: Bridge,
    session: ChatSession,
    catalogValue: EngineCatalog,
  ): Promise<{ modelApplied: boolean; effortApplied: boolean }> {
    let modelApplied = false;
    let effortApplied = false;
    if (!session.bridgeSessionId) return { modelApplied, effortApplied };
    const descriptor = catalogValue.engines.find((entry) => entry.id === session.engine);
    if (session.model) {
      const value = resolveModelValue(catalogValue, session.engine, session.model);
      if (value) {
        modelApplied = await bridge.setConfigOption(session.bridgeSessionId, descriptor?.modelConfigId ?? "model", value);
        if (!modelApplied) log(`model refused session=${session.bridgeSessionId} engine=${session.engine}`);
      }
    }
    if (session.effort) {
      effortApplied = await bridge.setConfigOption(
        session.bridgeSessionId,
        descriptor?.effortConfigId ?? "reasoning_effort",
        session.effort,
      );
      if (!effortApplied) log(`effort refused session=${session.bridgeSessionId} engine=${session.engine}`);
    }
    return { modelApplied, effortApplied };
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
          engines: ENGINE_ORDER,
          mcode: { available: mcodeAvailable() },
          tailnetHost,
        }),
      );
      return;
    }

    // The engine catalog: which engines this host runs, which models each
    // offers right now, and which effort levels it accepts.  The native
    // model picker reads this instead of shipping a list that goes stale.
    if (req.method === "GET" && url.pathname === "/clutch/v1/engines") {
      try {
        const value = await catalog();
        res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify(value));
      } catch (err) {
        log(`engine catalog failed message=${(err as Error).message.slice(0, 120)}`);
        res.writeHead(502, { "content-type": "application/json" }).end(
          JSON.stringify({ error: (err as Error).message.slice(0, 300) }),
        );
      }
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
      const requestedEngine = url.searchParams.get("engine");
      if (!isEngine(requestedEngine) || !CODE_ENGINES.includes(requestedEngine)) {
        res.writeHead(400, { "content-type": "application/json" }).end(
          JSON.stringify({ error: `session discovery requires engine to be one of ${CODE_ENGINES.join(", ")}` }),
        );
        return;
      }
      const listEngine = requestedEngine;
      try {
        const bridge = bridgeFor(listEngine);
        await bridge.initialize();
        const requestedCwd = url.searchParams.get("cwd")?.trim() || undefined;
        const limit = parseLimitParam(url.searchParams.get("limit"), 50, 200);
        const listed = sortSessionsByUpdated(await bridge.listSessions(requestedCwd, limit));
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ sessions: listed }));
      } catch (err) {
        log(`${listEngine} list failed message=${(err as Error).message.slice(0, 120)}`);
        res.writeHead(502, { "content-type": "application/json" }).end(
          JSON.stringify({ error: (err as Error).message.slice(0, 300) }),
        );
      }
      return;
    }

    if (req.method === "POST" && url.pathname === "/clutch/v1/sessions/load") {
      let body: { engine?: unknown; sessionId?: unknown; cwd?: unknown; limit?: unknown; model?: unknown; effort?: unknown };
      try {
        body = (await readJsonBody(req)) as typeof body;
      } catch {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
        return;
      }
      if (!isEngine(body.engine) || !CODE_ENGINES.includes(body.engine) || typeof body.sessionId !== "string" || body.sessionId.length === 0) {
        res.writeHead(400, { "content-type": "application/json" }).end(
          JSON.stringify({ error: `engine must be one of ${CODE_ENGINES.join(", ")} and sessionId is required` }),
        );
        return;
      }
      const loadEngine = body.engine;
      const cwd = typeof body.cwd === "string" && body.cwd.length > 0 ? body.cwd : process.env.HOME ?? "/tmp";
      const historyLimit =
        typeof body.limit === "number" || typeof body.limit === "string"
          ? parseLimitParam(String(body.limit), 200, 1000)
          : 200;
      const chatId = randomBytes(16).toString("hex");
      const history: AcpUpdate[] = [];
      const session: ChatSession = {
        engine: loadEngine,
        bridgeSessionId: body.sessionId,
        resumeSessionId: body.sessionId,
        cwd,
        busy: true,
        stream: (update) => {
          if (history.length < 20_000) history.push(update);
        },
        ...(typeof body.model === "string" && body.model.length > 0 ? { model: body.model } : {}),
        ...(typeof body.effort === "string" && body.effort.length > 0 ? { effort: body.effort } : {}),
      };
      sessions.set(chatId, session);
      try {
        const bridge = bridgeFor(loadEngine);
        await bridge.initialize();
        await bridge.loadSession(body.sessionId, cwd);
        // A resumed thread keeps the model it was created with unless the
        // client asks for another one, so the choices land after the load.
        if (session.model || session.effort) {
          await applySessionChoices(bridge, session, await catalog());
        }
        session.busy = false;
        session.stream = null;
        res.writeHead(200, { "content-type": "application/json" }).end(
          JSON.stringify({ sessionId: chatId, remoteSessionId: body.sessionId, history: sliceThreadHistory(compactToolHistory(history), historyLimit) }),
        );
      } catch (err) {
        sessions.delete(chatId);
        log(`${loadEngine} load failed session=${chatId} message=${(err as Error).message.slice(0, 120)}`);
        res.writeHead(502, { "content-type": "application/json" }).end(
          JSON.stringify({ error: (err as Error).message.slice(0, 300) }),
        );
      }
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
        effort?: unknown;
        engine?: unknown;
        sessionId?: unknown;
        cwd?: unknown;
        relay?: unknown;
        images?: unknown;
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
      // The model the client picked and the effort it wants.  Both are
      // optional: without them the engine keeps its own defaults.
      const requestedModel = typeof body.model === "string" && body.model.trim().length > 0 ? body.model.trim() : undefined;
      const requestedEffort = typeof body.effort === "string" && body.effort.trim().length > 0 ? body.effort.trim() : undefined;
      // Images attached to the turn, the way the web canvas attaches files.
      const images = parsePromptImages(body.images);

      let chatId = typeof body.sessionId === "string" && body.sessionId.length > 0 ? body.sessionId : null;
      let session = chatId ? sessions.get(chatId) : undefined;
      if (!session || session.engine !== engine) {
        chatId = randomBytes(16).toString("hex");
        session = { engine, bridgeSessionId: "", resumeSessionId: null, cwd, busy: false, stream: null };
        sessions.set(chatId, session);
      }
      if (requestedModel) session.model = requestedModel;
      if (requestedEffort) session.effort = requestedEffort;
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
        if (u.kind === "tool_call" || u.kind === "tool_call_update") {
          sseSend(res, "tool", { id: u.toolCallId ?? "", name: u.text, status: u.toolStatus ?? "running" });
          return;
        }
        const r = route(u);
        sseSend(res, r.event, { text: r.text });
        if (u.kind !== "user_message_chunk") sink?.onUpdate(u.kind, r.text);
      };
      let settled = false;
      // The resumable remote id rides every terminal event so a fresh turn
      // can be reloaded later (mcode threads live in the sidecar map only
      // until the process exits).
      const remoteId = (): string | null => active.resumeSessionId ?? (active.bridgeSessionId || null);
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
        finish("done", { stopReason: "cancelled", sessionId: chatId, remoteSessionId: remoteId() });
      });

      try {
        const bridge = bridgeFor(engine);
        await bridge.initialize();
        if (!active.bridgeSessionId) {
          if (CODE_ENGINES.includes(engine) && active.resumeSessionId) {
            await bridge.loadSession(active.resumeSessionId, active.cwd);
            active.bridgeSessionId = active.resumeSessionId;
          } else {
            active.bridgeSessionId = await bridge.newSession(cwd);
            if (CODE_ENGINES.includes(engine)) active.resumeSessionId = active.bridgeSessionId;
          }
          log(`chat session=${chatId} bridgeSession=${active.bridgeSessionId} cwdChars=${cwd.length}`);
        }
        // The model's and the effort's choices land before the turn, so the
        // first prompt of a new session already runs on the picked model.
        if (active.model || active.effort) {
          const applied = await applySessionChoices(bridge, active, await catalog());
          log(`chat choices session=${chatId} model=${applied.modelApplied} effort=${applied.effortApplied}`);
        }
        const result = await bridge.prompt(active.bridgeSessionId, prompt, images);
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
