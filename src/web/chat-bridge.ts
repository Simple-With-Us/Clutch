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
 *   GET  /clutch/v1/sessions?engine=<engine> → that engine's threads
 *   POST /clutch/v1/sessions/load          → replay one thread of any engine
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
import { mkdir, mkdtemp, readdir, rm, stat, utimes, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { z } from "zod";

import { clutchChatPort } from "../shared/ports.ts";
import { initClutchSettings } from "../shared/clutchSettings.ts";
import { ENGINE_ORDER, isDshHostedEngine, isEngine, type Engine } from "../shared/engine-types.ts";
import { engineCatalog, resolveModelAltValue, resolveModelValue, type EngineCatalog } from "./engine-catalog.ts";
import { isTrustedHostHeader, tailnetDnsName, trustedAuthoritySet } from "./pair-link.ts";
import { readTailnetStatus } from "./tailnet-status.ts";
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
import { DshHostClient } from "./dshHostClient.ts";
import { listDshHostSessions, loadDshHostHistory, type SessionSummary } from "./dshHostSessions.ts";
import { compactToolHistory, toolStatusOf, type SessionUpdate } from "./sessionUpdates.ts";

// Re-exported for the clients and the tests that already import them from
// here; the implementations now live in the shared module.
export { compactToolHistory, toolStatusOf };

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const HOST = "127.0.0.1";
const PORT = Number(clutchChatPort());
const CLUTCH_HOME = process.env.CLUTCH_HOME ?? join(homedir(), ".clutch");
const TOKEN_FILE = process.env.CLUTCH_CHAT_TOKEN_FILE ?? join(CLUTCH_HOME, "chat-token");
/** Where the engine keeps its session logs — the only place real usage lives. */
const DSH_HOME = process.env.CLUTCH_DSH_HOME ?? join(CLUTCH_HOME, "dsh");
const SESSION_META_FILE = process.env.CLUTCH_SESSION_META_FILE ?? sessionMetaPath(CLUTCH_HOME);

interface Launcher {
  command: string;
  args: string[];
}

/**
 * The engines whose threads their own ACP bridge keeps and resumes.
 *
 * The dsh-hosted engines (DeepSeek, MiniMax) are not here: the dsh host owns
 * their session log, and the sidecar reads it through the host while the
 * bridge only carries the turns.
 */
const CODE_ENGINES: Engine[] = ["mcode", "muse"];

/**
 * How long a failed connection to the dsh host is remembered.
 *
 * The host is a separate process from the sidecar, so it may start after the
 * sidecar or restart under it; the failure is remembered only long enough to
 * avoid hammering a host that is not there.
 */
const HOST_RETRY_COOLDOWN_MS = 30_000;

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

/** Whether a bare command name resolves on PATH. */
function commandOnPath(command: string): boolean {
  const path = process.env.PATH ?? "";
  for (const dir of path.split(":")) {
    if (!dir) continue;
    if (existsSync(join(dir, command))) return true;
  }
  return false;
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

/**
 * The bounded `tailscale status` reader lives in ./tailnet-status.ts so this
 * bridge and the web launcher share one implementation.  Detection runs before
 * the sidecar listens, so a CLI left waiting on a wedged tailscaled must not
 * keep the bridge from ever starting.
 */
export { readTailnetStatus };

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
  // The launcher's own search list wins, so a host that keeps the adapter
  // outside the global npm prefix (the fleet runtime does) still reads as
  // installed.
  const adapterPaths = candidates.adapters ?? [
    ...(env.MUSE_CODE_ACP_SEARCH_PATHS ?? "")
      .split(":")
      .filter((dir) => dir.length > 0)
      .map((dir) => join(dir, "muse-code-acp")),
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

/** One replayed transcript entry; the shape both engine backends speak. */
type AcpUpdate = SessionUpdate;

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

/** Where attachments are materialized for the engines that take a path. */
export function attachmentRoot(): string {
  return join(CLUTCH_HOME, "attachments");
}

/**
 * The file name an attachment is written under.
 *
 * The name comes from the client, so it is never trusted: only the last
 * path segment survives, and a name that is empty after that falls back to
 * a generated one.  Without this, a name like `../../.ssh/authorized_keys`
 * would write outside the attachment directory.
 */
export function safeAttachmentName(raw: string | undefined, index: number): string {
  const base = basename(raw ?? "").trim();
  const cleaned = base.replace(/[^A-Za-z0-9._-]/g, "_").replace(/^\.+/, "");
  if (!cleaned || cleaned === "." || cleaned === "..") return `attachment-${index + 1}`;
  return cleaned.slice(0, 120);
}

/**
 * Write an attachment to disk for the engines that take a path.
 *
 * The bytes land in a per-session directory under the attachment root, never
 * in the user's working directory: an attachment is not a project file, and
 * writing it there would dirty the working tree and accumulate forever.
 * The resolved path is checked against the root before the write, so a
 * crafted name cannot escape.
 */
let attachmentWork: Promise<void> = Promise.resolve();

/** Serialize scan/delete and image writes so pruning cannot invalidate a returned path. */
async function withAttachmentWork<T>(work: () => Promise<T>): Promise<T> {
  const previous = attachmentWork;
  let release!: () => void;
  attachmentWork = new Promise<void>((resolve) => { release = resolve; });
  await previous;
  try {
    return await work();
  } finally {
    release();
  }
}

export async function materializeAttachment(options: {
  root: string;
  sessionId: string;
  image: PromptImage;
  index: number;
}): Promise<string | null> {
  return withAttachmentWork(() => materializeAttachmentUnlocked(options));
}

async function materializeAttachmentUnlocked(options: {
  root: string;
  sessionId: string;
  image: PromptImage;
  index: number;
}): Promise<string | null> {
  const sessionDir = join(options.root, options.sessionId);
  const candidate = resolve(sessionDir, safeAttachmentName(options.image.name, options.index));
  const root = resolve(options.root);
  // The resolved file must sit under the resolved root: the name is
  // sanitized already, and this is the second line of defence.
  if (candidate !== root && !candidate.startsWith(root + sep)) {
    log(`attachment refused: the name escaped the attachment directory`);
    return null;
  }
  let imageDir: string | undefined;
  try {
    await mkdir(sessionDir, { recursive: true, mode: 0o700 });
    // Each image gets a directory created exclusively by mkdtemp. Names can
    // repeat within a turn or across turns without changing an earlier path.
    imageDir = await mkdtemp(join(sessionDir, "image-"));
    const file = join(imageDir, safeAttachmentName(options.image.name, options.index));
    await writeFile(file, Buffer.from(options.image.data, "base64"), { flag: "wx", mode: 0o600 });
    // Writing a file does not move the directory's own timestamp, so an
    // active session's directory would look old to the prune.  Touch it —
    // best-effort only: the image is already written, and a failed touch
    // must not discard it.
    try {
      const now = new Date();
      await utimes(sessionDir, now, now);
    } catch {
      /* the prune also reads the files inside, so this is a courtesy */
    }
    return file;
  } catch {
    if (imageDir) await rm(imageDir, { recursive: true, force: true }).catch(() => undefined);
    log("attachment write failed");
    return null;
  }
}

/** Prepare every image before a turn can be sent. Never silently drop one. */
export async function prepareAttachedPrompt(root: string, sessionId: string, text: string, images: PromptImage[]): Promise<string> {
  return withAttachmentWork(() => prepareAttachedPromptUnlocked(root, sessionId, text, images));
}

async function prepareAttachedPromptUnlocked(root: string, sessionId: string, text: string, images: PromptImage[]): Promise<string> {
  // Old attachment directories are pruned while a new batch is written: the
  // sidecar has no background loop to hang this on, and a write is the moment
  // a stale directory can be noticed.
  await pruneAttachmentsUnlocked(root, 24 * 60 * 60 * 1000, sessionId);
  const written: string[] = [];
  try {
    for (const [index, image] of images.entries()) {
      const file = await materializeAttachmentUnlocked({ root, sessionId, image, index });
      if (!file) throw new Error("An attachment could not be saved. The turn was not sent. Please try again.");
      written.push(file);
    }
    return `${text}\n\n${written.map((file) => `<attached-image path="${file}" />`).join("\n")}`;
  } catch (error) {
    // These directories were created exclusively for this preparation. A
    // partial batch is never sent, so only its own unused files are removed.
    await Promise.all(written.map((file) => rm(dirname(file), { recursive: true, force: true }).catch(() => undefined)));
    throw error;
  }
}

/**
 * Remove attachment directories older than a day, so a long-lived sidecar
 * does not keep every image it ever received.
 *
 * Called when an attachment is written, not on a timer: the sidecar has no
 * background loop to hang this on, and a write is the moment a stale
 * directory can be noticed.
 */
export async function pruneAttachments(
  root: string,
  maxAgeMs = 24 * 60 * 60 * 1000,
  keepSessionId?: string,
): Promise<void> {
  return withAttachmentWork(() => pruneAttachmentsUnlocked(root, maxAgeMs, keepSessionId));
}

async function pruneAttachmentsUnlocked(root: string, maxAgeMs: number, keepSessionId?: string): Promise<void> {
  let entries: string[];
  try {
    entries = await readdir(root);
  } catch {
    return;
  }
  const now = Date.now();
  for (const entry of entries) {
    // Never prune the session being written right now: its directory can
    // look old between the mkdir and the write.
    if (keepSessionId && entry === keepSessionId) continue;
    const dir = join(root, entry);
    try {
      const info = await stat(dir);
      if (!info.isDirectory()) continue;
      // The newest file inside counts too: a session that keeps receiving
      // attachments must not be pruned because its directory timestamp
      // did not move.
      const newest = await newestFileTime(dir, info.mtimeMs);
      if (now - newest < maxAgeMs) continue;
      await rm(dir, { recursive: true, force: true });
    } catch {
      /* a directory we cannot prune is not worth failing a turn over */
    }
  }
}

/** The newest modification time inside a directory, or the directory's own. */
async function newestFileTime(dir: string, fallback: number): Promise<number> {
  let newest = fallback;
  let entries: string[];
  try {
    entries = await readdir(dir);
  } catch {
    return fallback;
  }
  for (const entry of entries) {
    try {
      const info = await stat(join(dir, entry));
      if (info.mtimeMs > newest) newest = info.mtimeMs;
    } catch {
      /* a file that vanished mid-scan is not worth failing over */
    }
  }
  return newest;
}

/** Minimal JSON-RPC client over a bridge launcher's stdio. */
export class Bridge {
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

  /**
   * Send one turn.
   *
   * `cwd` is the session's working directory, passed per call: the bridge
   * is shared by every session of an engine, so it cannot hold a directory
   * of its own.
   */
  async prompt(
    sessionId: string,
    text: string,
    images: PromptImage[] = [],
    cwd: string = process.env.HOME ?? "/tmp",
  ): Promise<{ stopReason: string }> {
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
      // The dsh bridges have no image block.  Their contract is an image
      // materialized to a file, with the path appended to the text, so the
      // agent opens the file with its own read tool.  Naming a file that
      // does not exist would lose the attachment entirely.
      prompt = await prepareAttachedPrompt(attachmentRoot(), sessionId, text, images);
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

/**
 * The session-load request.
 *
 * Every engine is loadable, so the engine is one of the four Clutch runs
 * rather than the code engines only.
 */
const SessionLoadSchema = z
  .object({
    engine: z.enum(ENGINE_ORDER as unknown as [Engine, ...Engine[]], {
      error: `engine must be one of ${ENGINE_ORDER.join(", ")}`,
    }),
    sessionId: z.string({ error: "sessionId is required" }).min(1, "sessionId is required"),
    cwd: z.string().optional(),
    limit: z.union([z.number(), z.string()]).optional(),
    model: z.string().optional(),
    effort: z.string().optional(),
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
    // The array and its elements are boundary data: each one is checked
    // before any field is read.
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const row = item as Record<string, unknown>;
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
   * The dsh host client, created on first use.
   *
   * The host is only needed for the engines it owns, so a machine that runs
   * only the code engines never opens a connection to it.
   */
  let hostClient: DshHostClient | null = null;
  let hostClientFailedAt = 0;
  async function dshHost(): Promise<DshHostClient> {
    if (hostClient) return hostClient;
    // A failed connect is remembered only briefly: the host is a separate
    // process, so it may start later or be restarted, and the sidecar must
    // not be stuck with the first failure for the life of the process.
    if (hostClientFailedAt && Date.now() - hostClientFailedAt < HOST_RETRY_COOLDOWN_MS) {
      throw new Error("the dsh host is not reachable");
    }
    try {
      hostClient = await DshHostClient.connect();
      hostClientFailedAt = 0;
      return hostClient;
    } catch (err) {
      hostClientFailedAt = Date.now();
      throw err;
    }
  }

  /**
   * The threads one engine owns, newest first.
   *
   * The dsh-hosted engines are read from the host, which owns their session
   * log; the code engines are read from their own ACP bridge.
   */
  async function listSessionsFor(
    engine: Engine,
    cwd: string | undefined,
    limit: number,
  ): Promise<SessionSummary[]> {
    if (isDshHostedEngine(engine)) {
      const listed = await listDshHostSessions(await dshHost(), {
        engine,
        limit,
        ...(cwd ? { cwd } : {}),
      });
      return sortSessionsByUpdated(listed);
    }
    const bridge = bridgeFor(engine);
    await bridge.initialize();
    return sortSessionsByUpdated(await bridge.listSessions(cwd, limit));
  }

  /**
   * Whether an engine's launcher and host binary are present here, so the
   * catalog can say "not installed" instead of failing on the first turn.
   */
  function engineAvailable(engine: Engine): boolean {
    const launcher = LAUNCHERS[engine];
    // A launcher with a path is checked against the filesystem; a bare
    // command name is checked against PATH, so a server without MiniMax
    // Code does not claim to have it.
    if (launcher.command.includes("/")) {
      if (!existsSync(launcher.command)) return false;
    } else if (!commandOnPath(launcher.command)) {
      return false;
    }
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
        if (!modelApplied) {
          // The engine may spell the same model another way (Muse Code:
          // bare id versus provider-qualified tuple).  Give the second form
          // its turn before giving up on the choice.
          const alt = resolveModelAltValue(catalogValue, session.engine, session.model);
          if (alt) {
            modelApplied = await bridge.setConfigOption(session.bridgeSessionId, descriptor?.modelConfigId ?? "model", alt);
          }
        }
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
      // A literal `null` body parses fine and would then throw on
      // `body.sessionId` inside this async handler, which ends the bridge.
      if (typeof body !== "object" || body === null || Array.isArray(body)) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "JSON body must be an object" }));
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
      if (!isEngine(requestedEngine)) {
        res.writeHead(400, { "content-type": "application/json" }).end(
          JSON.stringify({ error: `session discovery requires engine to be one of ${ENGINE_ORDER.join(", ")}` }),
        );
        return;
      }
      const listEngine = requestedEngine;
      const requestedCwd = url.searchParams.get("cwd")?.trim() || undefined;
      const limit = parseLimitParam(url.searchParams.get("limit"), 50, 200);
      try {
        const includeArchived = url.searchParams.get("archived") === "include";
        // Archived threads are dropped after listing, so over-fetch candidates
        // (capped well past the page size) to keep `limit` visible rows when
        // possible, then trim back to the requested page size after filtering.
        const fetchLimit = includeArchived ? limit : Math.max(limit, 500);
        const listed = await listSessionsFor(listEngine, requestedCwd, fetchLimit);
        const page = applySessionMeta(listed, loadSessionMeta(SESSION_META_FILE), includeArchived).slice(0, limit);
        // Reading usage means a synchronous zstd log read per session, so cap
        // how many rows get enriched in one request; rows past the cap simply
        // report no usage (the UI already renders "not reported").
        const sessions = attachUsage(page.slice(0, USAGE_ENRICH_CAP)).concat(page.slice(USAGE_ENRICH_CAP));
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ sessions }));
      } catch (err) {
        log(`${listEngine} list failed message=${(err as Error).message.slice(0, 120)}`);
        res.writeHead(502, { "content-type": "application/json" }).end(
          JSON.stringify({ error: (err as Error).message.slice(0, 300) }),
        );
      }
      return;
    }

    if (req.method === "POST" && url.pathname === "/clutch/v1/sessions/load") {
      let raw: unknown;
      try {
        raw = await readJsonBody(req);
      } catch {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
        return;
      }
      const parsedLoad = SessionLoadSchema.safeParse(raw);
      if (!parsedLoad.success) {
        res.writeHead(400, { "content-type": "application/json" }).end(
          JSON.stringify({ error: parsedLoad.error.issues[0]?.message ?? "invalid request body" }),
        );
        return;
      }
      const body = parsedLoad.data;
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
        // Every engine registers the thread's working directory with its
        // bridge here, so the next turn runs where the thread was started.
        await bridge.loadSession(body.sessionId, cwd);
        if (isDshHostedEngine(loadEngine)) {
          // The host owns this thread's log, so its history is read there.
          // The next turn still goes through the ACP bridge, which resumes
          // the host's own session id, so the thread continues where it left
          // off rather than starting a new one.
          const updates = await loadDshHostHistory(await dshHost(), {
            sessionId: body.sessionId,
            limit: historyLimit,
          });
          history.push(...updates);
        } else if (session.model || session.effort) {
          // A resumed thread keeps the model it was created with unless the
          // client asks for another one, so the choices land after the load.
          await applySessionChoices(bridge, session, await catalog());
        }
        session.busy = false;
        session.stream = null;
        res.writeHead(200, { "content-type": "application/json" }).end(
          JSON.stringify({ sessionId: chatId, remoteSessionId: body.sessionId, cwd, history: sliceThreadHistory(compactToolHistory(history), historyLimit) }),
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
          // A thread the client resumed keeps its own session id, whichever
          // engine owns it: the dsh-hosted engines resume by that id too, and
          // dropping it would start a different thread after a restart.
          if (active.resumeSessionId) {
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
        const result = await bridge.prompt(active.bridgeSessionId, prompt, images, active.cwd);
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
