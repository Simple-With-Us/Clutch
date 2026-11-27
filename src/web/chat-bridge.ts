#!/usr/bin/env node
/**
 * Clutch chat bridge — the native-chat SSE sidecar.
 *
 * `dsh web` exposes no REST API (its browser speaks the internal cordis
 * protocol), so native clients get this thin loopback server instead:
 *
 *   POST /clutch/v1/chat    {prompt, model?, sessionId?, cwd?} → SSE stream
 *   POST /clutch/v1/chat/cancel {sessionId} → stop one in-flight turn
 *   POST /clutch/v1/permissions {sessionId, requestId, optionId} → answer a
 *        permission request the engine is waiting on
 *   GET  /clutch/v1/thread?uid=<deviceUid>&limit=<n> → agent thread bubbles
 *   GET  /clutch/v1/health  liveness, engines, and MiniMax Code availability
 *   GET  /clutch/v1/sessions?engine=<engine> → that engine's threads
 *   POST /clutch/v1/sessions/load          → replay one thread of any engine
 *
 * SSE events: `message` {text}, `thought` {text}, `tool`
 * {id, name, status}, `permission` {requestId, title, toolName, options},
 * `done` {stopReason, sessionId}.  Each turn runs a real coding session through
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
import { createHash, createPrivateKey, randomBytes, timingSafeEqual } from "node:crypto";
import { accessSync, constants, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, unlinkSync, writeFileSync, type Dirent } from "node:fs";
import { mkdir, mkdtemp, readdir, rm, stat, utimes, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, delimiter, dirname, join, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { z } from "zod";

import { DshHostClientCache, isRefusedIdentity } from "./dshHostClientCache.ts";

import { clutchChatPort } from "../shared/ports.ts";
import { initClutchSettings } from "../shared/clutchSettings.ts";
import { ENGINE_LABELS, ENGINE_ORDER, EngineNameSchema, isDshHostedEngine, isEngine, type Engine } from "../shared/engine-types.ts";
import {
  engineCatalog,
  loadEnginePluginReport,
  resolveModelAltValue,
  resolveModelValue,
  type EngineCatalog,
  type EnginePluginReport,
} from "./engine-catalog.ts";
import { isTrustedHostHeader, tailnetDnsName, trustedAuthoritySet } from "./pair-link.ts";
import { readTailnetStatus } from "./tailnet-status.ts";
import { handleQuotasRequest } from "./quotas-route.ts";
import { handleInfisicalSettingsRequest } from "./infisical-route.ts";
import {
  ActivityPushRelay,
  ActivityTokenStore,
  handleActivityTokensRequest,
  type ActivitySnapshot,
  type ActivityThreadApproval,
  type ActivityThreadRun,
} from "./activityPushRelay.ts";
import { ApnsClient, CLUTCH_IOS_PUSH_TOPIC } from "./apnsClient.ts";
import { CometChatRelay, cleanEnvValue, cometchatConfigFromEnv, createStreamSink, isThreadUid, THREAD_MESSAGE_LIMIT_DEFAULT, THREAD_MESSAGE_LIMIT_MAX, type StreamSink } from "./cometchat-relay.ts";
import { miniMaxCodeRemoteHtml } from "./minimax-code-remote.ts";
import { attachSessionModelMetadata, readSessionUsage, withRate, type SessionModelMetadata, type SessionUsage } from "./session-usage.ts";
import { readZcodeSessionUsage } from "./zcode-session-usage.ts";
import { ZCODE_ACP_INSTALL, ZCODE_ACP_SETUP, defaultZcodeAcpServer, resolveZcodeCli, zcodeSignedIn, zcodeSpawnEnv } from "./zcode-acp.ts";
import { modelMetadataFromMuseConfigOptions } from "./muse-session-metadata.ts";
import { MuseLaunchOptionsSchema, MuseSettingsError, contributorDefaultModel, isMuseContributorModel, museContributorModelId, museLaunchArguments, sameMuseLaunchOptions, type MuseLaunchOptions } from "./muse-launch-options.ts";
import { museDisplayTitle, readMuseSessionLog, readMuseSessionName, readMuseSessionSummary } from "./muse-session-log.ts";
import { mapWithConcurrency } from "./bounded-map.ts";
import { museSessionUsage, withMuseContext } from "./muse-session-metrics.ts";
import { normalizeSessionFolder, sessionIsInFolder } from "./session-folder-scope.ts";
import { ContextPolicySchema, compactAvailabilityFromUpdate, contextUsageFromUpdate, shouldCompactEarly, type ContextPolicy, type ContextUsage } from "./muse-context.ts";
import { attachMuseErrorDiagnostics, museErrorDiagnostics } from "./muse-error-diagnostics.ts";
import { createTurnDiagnostics, type TurnDiagnosticHandle, type TurnOutcome } from "./turn-diagnostics.ts";
import { attachMuseAuthFailure, isMuseAuthAttemptId, MuseAuthController, type MuseAuthBridge, type MuseUrlElicitation } from "./muse-auth.ts";
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
import { createCron, deleteCron, listCrons, type CronRule } from "./dshHostCrons.ts";
import { findLiveTurn } from "./liveTurn.ts";
import { listDshHostSessions, loadDshHostHistory, type SessionSummary } from "./dshHostSessions.ts";
import { listDirectory, readPreview } from "./files.ts";
import { createDshHostSession, hostProviderFor, runDshHostTurn, selectHostModel } from "./dshHostTurn.ts";
import {
  DshHostApprovalRelay,
  type HostApproval,
  type HostApprovalOutcome,
} from "./dshHostApprovals.ts";
import { compactToolHistory, toolStatusOf, type PlanEntry, type SessionUpdate } from "./sessionUpdates.ts";

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
/** Where the phone's Live Activity push registrations live. */
const ACTIVITY_TOKEN_FILE = process.env.CLUTCH_ACTIVITY_TOKEN_FILE ?? join(CLUTCH_HOME, "activity-tokens.json");

/**
 * The folder a thread works in when the client did not name one.
 *
 * The same default the chat route uses, so the files a client looks at are
 * the files a turn would work in.
 */
function defaultCwd(): string {
  // An empty HOME must not fall through to process.cwd().
  return process.env.HOME || "/tmp";
}

interface Launcher {
  command: string;
  args: string[];
  /** Set when an operator's CLUTCH_CHAT_LAUNCHER_<ENGINE> replaced the shipped launcher. */
  override?: boolean;
}

/**
 * The engines whose threads their own ACP bridge keeps and resumes.
 *
 * The dsh-hosted engines (DeepSeek, MiniMax) are not here: the dsh host owns
 * their session log, and the sidecar reads it through the host while the
 * bridge only carries the turns.
 */
const CODE_ENGINES: Engine[] = ["mcode", "muse", "zcode"];

/**
 * How long a failed connection to the dsh host is remembered.
 *
 * The host is a separate process from the sidecar, so it may start after the
 * sidecar or restart under it; the failure is remembered only long enough to
 * avoid hammering a host that is not there.
 */
const HOST_RETRY_COOLDOWN_MS = 30_000;

/**
 * How long the availability check waits for the dsh host to answer.
 *
 * The host is a local process, so it answers at once or not at all.  The
 * bound keeps a host that accepts the connection and then goes quiet from
 * holding the catalog back, and the fallback path is the one the check
 * falls back to when the probe times out.
 */
const HOST_PROBE_TIMEOUT_MS = 2_000;

/**
 * How long a permission request waits for the client's answer.
 *
 * The engine is blocked until the request is answered, so a client that
 * never answers must not block the turn forever: the sidecar falls back to
 * the allow-once it has always sent.
 */
const PERMISSION_TIMEOUT_MS = 120_000;


const defaultMcode = [
  join(homedir(), ".local", "bin", "mcode"),
  join(homedir(), ".minimax-code", "bin", "mcode"),
].find(existsSync) ?? "mcode";
const mcodeLauncherOverride = process.env.CLUTCH_CHAT_LAUNCHER_MCODE?.trim();
const museLauncherOverride = process.env.CLUTCH_CHAT_LAUNCHER_MUSE?.trim();
const zcodeLauncherOverride = process.env.CLUTCH_CHAT_LAUNCHER_ZCODE?.trim();

const LAUNCHERS: Record<Engine, Launcher> = {
  // CLUTCH_CHAT_LAUNCHER_<ENGINE> overrides exist for the full-loop test,
  // which points the engines at a stub script. Production always uses the
  // shipped launchers below.
  deepseek: { command: process.env.CLUTCH_CHAT_LAUNCHER_DEEPSEEK?.trim() || join(ROOT, "scripts", "dsh-acp.sh"), args: [] },
  minimax: { command: process.env.CLUTCH_CHAT_LAUNCHER_MINIMAX?.trim() || join(ROOT, "scripts", "minimax-acp.sh"), args: [] },
  mcode: mcodeLauncherOverride
    ? { command: mcodeLauncherOverride, args: [] }
    : { command: process.env.CLUTCH_MCODE_CLI?.trim() || defaultMcode, args: ["acp"] },
  // The shipped launcher prefers current Muse Code's native experimental ACP
  // command and falls back to the community MSP adapter for older hosts.  In
  // either case the sidecar receives the same ACP v1 stream and needs no
  // Python bridge for this engine.
  muse: museLauncherOverride
    ? { command: museLauncherOverride, args: [] }
    : { command: join(ROOT, "scripts", "muse-code-acp.sh"), args: [] },
  // Z Code is the third code engine, but unlike mcode its CLI has no ACP
  // command:  the launcher is the `zcode-acp-server` bridge, which drives
  // `zcode app-server --stdio` and speaks ACP v1 on stdio (C-129; see
  // ./zcode-acp.ts).  CLUTCH_ZCODE_ACP_CLI names a bridge the default search
  // missed, and CLUTCH_ZCODE_CLI still names the Z Code CLI the bridge drives.
  zcode: zcodeLauncherOverride
    ? { command: zcodeLauncherOverride, args: [], override: true }
    : { command: defaultZcodeAcpServer(), args: [] },
};

/** Engines a phone or Mac can pick, in the order the picker shows them. */
export { ENGINE_ORDER, ENGINE_LABELS, isEngine, type Engine } from "../shared/engine-types.ts";

function log(line: string): void {
  process.stderr.write(`chat-bridge: ${line}\n`);
}

/** Whether a bare command name resolves on PATH. */
function commandOnPath(command: string, env: Record<string, string | undefined> = process.env): boolean {
  const path = env.PATH ?? "";
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
 * MiniMax Code's; `zcode-*` and GLM ids (`glm-*`) are Z Code's; everything
 * else stays on the DeepSeek sidecar.
 */
export function engineForModelId(model: string | undefined): Engine | null {
  if (typeof model !== "string") return null;
  const id = model.trim().toLowerCase();
  if (!id) return null;
  if (id.startsWith("muse")) return "muse";
  if (id.startsWith("mcode")) return "mcode";
  if (id.startsWith("minimax")) return "minimax";
  if (id.startsWith("deepseek")) return "deepseek";
  if (id.startsWith("zcode")) return "zcode";
  if (id.startsWith("glm-")) return "zcode";
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
/** Whether a socket peer is this machine, mirroring ClutchHost.isLocal:
 * loopback in dotted, mapped-dotted and mapped-hex forms, nothing looser. */
export function isLoopbackRemoteAddress(remote: string): boolean {
  if (remote === "::1" || remote.startsWith("127.")) return true;
  if (!remote.startsWith("::ffff:")) return false;
  const mapped = remote.slice("::ffff:".length);
  if (mapped.startsWith("127.")) return true;
  const hextets = mapped.split(":");
  // Exactly two hextets of at most four hex digits for the colon form, or
  // one word of at most eight; anything longer or wider is not a mapped
  // loopback at all. Both hextets must fit a UInt16.
  if (hextets.length === 2) {
    if (!hextets.every((part) => /^[0-9a-f]{1,4}$/i.test(part))) return false;
    const high = Number.parseInt(hextets[0]!, 16);
    const low = Number.parseInt(hextets[1]!, 16);
    return high <= 0xffff && low <= 0xffff && high >> 8 === 0x7f;
  }
  if (hextets.length === 1) {
    if (!/^[0-9a-f]{1,8}$/i.test(mapped)) return false;
    const word = Number.parseInt(mapped, 16);
    return word <= 0xffffffff && word >> 24 === 0x7f;
  }
  return false;
}

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

/** Whether the Z Code launcher (the `zcode-acp-server` bridge) is present on this machine. */
export function zcodeAvailable(launcher: Launcher = LAUNCHERS.zcode, path = process.env.PATH ?? ""): boolean {
  if (launcher.command.includes("/")) return existsSync(launcher.command);
  // A bare name is the PATH fallback: resolve it, so health reports false
  // when the CLI is missing instead of failing on the first send.
  return path.split(delimiter).filter(Boolean).some((dir) => executableFile(join(dir, launcher.command)));
}

function executableFile(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

/**
 * Passive installation check for the selected Muse backend.
 * The launcher validates native ACP support only when a user starts it.
 */
export async function museInstalled(
  env: Record<string, string | undefined> = process.env,
  candidates: {
    hosts?: string[];
    adapters?: string[];
  } = {},
): Promise<boolean> {
  // An explicit override only counts when the path is really there: a stale
  // variable must not make the catalog claim Muse Code is installed.
  const hostPaths = candidates.hosts ?? [
    ...(env.PATH ?? "").split(":").filter(Boolean).map((dir) => join(dir, "muse")),
    "/usr/local/bin/muse",
    "/opt/homebrew/bin/muse",
    join(homedir(), ".local", "bin", "muse"),
  ];
  // The launcher's own search list wins, so a host that keeps the adapter
  // outside the global npm prefix (the fleet runtime does) still reads as
  // installed.
  const adapterPaths = candidates.adapters ?? [
    ...(env.PATH ?? "").split(":").filter(Boolean).map((dir) => join(dir, "muse-code-acp")),
    ...(env.MUSE_CODE_ACP_SEARCH_PATHS ?? "")
      .split(":")
      .filter((dir) => dir.length > 0)
      .map((dir) => join(dir, "muse-code-acp")),
    "/usr/local/bin/muse-code-acp",
    "/opt/homebrew/bin/muse-code-acp",
    join(homedir(), ".local", "bin", "muse-code-acp"),
  ];
  const override = env.MUSE_CODE_EXECUTABLE?.trim();
  const host = (override && executableFile(override) ? override : undefined)
    || hostPaths.find(executableFile);
  if (!host) return false;
  const backend = env.MUSE_CODE_ACP_BACKEND?.trim() || "auto";
  if (backend !== "auto" && backend !== "native" && backend !== "adapter") return false;
  if (backend !== "adapter") return true;
  const adapterOverride = env.MUSE_CODE_ACP_BIN?.trim();
  const adapter = (adapterOverride && executableFile(adapterOverride) ? adapterOverride : undefined)
    || adapterPaths.find(executableFile);
  return Boolean(adapter);
}

/**
 * What one engine needs before a turn can run.
 *
 * `available` in the catalog means exactly this: the launcher starts and the
 * credential the engine needs is reachable.  A launcher file on disk is not
 * enough — a bridge with no interpreter and an engine with no key both
 * answer every turn with "bridge exited" or an auth error.
 */
export interface EngineAvailability {
  /** True when a turn can actually run on this host. */
  available: boolean;
  /**
   * One short sentence saying what is missing and where to put it.
   *
   * The owner reads this in the engine picker, so it names a place to put the
   * credential and never a value.
   */
  note?: string;
}

/**
 * The host facts the availability check reads.
 *
 * Every input is injectable, so the check can be exercised on any machine:
 * the environment the launcher will run in, the launcher each engine uses,
 * the dsh credential store the bridges read, and Clutch's own settings.
 */
export interface EngineAvailabilityContext {
  /** The environment the launcher will run in. */
  env?: Record<string, string | undefined>;
  /** The launcher each engine uses. */
  launchers?: Record<Engine, Launcher>;
  /** The dsh credential store the bridges read. */
  credentialFile?: string;
  /** Clutch's own settings (Infisical-backed), when the sidecar has them. */
  settings?: { get(key: string): string };
  /**
   * Whether a dsh host is reachable to run the dsh-hosted engines.
   *
   * The DeepSeek and MiniMax turns run in the host when it answers, and the
   * Python bridge is only the fallback path, so a host that is up satisfies
   * the engine on a machine that has no interpreter for the bridge.  The
   * caller knows this because it holds the host client.
   */
  hostReachable?: boolean;
  /**
   * The interpreter paths to try, in order, after `PYTHON`.
   *
   * The default is the launcher's own order: `/opt/homebrew/bin/python3`
   * first, then `python3` on PATH.  A caller that answers for a different
   * machine's layout supplies its own list, so the answer never depends on
   * what the host happens to have installed.
   */
  interpreterCandidates?: readonly string[];
}

/**
 * The DSH credential file path for DeepSeek and MiniMax.
 *
 * `scripts/lib/clutch-env.sh` forces `DSH_HOME` to `$CLUTCH_HOME/dsh`, so
 * this is the one file both bridges open when the environment carries no
 * key.  DeepSeek keeps its legacy presence check; MiniMax parses its exact
 * provider assignment below.
 */
function dshCredentialFile(env: Record<string, string | undefined>): string {
  const clutchHome = env.CLUTCH_HOME ?? join(env.HOME ?? homedir(), ".clutch");
  return join(clutchHome, "dsh", ".credentials.yaml");
}

/** Read only whether one exact nonempty simple assignment exists in a DSH file. */
function credentialFileHasKey(path: string, names: readonly string[]): boolean {
  let content: string;
  try {
    content = readFileSync(path, "utf8");
  } catch {
    return false;
  }
  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*[:=]\s*(.*?)\s*$/.exec(line);
    if (!match || !names.includes(match[1]!)) continue;
    let value = match[2]!.trim();
    if (value.startsWith("'") || value.startsWith('"')) {
      if (value.length < 2 || value.at(-1) !== value[0]) continue;
      value = value.slice(1, -1).trim();
    } else if (value.endsWith("'") || value.endsWith('"')) {
      continue;
    }
    if (value) return true;
  }
  return false;
}

/**
 * A managed setting's value.
 *
 * The environment comes first: an explicitly-set env var is the operator's
 * own override, and Clutch's rule is that it beats the managed store.  The
 * settings cache is the fallback for the keys the environment does not
 * carry.
 */
function settingValue(
  name: string,
  env: Record<string, string | undefined>,
  settings?: { get(key: string): string },
): string {
  const fromEnv = (env[name] ?? "").trim();
  if (fromEnv) return fromEnv;
  return settings?.get(name)?.trim() ?? "";
}

/**
 * The interpreter the dsh launchers will use.
 *
 * `scripts/dsh-acp.sh` and `scripts/minimax-acp.sh` look for `PYTHON`, then
 * `/opt/homebrew/bin/python3`, then `python3` on PATH.  A host with none of
 * them answers every turn with "bridge exited", which is why the interpreter
 * is checked here and not left to the turn.
 */
const DEFAULT_INTERPRETER_CANDIDATES: readonly string[] = ["/opt/homebrew/bin/python3"];

function pythonInterpreter(
  env: Record<string, string | undefined>,
  candidates: readonly string[] = DEFAULT_INTERPRETER_CANDIDATES,
): string | null {
  const named = (env.PYTHON ?? "").trim();
  if (named && executableFile(named)) return named;
  for (const candidate of candidates) {
    if (executableFile(candidate)) return candidate;
  }
  for (const dir of (env.PATH ?? "").split(":")) {
    if (!dir) continue;
    const candidate = join(dir, "python3");
    if (executableFile(candidate)) return candidate;
  }
  return null;
}

/**
 * The MiniMax Code credential files under a directory.
 *
 * `mcode login` writes an OAuth credential under `~/.minimax/auth`, in a
 * layout that has changed between releases, so the file is found by name
 * rather than by a fixed path.  The search is bounded, so a deep tree of
 * directories cannot turn a sign-in check into a crawl.
 */
function findAuthFiles(dir: string, depth: number): string[] {
  if (depth > 4) return [];
  let entries: Dirent[];
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  const files: string[] = [];
  for (const entry of entries) {
    if (entry.isFile() && entry.name === "auth.json") files.push(join(dir, entry.name));
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    files.push(...findAuthFiles(join(dir, entry.name), depth + 1));
  }
  return files;
}

/**
 * Whether only the owner can read the credential file.
 *
 * MiniMax Code refuses a credential that anybody else can read, so a
 * group-readable file is not a sign-in: the CLI keeps listing its threads
 * and refuses every turn, which is the same lie the catalog must not tell.
 * The rule is the documented one — the credential file is mode 600.
 */
function credentialIsPrivate(file: string): boolean {
  try {
    return (statSync(file).mode & 0o077) === 0;
  } catch {
    return false;
  }
}

/**
 * The MiniMax Code credential, and whether only its owner can read it.
 *
 * `mcode login` writes an OAuth credential under `~/.minimax/auth`; without
 * it the CLI lists its threads but refuses every turn, which is the same
 * lie the catalog must not tell.
 */
function mcodeCredential(env: Record<string, string | undefined>): { file: string; private: boolean } | null {
  const files = findAuthFiles(join(env.HOME ?? homedir(), ".minimax", "auth"), 0);
  const first = files[0];
  if (!first) return null;
  const privateFile = files.find((file) => credentialIsPrivate(file));
  return { file: privateFile ?? first, private: privateFile !== undefined };
}

/**
 * Whether Muse Code has a credential the spawned host can reach.
 *
 * Only `META_API_KEY` counts.  The spawned `muse serve` host cannot read the
 * CLI's own login: on macOS that login lives in the login keychain, which a
 * background session cannot open, and the provider catalog on disk says
 * which models an account may use rather than proving the spawned host can
 * authenticate.  A browser login therefore leaves the spawned host
 * unauthenticated, so the key is the only credential the host ever reads
 * (see INFISICAL.md).
 */
function museSignedIn(
  env: Record<string, string | undefined>,
  settings?: { get(key: string): string },
): boolean {
  return Boolean(settingValue("META_API_KEY", env, settings));
}

/**
 * Whether an engine can actually run a turn here.
 *
 * Two things have to hold: the launcher has to start (the file is there and
 * the interpreter it needs is there), and the credential the engine needs
 * has to be reachable.  The check stays cheap on purpose — files and
 * environment first, so the picker can ask for it on every request.  The
 * supported MiniMax launcher loads Clutch's managed settings before starting
 * the Python bridge; no external secret CLI is consulted here.
 *
 * The dsh-hosted engines are the one case where the answer depends on more
 * than this machine: the host runs their turns when it answers, and the
 * Python bridge is only the fallback, so a reachable host satisfies the
 * engine on its own.
 */
export async function engineAvailability(
  engine: Engine,
  context: EngineAvailabilityContext = {},
): Promise<EngineAvailability> {
  const env = context.env ?? process.env;
  const launchers = context.launchers ?? LAUNCHERS;
  const settings = context.settings;
  const launcher = launchers[engine];
  const label = ENGINE_LABELS[engine];

  // A launcher with a path is checked against the filesystem; a bare
  // command name is checked against PATH, so a server without MiniMax
  // Code does not claim to have it.
  // Z Code's launcher is its ACP bridge rather than the engine itself, so a
  // missing launcher names the bridge's install line.
  const missingLauncher = engine === "zcode"
    ? `${label} needs its ACP bridge on this host.\u00A0 Run ${ZCODE_ACP_INSTALL}.`
    : `${label} is not installed on this host.`;
  if (launcher.command.includes("/")) {
    if (!existsSync(launcher.command)) {
      return { available: false, note: missingLauncher };
    }
  } else if (!commandOnPath(launcher.command, env)) {
    return { available: false, note: missingLauncher };
  }

  if (engine === "muse") {
    if (!await museInstalled(env)) {
      return { available: false, note: `${label} is not installed on this host.` };
    }
    if (!museSignedIn(env, settings)) {
      // This one stays available.  The Muse sign-in lives behind the engine
      // being selected, so an engine that needs a sign-in but is dropped from
      // the picker takes the owner's only way to sign in with it.  The note
      // says what is still needed, and the app finishes it in place.
      //
      // The CLI login is the route on the Mac, where the desktop helper
      // starts Muse in the desktop security session and the saved login is
      // readable.  Everywhere else the spawned host reads the key only, so
      // the note names the key as well.
      return {
        available: true,
        note: `${label} needs a sign-in.\u00A0 Run muse login on the Mac, where the desktop helper starts Muse with that saved login, or add META_API_KEY in Clutch settings.`,
      };
    }
    return { available: true };
  }

  if (engine === "mcode") {
    const credential = mcodeCredential(env);
    if (!credential) {
      return {
        available: false,
        note: `${label} needs a sign-in.\u00A0 Run mcode login as the user this sidecar runs as.`,
      };
    }
    if (!credential.private) {
      // The credential file is there, but MiniMax Code refuses a credential
      // that anyone else can read, so the turn would fail with a token error
      // that reads like a sign-in problem.  The note names the file and the
      // fix instead.
      return {
        available: false,
        note: `${label} needs a private credential file.\u00A0 Run chmod 600 ${credential.file}, then sign in again.`,
      };
    }
    return { available: true };
  }

  if (engine === "zcode") {
    // A full launcher override (test hooks, unusual installs) is the
    // operator's own command, which may drive neither the bridge nor the CLI,
    // so neither the CLI nor the sign-in the bridge reads is checked for it.
    // The mark is read off the launcher this check was handed, the same one
    // the health route and the spawn use, and the existence check above has
    // already run against the override's own command.  A path also has to be
    // a file the spawn can run:  that check accepts a directory.
    if (launcher.override) {
      return launcher.command.includes("/") && !executableFile(launcher.command)
        ? { available: false, note: `${label} is not installed on this host.` }
        : { available: true };
    }
    // The bridge drives the Z Code CLI, so the CLI has to be here too.
    if (!resolveZcodeCli(env)) {
      return { available: false, note: `${label} is not installed on this host.\u00A0 Install the Z Code app or CLI.` };
    }
    // Same reasoning as Muse: the sign-in the bridge reads is the Z Code
    // app's own, or a saved `zcode-acp setup` account, and the file check
    // cannot see every form of it, so a missing one keeps the engine listed
    // with a note instead of dropping it.  An API key in Clutch settings is
    // not a Z Code sign-in:  the bridge never reads one.
    if (!zcodeSignedIn(env)) {
      return {
        available: true,
        note: `${label} needs a sign-in.\u00A0 Sign in through the Z Code app, or run ${ZCODE_ACP_SETUP} as the user this sidecar runs as.`,
      };
    }
    return { available: true };
  }

  // The dsh engines: the bridge needs an interpreter, and the provider key
  // has to be reachable from the environment or from the credential store
  // the bridge reads.  A reachable dsh host runs the turn itself, so the
  // interpreter is a requirement of the fallback path alone: a host that
  // answers must not lose the engine from the picker over a bridge it will
  // never run.
  if (!context.hostReachable && !pythonInterpreter(env, context.interpreterCandidates)) {
    return { available: false, note: `${label} needs Python 3 to run its bridge.` };
  }
  const credentialFile = context.credentialFile ?? dshCredentialFile(env);
  if (engine === "deepseek") {
    if (!settingValue("DEEPSEEK_API_KEY", env, settings) && !existsSync(credentialFile)) {
      return {
        available: false,
        note: `${label} needs an API key.\u00A0 Add DEEPSEEK_API_KEY in Clutch settings, or save it in ${credentialFile}.`,
      };
    }
  }
  if (engine === "minimax") {
    // The supported wrapper backfills Clutch-managed settings into the
    // launch environment.  Direct bridge invocation may instead use the DSH
    // credential file; these are the only credential sources this path
    // advertises.
    const keyName = settingValue("CLUTCH_MINIMAX_API_KEY_NAME", env, settings) || "MINIMAX_API_KEY";
    const inEnvironment = Boolean(
      settingValue(keyName, env, settings) || settingValue("MINIMAX_API_KEY", env, settings),
    );
    if (!inEnvironment && !credentialFileHasKey(credentialFile, [keyName, "MINIMAX_API_KEY"])) {
      return {
        available: false,
        note: `${label} needs an API key.\u00A0 Add ${keyName} in Clutch settings or save it in ${credentialFile}.`,
      };
    }
  }
  return { available: true };
}

/**
 * How long the availability answers are reused.
 *
 * The same window the engine catalog keeps its entry for, so the probes and
 * the catalog they feed expire together and a warm catalog never carries an
 * answer from a probe that is older than the entry it sits in.
 */
const AVAILABILITY_TTL_MS = 5 * 60 * 1000;

/** One cached answer, and the moment it was taken. */
export interface CachedAnswer<T> {
  at: number;
  value: T;
}

/**
 * The cached answer, or null when there is none or it has expired.
 *
 * The availability check reads the filesystem and the catalog that uses its
 * answer is cached for a few minutes, so the answer is kept for the same
 * while: a warm catalog must not pay for probes it is about to discard.
 */
export function cachedAnswer<T>(
  entry: CachedAnswer<T> | null,
  ttlMs: number,
  now: number,
): T | null {
  if (!entry) return null;
  return now - entry.at < ttlMs ? entry.value : null;
}

/**
 * The notes the sidecar has published for an engine, over its lifetime.
 *
 * The set is what tells a stale note from one the catalog wrote itself: the
 * sidecar's notes are the only ones it has ever published, so a note that is
 * in the set and no longer current was the sidecar's, and a note that is not
 * in the set came from the catalog and stays.
 */
export type PublishedNotes = Map<Engine, Set<string>>;

/**
 * Put the sidecar's current notes on the catalog's descriptors.
 *
 * The catalog is cached for a few minutes, so a descriptor can carry a note
 * from the moment it was built: an engine that needed a key then can be
 * signed in now, and the picker would still ask for a key the owner has
 * already supplied.  The sidecar's note is the current one, and a note that
 * is gone is dropped rather than left behind.
 */
export function withCurrentNotes(
  catalog: EngineCatalog,
  notes: Partial<Record<Engine, string>>,
  published: PublishedNotes = new Map(),
): EngineCatalog {
  return {
    engines: catalog.engines.map((descriptor) => {
      const { note: built, ...rest } = descriptor;
      const current = notes[descriptor.id];
      if (current) return { ...rest, note: current };
      if (built && published.get(descriptor.id)?.has(built)) return rest;
      return built ? { ...rest, note: built } : rest;
    }),
  };
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

/**
 * Whether the request carries the sidecar's Bearer token.
 *
 * The header value arrives parsed, so it is a string or it is nothing: a
 * malformed value never reaches the comparison.
 */
function bearerOk(authorization: string | undefined, token: string): boolean {
  const header = authorization ?? "";
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
 * What the engine wrote as raw JSON, in one line.
 *
 * The engine writes a tool's arguments and its result as JSON, sometimes as
 * an object and sometimes as a string that already holds JSON.  Both are
 * read here, and neither is invented:  what cannot be read is nothing.
 */
function rawToolText(raw: unknown): string {
  if (typeof raw === "string") return raw.slice(0, 8000);
  if (raw === undefined || raw === null) return "";
  try {
    return JSON.stringify(raw).slice(0, 8000);
  } catch {
    return "";
  }
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
      // What the call was asked and what it answered.  The engine writes the
      // arguments and the result as raw JSON, and a card that shows only the
      // name of the tool shows nothing of the work.
      ...(kind === "tool_call" && update.rawInput !== undefined
        ? { toolInput: rawToolText(update.rawInput) }
        : {}),
      ...(kind === "tool_call_update" && update.rawOutput !== undefined
        ? { toolOutput: rawToolText(update.rawOutput) }
        : {}),
    };
  }
  if (kind === "plan" || kind === "plan_update" || kind === "plan_removed") {
    // The engine sends the whole plan every time it changes, so the client
    // replaces the list it has rather than patching it.
    const entries = readPlanEntries(update, kind);
    // A plan the sidecar cannot read is dropped rather than emptied.  A shape
    // it does not know is not a plan the engine removed, and emptying the
    // list would wipe the plan the owner is looking at.
    if (entries === null) return null;
    return { sessionId: row.sessionId, kind: "plan", text: "", plan: entries };
  }
  return null;
}

/**
 * The plan entries an update carries.
 *
 * `plan_update` nests the entries under a content object whose type says
 * what shape they are in.  Only the item shape is a list the clients can
 * show, so the others are dropped rather than guessed at, and a plan that
 * was removed arrives as an empty list.
 *
 * Null means the shape was not one this sidecar reads: the caller keeps
 * what it has rather than treating the plan as gone.
 */
function readPlanEntries(update: Record<string, unknown>, kind: string): PlanEntry[] | null {
  // A removed plan is an empty list, not a missing one.
  if (kind === "plan_removed") return [];
  const content = update.content;
  const nested =
    typeof content === "object" && content !== null
      ? (content as Record<string, unknown>).entries
      : undefined;
  const raw = Array.isArray(update.entries) ? update.entries : nested;
  if (!Array.isArray(raw)) return null;
  const entries: PlanEntry[] = [];
  for (const item of raw) {
    if (typeof item !== "object" || item === null) continue;
    const record = item as Record<string, unknown>;
    const content = typeof record.content === "string" ? record.content.trim() : "";
    if (!content) continue;
    entries.push({
      content,
      priority: planPriority(record.priority),
      status: planStatus(record.status),
    });
  }
  return entries;
}

/** The engine's priority for a plan entry, or the middle one it did not say. */
function planPriority(raw: unknown): "high" | "medium" | "low" {
  switch (raw) {
    case "high":
      return "high";
    case "low":
      return "low";
    default:
      return "medium";
  }
}

/** Where a plan entry stands. */
function planStatus(raw: unknown): "pending" | "in_progress" | "completed" {
  switch (raw) {
    case "completed":
      return "completed";
    case "in_progress":
      return "in_progress";
    default:
      return "pending";
  }
}

interface AcpSessionInfo {
  sessionId: string;
  cwd?: string;
  title?: string;
  updatedAt?: string;
  /** Real engine accounting, present only when the log could be read. */
  usage?: SessionUsage;
  provider?: string;
  model?: string;
  /** Clutch-side Project assignment and archive state. */
  projectId?: string;
  archived?: boolean;
}

/**
 * Whether two readings of an engine's log are the same record.
 *
 * The engine's timestamp is optional, so it cannot be the only thing compared:
 * two different records without one would look identical.  The counters and
 * the duration are what change when the engine writes again.
 */
export function sameUsageReading(left: SessionUsage, right: SessionUsage): boolean {
  return left.updatedAtMs === right.updatedAtMs
    && left.inputTokens === right.inputTokens
    && left.outputTokens === right.outputTokens
    && left.totalTokens === right.totalTokens
    && left.cacheReadTokens === right.cacheReadTokens
    && left.responseTokensPerSecond === right.responseTokensPerSecond
    && left.completionDurationMs === right.completionDurationMs
    && left.model === right.model
    && left.provider === right.provider;
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
  includeTitleOverrides = true,
): AcpSessionInfo[] {
  const out: AcpSessionInfo[] = [];
  for (const session of sessions) {
    const entry = meta.sessions[session.sessionId];
    if (entry?.archived && !includeArchived) continue;
    out.push({
      ...session,
      ...(includeTitleOverrides && entry?.title ? { title: entry.title } : {}),
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

class MuseSteeringError extends Error {
  constructor(readonly reason: "unsupported" | "idle" | "stale" | "inactive", readonly code?: number) {
    super(`Muse steering ${reason}`);
    this.name = "MuseSteeringError";
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

/**
 * The counter behind the permission request ids.
 *
 * It is file-wide rather than per bridge, so an id names one request in the
 * whole process and a client cannot answer the wrong turn's request.
 */
let permissionCounter = 0;

/** One option the engine offers for a permission request. */
export interface PermissionOption {
  /** The id the client sends back. */
  optionId: string;
  /** The engine's kind for the option: allow_once, allow_always, reject_once, reject_always. */
  kind: string;
  /** The engine's own name for the option. */
  name: string;
}

/**
 * What the tool wants to do, in the words the owner reads before answering.
 *
 * An approval the owner cannot read is not an approval, so the sidecar
 * carries the command for a shell tool, the path for a file tool and a
 * compact diff for an edit.  Nothing larger crosses the wire, and a field
 * the engine sent that this file does not name never reaches the client.
 */
export interface PermissionEvidence {
  /** The command the tool wants to run. */
  command?: string;
  /** The path the tool wants to touch. */
  path?: string;
  /** The lines the tool wants to write, as a compact diff. */
  diff?: string;
}

/**
 * What the owner reads about a permission request, read from the engine's own
 * params.
 *
 * The params are untrusted, so they are parsed against the known shape
 * first:  a field this file does not name is dropped here and never
 * reaches the client.
 */
export function permissionEvidenceFromParams(params: unknown): PermissionEvidence | undefined {
  const parsed = PermissionParamsSchema.safeParse(params);
  if (!parsed.success) return undefined;
  return buildPermissionEvidence(parsed.data.toolCall?.rawInput);
}

/** A permission request the engine is waiting on. */
export interface PermissionRequest {
  /** The id the client answers with. */
  requestId: string;
  /** The ACP session that asked. */
  sessionId: string;
  /** What the tool wants to do, as the engine described it. */
  title: string;
  /** The tool that wants the permission. */
  toolName: string;
  /** The options the engine offers. */
  options: PermissionOption[];
  /** What the tool wants to do, when the engine said enough for the owner to read it. */
  evidence?: PermissionEvidence;
}

/** Read one string field out of an unknown value, or null. */
function readString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

/** How many changed lines a compact diff shows before it says how many more. */
const EVIDENCE_DIFF_LINES = 3;

/** How much of one side of an edit the evidence reads. */
const EVIDENCE_EDIT_LIMIT = 20_000;

/** What the diff says when the edit it read was cut. */
const EVIDENCE_CUT_MARKER = "… the edit was cut here; more may have changed";

/** How long one line of the evidence may be. */
const EVIDENCE_LINE_LIMIT = 160;

/** One side of an edit, and whether it was cut.
 *
 * The cut is at a line boundary, because a cut inside a line compares two
 * halves of a line as two different lines and says the edit changed when
 * it did not.  The cut never leaves half a character behind either:  a
 * character that is half of a pair is not a character, and it misrenders
 * on the card.
 */
function boundedEdit(text: string): { text: string; cut: boolean } {
  if (text.length <= EVIDENCE_EDIT_LIMIT) return { text, cut: false };
  let head = text.slice(0, EVIDENCE_EDIT_LIMIT);
  const newline = head.lastIndexOf("\n");
  if (newline >= 0) head = head.slice(0, newline + 1);
  if (head.length > 0) {
    const last = head.charCodeAt(head.length - 1);
    // A high surrogate at the end is half of a pair, and the other half is
    // past the cut.
    if (last >= 0xd800 && last <= 0xdbff) head = head.slice(0, -1);
  }
  return { text: head, cut: true };
}

/** The lines a text holds, without the empty ones. */
function contentLines(text: string | undefined): string[] {
  return (text ?? "").split("\n").filter((line) => line.trim().length > 0);
}

/** One line of evidence, cut to a length a card can hold.
 *
 * The cut never leaves half of a character behind:  a character that is
 * half of a pair is not a character, and it misrenders on the card.
 */
function evidenceLine(line: string): string {
  if (line.length <= EVIDENCE_LINE_LIMIT) return line;
  let cut = line.slice(0, EVIDENCE_LINE_LIMIT);
  const last = cut.charCodeAt(cut.length - 1);
  if (last >= 0xd800 && last <= 0xdbff) cut = cut.slice(0, -1);
  return `${cut}…`;
}

/** A compact diff of what an edit would write.
 *
 * The owner reads the lines that change and not the whole file, so the
 * diff shows a few of them and says how many it left out.
 */
export function compactDiff(
  oldText: string | undefined,
  newText: string | undefined,
  cut = false,
): string | undefined {
  const before = contentLines(oldText);
  const after = contentLines(newText);
  if (before.length === 0 && after.length === 0) return undefined;
  // The lines the two sides share at the head and at the tail did not
  // change, so the diff shows only the part in the middle:  a diff that
  // calls an unchanged line removed is a diff that lies.
  let head = 0;
  while (head < before.length && head < after.length && before[head] === after[head]) head += 1;
  let tail = 0;
  while (
    tail < before.length - head &&
    tail < after.length - head &&
    before[before.length - 1 - tail] === after[after.length - 1 - tail]
  ) {
    tail += 1;
  }
  const removed = before.slice(head, before.length - tail);
  const added = after.slice(head, after.length - tail);
  // The two sides read the same, so the change may be past the cut:  an
  // edit that was cut says so even when what was read did not differ.
  if (removed.length === 0 && added.length === 0) return cut ? EVIDENCE_CUT_MARKER : undefined;
  // A line that was added or taken away moves the lines around it, so the
  // diff says the line that was added or taken away rather than the same
  // lines twice:  a change the owner reads as three changed lines is a
  // change the owner was not shown.
  let shownRemoved = removed;
  let shownAdded = added;
  if (
    removed.length > 0 &&
    added.length === removed.length + 1 &&
    added.slice(1).every((line, index) => line === removed[index])
  ) {
    shownRemoved = [];
    shownAdded = added.slice(0, 1);
  } else if (
    added.length > 0 &&
    removed.length === added.length + 1 &&
    removed.slice(1).every((line, index) => line === added[index])
  ) {
    shownRemoved = removed.slice(0, 1);
    shownAdded = [];
  }
  const lines: string[] = [];
  for (const line of shownRemoved.slice(0, EVIDENCE_DIFF_LINES)) lines.push(`- ${evidenceLine(line)}`);
  for (const line of shownAdded.slice(0, EVIDENCE_DIFF_LINES)) lines.push(`+ ${evidenceLine(line)}`);
  const more =
    Math.max(0, shownRemoved.length - EVIDENCE_DIFF_LINES) + Math.max(0, shownAdded.length - EVIDENCE_DIFF_LINES);
  if (more > 0) lines.push(`… ${more} more line${more === 1 ? "" : "s"}`);
  // An edit larger than the evidence reads may still change past the cut,
  // so the diff says so beside the lines it could align.
  if (cut) lines.push(EVIDENCE_CUT_MARKER);
  return lines.join("\n");
}

/**
 * What the tool wants to do, read from the input the engine sent.
 *
 * The input is untrusted, so only the fields this file names are read and
 * only what the owner needs is kept:  the command, the path and the diff.
 * A tool whose input says none of those has no evidence, and the card says
 * so rather than showing something the engine never wrote.
 */
export function buildPermissionEvidence(rawInput: unknown): PermissionEvidence | undefined {
  if (typeof rawInput !== "object" || rawInput === null || Array.isArray(rawInput)) return undefined;
  const record = rawInput as Record<string, unknown>;
  // The limits live here, where the evidence is built, so every path into
  // the client cuts the same way:  a cut text says that it was cut.
  const command = readString(record.command);
  const path = readString(record.file_path) ?? readString(record.path);
  // The diff reads a bounded part of the edit, because the engine's input
  // is unbounded and the request is on the message path:  the part that was
  // cut is said in the diff, so a change past the cut is not a change the
  // owner is told does not exist.
  const oldRaw = typeof record.old_string === "string" ? record.old_string : undefined;
  const newRaw = typeof record.new_string === "string" ? record.new_string : undefined;
  const oldEdit = oldRaw === undefined ? undefined : boundedEdit(oldRaw);
  const newEdit = newRaw === undefined ? undefined : boundedEdit(newRaw);
  const diff = compactDiff(
    oldEdit?.text,
    newEdit?.text,
    oldEdit?.cut === true || newEdit?.cut === true,
  );
  if (!command && !path && !diff) return undefined;
  return {
    ...(command ? { command: bounded(command, 2_000) } : {}),
    ...(path ? { path: bounded(path, 1_000) } : {}),
    ...(diff ? { diff } : {}),
  };
}

/**
 * Cuts a text to a length a card can hold.
 *
 * A cut text says that it was cut, because an approval of half a command
 * is a claim about the command and not about the whole of it.
 */
export function bounded(value: string, limit: number): string {
  return value.length > limit ? `${value.slice(0, limit)}…` : value;
}

/** The tool call a permission request is about.
 *
 * The tool's own input is kept as it arrives and read where the evidence is
 * built:  a shape this file does not understand must not make the request
 * unreadable, because a request that is dropped leaves the engine waiting
 * on an answer that never comes.
 */
const PermissionToolCallSchema = z.object({
  toolCallId: z.string().optional(),
  title: z.string().optional(),
  kind: z.string().optional(),
  rawInput: z.unknown().optional(),
});

/**
 * The shape of a permission request as an engine sends it.
 *
 * The params arrive from the engine, so they are untrusted: the schema drops
 * what it does not recognise instead of letting a stray field reach the
 * client or the engine's answer.
 */
const PermissionParamsSchema = z
  .object({
    sessionId: z.string().optional(),
    toolCall: PermissionToolCallSchema.optional(),
    options: z
      .array(
        z.object({
          optionId: z.string().min(1),
          kind: z.string().default(""),
          name: z.string().default(""),
        }),
      )
      .optional(),
  })
  .loose();

/** Read the options out of a permission request, keeping only the usable ones. */
function parsePermissionOptions(value: unknown): PermissionOption[] {
  if (!Array.isArray(value)) return [];
  const options: PermissionOption[] = [];
  for (const entry of value) {
    if (typeof entry !== "object" || entry === null) continue;
    const record = entry as Record<string, unknown>;
    const optionId = readString(record.optionId);
    if (!optionId) continue;
    options.push({
      optionId,
      kind: readString(record.kind) ?? "",
      name: readString(record.name) ?? optionId,
    });
  }
  return options;
}

/**
 * The option the sidecar falls back to when nobody answers.
 *
 * It is the same allow-once the sidecar has always sent on its own, so a
 * client that never answers leaves the turn exactly as it was before.
 */
export function fallbackPermissionOption(options: PermissionOption[]): string | null {
  const allow = options.find((option) => option.kind === "allow_once");
  if (allow) return allow.optionId;
  const reject = options.find(
    (option) => option.kind === "reject_once" || option.kind === "reject_always",
  );
  return reject?.optionId ?? null;
}

/**
 * The options a host approval offers.
 *
 * The host asks one question with two answers, and the grant lasts for that
 * one call: it is the host's own vocabulary, so a card in the app offers the
 * same choice the web canvas does.
 */
const HOST_APPROVAL_OPTIONS: PermissionOption[] = [
  { optionId: "allow-once", kind: "allow_once", name: "Allow once" },
  { optionId: "reject", kind: "reject_once", name: "Reject" },
];

/**
 * The host's answer to the option a client picked.
 *
 * Anything that is not the grant is a refusal: the host has no other grant,
 * and a card that sends something the host does not understand would be
 * refused by the host anyway.
 */
function hostOutcomeFor(optionId: string | null): HostApprovalOutcome {
  return optionId === "allow-once" ? "allowed-once" : "rejected";
}

export function safeMuseBridgeError(error: unknown): string {
  if (error instanceof MuseSettingsError) return error.message;
  if (!error || typeof error !== "object") return "Muse request failed; retry or sign in to Muse.";
  const row = error as { message?: unknown; code?: unknown };
  const message = typeof row.message === "string" ? row.message : "";
  if (/log in to muse|not logged in|login required|not authenticated/i.test(message)) {
    return "Log in to Muse before opening a session.";
  }
  if (/(?:this\s+)?session (?:is )?(?:already being opened|already open|already in use|open in another process)|session (?:is )?open in another process|this muse thread is open in another process/i.test(message)) {
    return "This Muse thread is open in another process; choose another thread or wait until it is released.";
  }
  // A rate-limit refusal reads as what it is instead of a bare ACP code.
  // The copy keeps the "rate limit" words so re-sanitizing it maps to
  // itself, the way the session-conflict copy does.
  if (/rate limit|too many requests|quota exceeded|\b429\b/i.test(message)) {
    if (typeof row.code === "number" && Number.isSafeInteger(row.code)) {
      return `Muse rate limit reached (ACP code ${row.code}); wait a bit and retry.`;
    }
    return "Muse rate limit reached; wait a bit and retry.";
  }
  if (typeof row.code === "number" && Number.isSafeInteger(row.code)) {
    return `Muse request failed (ACP code ${row.code}).`;
  }
  return "Muse request failed; retry or sign in to Muse.";
}

const SessionOptionsResultSchema = z.object({
  configOptions: z.array(z.unknown()).optional(),
  modes: z.object({
    currentModeId: z.string(),
    availableModes: z.array(z.object({ id: z.string().min(1), name: z.string().optional() }).loose()).max(64),
  }).loose().optional(),
}).loose();

const BridgeErrorSchema = z.object({ message: z.unknown().optional(), code: z.unknown().optional() });
const BridgeMessageSchema = z.object({
  id: z.union([z.number(), z.string()]).optional(),
  method: z.string().optional(),
  params: z.record(z.string(), z.unknown()).optional(),
  result: z.unknown().optional(),
  error: BridgeErrorSchema.optional(),
});
const BridgeSessionUpdateParamsSchema = z.object({
  sessionId: z.string().min(1),
  update: z.object({
    sessionUpdate: z.string(),
    _meta: z.record(z.string(), z.unknown()).optional(),
  }).loose(),
}).loose();
const BridgeInitializationSchema = z.object({
  _meta: z.record(z.string(), z.unknown()).optional(),
  authMethods: z.array(z.unknown()).optional(),
});
const BridgeAuthMethodSchema = z.object({ id: z.string().min(1), name: z.string().optional().catch(undefined), description: z.string().optional().catch(undefined) });
const MuseSteeringCapabilitySchema = z.object({ version: z.literal(1), method: z.literal("_muse/steer") });
const MuseSteeringResultSchema = z.object({ status: z.literal("accepted") });
const BridgePromptResultSchema = z.object({ stopReason: z.string().optional().default("endTurn") });
const MuseSteerBodySchema = z.object({ sessionId: z.string().trim().min(1), text: z.string().trim().min(1).max(4000) });

/** Minimal JSON-RPC client over a bridge launcher's stdio. */
export class Bridge implements MuseAuthBridge {
  private child: ChildProcess | null = null;
  private initialized: Promise<unknown> | null = null;
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private onUpdate: ((u: AcpUpdate) => void) | null = null;
  private onProcessFailure: (() => void) | null = null;
  private onPermission: ((request: PermissionRequest) => void) | null = null;
  private onUrlElicitation: ((elicitation: MuseUrlElicitation) => boolean) | null = null;
  private onElicitationComplete: ((elicitationId: string) => void) | null = null;
  private offeredAuthMethods: Array<{ id: string; name?: string; description?: string }> = [];
  private steeringMethod: string | null = null;
  private activeTurnIds = new Map<string, string>();
  private advertisedConfigOptions: unknown[] | null = null;
  private advertisedModelMetadata: SessionModelMetadata | null = null;
  private sessionModelMetadata = new Map<string, SessionModelMetadata>();
  private pendingPermissions = new Map<
    string,
    { bridgeRequestId: number | string; options: PermissionOption[] }
  >();
  private buffer = "";
  private museLaunchOptions: MuseLaunchOptions | null = null;
  private reconfiguration: Promise<boolean> | null = null;
  private retiringChild: ChildProcess | null = null;
  private sessionModes = new Map<string, z.infer<typeof SessionOptionsResultSchema>["modes"]>();
  private baseLauncher: Launcher;
  private baseEnv: NodeJS.ProcessEnv;
  private museContexts = new Map<string, ContextUsage & { revision: number }>();
  private museCompactCommands = new Map<string, boolean>();
  private lastCompactedRevision = new Map<string, number>();

  constructor(
    readonly engine: Engine,
    private env: NodeJS.ProcessEnv,
    private launcher: Launcher = LAUNCHERS[engine],
  ) {
    this.baseLauncher = { command: launcher.command, args: [...launcher.args] };
    this.baseEnv = { ...env };
  }

  /** Reconfigure only after the caller has checked that no other Muse turn is active. */
  matchesMuseLaunchOptions(options: MuseLaunchOptions | null): boolean {
    return this.museLaunchOptions === null || options === null
      ? this.museLaunchOptions === options
      : sameMuseLaunchOptions(this.museLaunchOptions, options);
  }

  configureMuseLaunch(options: MuseLaunchOptions | null): Promise<boolean> {
    if (this.engine !== "muse") return Promise.resolve(false);
    if (options && this.baseEnv.MUSE_CODE_ACP_BACKEND === "adapter") return Promise.reject(new MuseSettingsError("native"));
    if (this.reconfiguration) return Promise.reject(new MuseSettingsError("busy"));
    if (this.matchesMuseLaunchOptions(options)) return Promise.resolve(false);
    if (this.pending.size > 0) return Promise.reject(new MuseSettingsError("busy"));
    const configure = async (): Promise<boolean> => {
      const child = this.child;
      if (child) {
        this.retiringChild = child;
        try {
          await new Promise<void>((resolve, reject) => {
            const timer = setTimeout(() => { child.removeListener("close", closed); reject(new MuseSettingsError("restart")); }, 10_000);
            const closed = (): void => { clearTimeout(timer); resolve(); };
            child.once("close", closed);
            if (!child.kill("SIGTERM")) { clearTimeout(timer); child.removeListener("close", closed); reject(new MuseSettingsError("restart")); }
          });
        } finally {
          this.retiringChild = null;
        }
      }
      this.launcher = { command: this.baseLauncher.command, args: [...this.baseLauncher.args, ...(options ? museLaunchArguments(options) : [])] };
      this.env = options ? { ...this.baseEnv, MUSE_CODE_ACP_REQUIRE_NATIVE: "1" } : { ...this.baseEnv };
      this.museLaunchOptions = options ? { ...options } : null;
      this.sessionModes.clear();
      this.sessionModelMetadata.clear();
      return true;
    };
    const pending = configure().finally(() => { this.reconfiguration = null; });
    this.reconfiguration = pending;
    return pending;
  }

  async applyMuseApprovalMode(sessionId: string, yolo: boolean): Promise<void> {
    const modes = this.sessionModes.get(sessionId);
    const acceptedIds = yolo ? ["allowAll", "yolo"] : ["onRequest", "default"];
    const requested = acceptedIds.find((id) => modes?.availableModes.some((mode) => mode.id === id));
    if (!modes || !requested) throw new MuseSettingsError("mode");
    if (modes.currentModeId === requested) return;
    try {
      await this.send("session/set_mode", { sessionId, modeId: requested });
      this.sessionModes.set(sessionId, { ...modes, currentModeId: requested });
    } catch {
      throw new MuseSettingsError("mode");
    }
  }

  hasMuseApprovalModes(sessionId: string): boolean {
    return this.sessionModes.has(sessionId);
  }

  contextControls(sessionId: string): { supportsCompaction: boolean; contextUsedTokens?: number; contextWindow?: number } {
    const context = this.museContexts.get(sessionId);
    return {
      supportsCompaction: this.museCompactCommands.get(sessionId) === true,
      ...(context ? { contextUsedTokens: context.used, contextWindow: context.size } : {}),
    };
  }

  takeEarlyCompaction(sessionId: string, policy: ContextPolicy): boolean {
    const context = this.museContexts.get(sessionId);
    const should = shouldCompactEarly({
      policy, context,
      compactAvailable: this.museCompactCommands.get(sessionId) ?? null,
      currentRevision: context?.revision ?? null,
      lastCompactedRevision: this.lastCompactedRevision.get(sessionId) ?? null,
    });
    if (should && context) this.lastCompactedRevision.set(sessionId, context.revision);
    return should;
  }

  /** Options from the latest successful user session/new or session/load. */
  catalogOptions(): unknown[] | null {
    return this.advertisedConfigOptions;
  }

  modelMetadata(sessionId: string): SessionModelMetadata | null {
    const metadata = this.sessionModelMetadata.get(sessionId);
    return metadata ? { ...metadata } : null;
  }

  steeringSupported(): boolean {
    return this.engine === "muse" && this.steeringMethod === "_muse/steer";
  }

  private rememberSessionOptions(result: unknown, sessionId?: string): void {
    const parsed = SessionOptionsResultSchema.safeParse(result);
    this.advertisedConfigOptions = parsed.success ? parsed.data.configOptions ?? [] : [];
    this.advertisedModelMetadata = this.engine === "muse"
      ? modelMetadataFromMuseConfigOptions(this.advertisedConfigOptions)
      : null;
    if (sessionId && parsed.success && Array.isArray(parsed.data.configOptions)) {
      if (this.advertisedModelMetadata) this.sessionModelMetadata.set(sessionId, { ...this.advertisedModelMetadata });
      else this.sessionModelMetadata.delete(sessionId);
    }
    if (sessionId && parsed.success && parsed.data.modes) this.sessionModes.set(sessionId, parsed.data.modes);
  }

  setUpdateHandler(fn: (u: AcpUpdate) => void): void {
    this.onUpdate = fn;
  }

  setProcessFailureHandler(fn: () => void): void {
    this.onProcessFailure = fn;
  }

  /**
   * Take over permission requests.
   *
   * Without a handler the sidecar answers them itself, the way it always
   * has.  With one, the request waits for the client's answer.
   */
  setPermissionHandler(fn: (request: PermissionRequest) => void): void {
    this.onPermission = fn;
  }

  setUrlElicitationHandler(handler: ((elicitation: MuseUrlElicitation) => boolean) | null): void {
    this.onUrlElicitation = handler;
  }

  setElicitationCompleteHandler(handler: ((elicitationId: string) => void) | null): void {
    this.onElicitationComplete = handler;
  }

  authMethods(): Array<{ id: string; name?: string; description?: string }> {
    return this.offeredAuthMethods.map((method) => ({ ...method }));
  }

  /**
   * Answer a permission request the engine is waiting on.
   *
   * `optionId` picks one of the options the engine offered; null cancels the
   * request.  An option the engine never offered is refused rather than
   * forwarded: a stale card or a mismatched client must not be able to stall
   * the blocked turn with an id the engine will reject.  A request that is
   * already gone is reported as unanswered, so a late answer is harmless
   * rather than an error.
   */
  answerPermission(requestId: string, optionId: string | null): boolean {
    const pending = this.pendingPermissions.get(requestId);
    if (!pending) return false;
    if (optionId !== null && !pending.options.some((option) => option.optionId === optionId)) {
      return false;
    }
    this.pendingPermissions.delete(requestId);
    const outcome = optionId
      ? { outcome: "selected", optionId }
      : { outcome: "cancelled" };
    this.child?.stdin?.write(
      `${JSON.stringify({ jsonrpc: "2.0", id: pending.bridgeRequestId, result: { outcome } })}\n`,
    );
    return true;
  }

  private spawn(): void {
    const launcher = this.launcher;
    if (launcher.command.includes("/") && !existsSync(launcher.command)) {
      throw new Error(`missing launcher ${launcher.command}`);
    }
    const child = spawn(launcher.command, launcher.args, {
      stdio: ["pipe", "pipe", this.engine === "muse" ? "ignore" : "inherit"],
      env: this.engine === "zcode" ? zcodeSpawnEnv(this.env) : this.env,
    });
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
    this.offeredAuthMethods = [];
    this.advertisedConfigOptions = null;
    this.advertisedModelMetadata = null;
    this.steeringMethod = null;
    this.activeTurnIds.clear();
    this.sessionModes.clear();
    this.sessionModelMetadata.clear();
    this.museContexts.clear();
    this.museCompactCommands.clear();
    this.lastCompactedRevision.clear();
    // Drop any partial line left by a mid-line crash; the next spawn starts
    // fresh instead of framing new stdout onto the old fragment.
    this.buffer = "";
    if (this.retiringChild !== child) this.onProcessFailure?.();
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
      let raw: unknown;
      try {
        raw = JSON.parse(line);
      } catch {
        continue;
      }
      const parsedMessage = BridgeMessageSchema.safeParse(raw);
      if (!parsedMessage.success) continue;
      const msg = parsedMessage.data;
      if (msg.method === "elicitation/create" && msg.id !== undefined) {
        const params = msg.params ?? {};
        const elicitation: MuseUrlElicitation = {
          requestId: msg.id,
          elicitationId: typeof params.elicitationId === "string" ? params.elicitationId : "",
          url: typeof params.url === "string" ? params.url : "",
          message: typeof params.message === "string" ? params.message : "",
        };
        if (this.engine === "muse" && params.mode === "url" && this.onUrlElicitation?.(elicitation)) continue;
        this.child?.stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", id: msg.id, error: { code: -32602, message: "unsupported elicitation" } })}\n`);
        continue;
      }
      if (msg.method === "elicitation/complete") {
        const elicitationId = typeof msg.params?.elicitationId === "string" ? msg.params.elicitationId : "";
        if (elicitationId) this.onElicitationComplete?.(elicitationId);
        continue;
      }
      if (msg.method === "session/request_permission" && msg.id !== undefined) {
        this.holdPermissionRequest(msg.id, msg.params ?? {});
        continue;
      }
      if (msg.method && msg.id !== undefined) {
        this.child?.stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method not supported" } })}\n`);
        continue;
      }
      if (msg.method === "session/update") {
        const parsedParams = BridgeSessionUpdateParamsSchema.safeParse(msg.params);
        if (!parsedParams.success) continue;
        const params = parsedParams.data;
        if (this.engine === "muse" && typeof params.sessionId === "string") {
          const context = contextUsageFromUpdate(params.update);
          if (context) {
            const previous = this.museContexts.get(params.sessionId);
            this.museContexts.set(params.sessionId, {
              ...context,
              revision: previous && previous.used === context.used && previous.size === context.size
                ? previous.revision : (previous?.revision ?? 0) + 1,
            });
          }
          const compact = compactAvailabilityFromUpdate(params.update);
          if (compact !== null) this.museCompactCommands.set(params.sessionId, compact);
        }
        if (this.engine === "muse" && typeof params?.sessionId === "string" &&
            params.update?.sessionUpdate === "session_info_update") {
          const meta = params.update._meta;
          if (meta) {
            const turnId = meta["muse/activeTurnId"];
            if (typeof turnId === "string" && turnId.length > 0) this.activeTurnIds.set(params.sessionId, turnId);
            else if (turnId === null) this.activeTurnIds.delete(params.sessionId);
          }
        }
        const update = normalizeSessionUpdate(msg.params);
        if (update) this.onUpdate?.(update);
        continue;
      }
      if (typeof msg.id === "number") {
        const p = this.pending.get(msg.id);
        if (!p) continue;
        this.pending.delete(msg.id);
        if (msg.error) {
          if (this.engine === "muse") {
            const error = new Error(safeMuseBridgeError(msg.error));
            attachMuseErrorDiagnostics(error, msg.error);
            attachMuseAuthFailure(error, msg.error);
            if (typeof msg.error.code === "number" && Number.isSafeInteger(msg.error.code)) {
              Object.assign(error, { code: msg.error.code });
            }
            p.reject(error);
          } else {
            p.reject(new Error(String(msg.error.message ?? "bridge error")));
          }
        }
        else p.resolve(msg.result);
      }
    }
  }

  /**
   * Hold a permission request until the client answers it.
   *
   * The engine waits for an answer, so the request is handed up and the
   * answer goes back the same way.  The request is registered before it is
   * handed up, so the no-handler fallback below can answer it: without that,
   * the engine would sit blocked on a request nobody ever replies to.  With
   * no handler attached the sidecar answers it itself, exactly as it did
   * before, so a caller that never asked for this feature sees no change.
   */
  private holdPermissionRequest(id: number | string, params: Record<string, unknown>): void {
    // A request the engine sent in a shape this file does not understand is
    // still a request the engine is blocked on, so it is held and answered
    // rather than dropped:  a dropped request leaves the engine waiting.
    const parsed = PermissionParamsSchema.safeParse(params);
    const data: z.infer<typeof PermissionParamsSchema> = parsed.success ? parsed.data : {};
    const options = parsePermissionOptions(data.options);
    const toolCall: z.infer<typeof PermissionToolCallSchema> = data.toolCall ?? {};
    const title = readString(toolCall.title) ?? "";
    const evidence = buildPermissionEvidence(toolCall.rawInput);
    const request: PermissionRequest = {
      requestId: `perm-${(permissionCounter += 1)}`,
      sessionId: readString(data.sessionId) ?? "",
      title,
      toolName: readString(toolCall.kind) ?? (title || "Tool call"),
      options,
      ...(evidence ? { evidence } : {}),
    };
    this.pendingPermissions.set(request.requestId, { bridgeRequestId: id, options });
    if (!this.onPermission) {
      this.answerPermission(request.requestId, fallbackPermissionOption(options));
      return;
    }
    this.onPermission(request);
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
    if (this.reconfiguration) return this.reconfiguration.then(() => this.initialize());
    if (!this.initialized) {
      const initialization = this.send("initialize", {
        protocolVersion: 1,
        clientCapabilities: {
          fs: { readTextFile: false, writeTextFile: false },
          ...(this.engine === "muse" ? {
            elicitation: { url: {} },
            _meta: { "muse/steering": 1 },
          } : {}),
        },
      });
      const tracked = initialization.then((result) => {
        const parsedInitialization = BridgeInitializationSchema.safeParse(result);
        if (this.engine === "muse" && parsedInitialization.success) {
          const response = parsedInitialization.data;
          const steering = MuseSteeringCapabilitySchema.safeParse(response._meta?.["muse/steering"]);
          this.steeringMethod = steering.success
            ? "_muse/steer"
            : null;
          const raw = response.authMethods;
          this.offeredAuthMethods = Array.isArray(raw)
            ? raw.flatMap((item) => {
                const parsedMethod = BridgeAuthMethodSchema.safeParse(item);
                if (!parsedMethod.success) return [];
                const row = parsedMethod.data;
                return [{
                  id: row.id,
                  ...(typeof row.name === "string" ? { name: row.name.slice(0, 200) } : {}),
                  ...(typeof row.description === "string" ? { description: row.description.slice(0, 500) } : {}),
                }];
              })
            : [];
        }
        return result;
      }).catch((error) => {
        if (this.initialized === tracked) this.initialized = null;
        throw error;
      });
      this.initialized = tracked;
    }
    return this.initialized;
  }

  authenticate(methodId: string): Promise<unknown> {
    if (this.engine !== "muse" || !this.offeredAuthMethods.some((method) => method.id === methodId)) {
      return Promise.reject(new Error("unsupported Muse authentication method"));
    }
    return this.send("authenticate", { methodId });
  }

  answerElicitation(requestId: number | string, action: "accept" | "cancel"): boolean {
    if (!this.child?.stdin) return false;
    try {
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: requestId, result: { action } })}\n`);
      return true;
    } catch {
      return false;
    }
  }

  async newSession(cwd: string): Promise<string> {
    const result = (await this.send("session/new", { cwd, mcpServers: [] })) as { sessionId?: unknown };
    if (typeof result?.sessionId !== "string" || result.sessionId.length === 0) {
      throw new Error("bridge returned no sessionId");
    }
    this.rememberSessionOptions(result, result.sessionId);
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
    const previousModel = this.sessionModelMetadata.get(sessionId)?.model;
    try {
      const result = await this.send("session/set_config_option", { sessionId, configId, value });
      const parsed = SessionOptionsResultSchema.safeParse(result);
      if (parsed.success && Array.isArray(parsed.data.configOptions)) this.rememberSessionOptions(result, sessionId);
      if (this.engine === "muse" && configId === "model" &&
          previousModel !== (museContributorModelId(value) ?? value)) {
        this.museContexts.delete(sessionId);
        this.lastCompactedRevision.delete(sessionId);
      }
      return true;
    } catch {
      return false;
    }
  }

  async listSessions(cwd?: string, limit: number = 100): Promise<AcpSessionInfo[]> {
    const cap = Math.min(Math.max(Math.trunc(limit) || 100, 1), 5_000);
    const sessions: AcpSessionInfo[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 100; page += 1) {
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
          ...(typeof row.provider === "string" ? { provider: row.provider } : {}),
          ...(typeof row.model === "string" ? { model: row.model } : {}),
        });
        if (sessions.length >= cap) break;
      }
      if (sessions.length >= cap) break;
      if (typeof result.nextCursor !== "string" || result.nextCursor.length === 0) break;
      cursor = result.nextCursor;
    }
    return sessions;
  }

  async loadSession(sessionId: string, cwd: string): Promise<unknown> {
    const result = await this.send("session/load", { sessionId, cwd, mcpServers: [] });
    this.rememberSessionOptions(result, sessionId);
    return result;
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
    this.activeTurnIds.delete(sessionId);
    // ACP agents take content blocks; the dsh bridges take a plain string.
    // Muse Code rejects a bare string ("Invalid params"), so the code
    // engines get the block form every time.
    let prompt: unknown = text;
    if (CODE_ENGINES.includes(this.engine)) {
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
    return BridgePromptResultSchema.parse(await this.send("session/prompt", { sessionId, prompt }));
  }

  cancel(sessionId: string): void {
    this.send("session/cancel", { sessionId }).catch(() => undefined);
  }

  async steer(sessionId: string, text: string): Promise<void> {
    if (this.engine !== "muse" || this.steeringMethod !== "_muse/steer") {
      throw new MuseSteeringError("unsupported");
    }
    if (!this.child || !this.initialized) throw new MuseSteeringError("inactive");
    const expectedTurnId = this.activeTurnIds.get(sessionId);
    if (!expectedTurnId) throw new MuseSteeringError("idle");
    let result: unknown;
    try {
      result = await this.send(this.steeringMethod, {
        sessionId,
        expectedTurnId,
        prompt: [{ type: "text", text }],
      });
    } catch (error) {
      const parsedError = BridgeErrorSchema.safeParse(error);
      const code = parsedError.success ? parsedError.data.code : undefined;
      if (code === -32600) throw new MuseSteeringError("stale", code);
      throw error;
    }
    if (!MuseSteeringResultSchema.safeParse(result).success) {
      throw new Error("Muse did not accept the steering request");
    }
  }

  clearActiveTurn(sessionId: string): void {
    this.activeTurnIds.delete(sessionId);
  }
}

interface ChatSession {
  engine: Engine;
  bridgeSessionId: string;
  resumeSessionId: string | null;
  cwd: string;
  busy: boolean;
  diagnostics?: TurnDiagnosticHandle;
  stream: ((u: AcpUpdate) => void) | null;
  /** The model this session runs, as the client asked for it. */
  model?: string;
  /** The provider and model the backend reports for this remote thread. */
  modelMetadata?: SessionModelMetadata;
  /** The reasoning effort this session runs, as the client asked for it. */
  effort?: string;
  /** The permission requests this turn is waiting on. */
  permission?: ((request: PermissionRequest) => void) | null;
  /** The fallback timers for those requests, so a late answer is not a second one. */
  permissionTimers: Map<string, ReturnType<typeof setTimeout>>;
  /**
   * The permission requests this turn owns, by request id.
   *
   * The ids are process-wide and predictable, so an answer is only accepted
   * when the request it names is one this turn raised: otherwise a stale card
   * could answer another turn's question.
   */
  pendingPermissions: Map<string, PermissionRequest>;
  /**
   * How this turn answers a permission request.
   *
   * A turn runs either on an ACP bridge or inside the dsh host, and each has
   * its own way of receiving the answer, so the turn holds the one that
   * applies to it.  A turn with none cannot answer, and its requests are
   * let go instead.
   */
  answerPermission?: ((requestId: string, optionId: string | null) => boolean | Promise<boolean>) | null;
  /**
   * The host approvals this turn is waiting on, by the id the client sees.
   *
   * The host's own id is kept beside the client's, because the answer has to
   * name the question the host asked and not the card on the screen.
   */
  hostApprovals: Map<string, HostApproval>;
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
    title: z.string().max(512).nullable().optional(),
  })
  .strict()
  .refine((v) => v.projectId !== undefined || v.archived !== undefined || v.title !== undefined, { message: "nothing to update" });

/** Most sessions enriched with log-derived usage per list request. */
const USAGE_ENRICH_CAP = 50;

/** Saved Muse names apply to the entire returned page, independently of the
 * cap on usage and model enrichment. Older rows use a separate compact name read. */
export async function enrichMuseSessionPage(
  rows: readonly AcpSessionInfo[],
  readSummary: typeof readMuseSessionSummary = readMuseSessionSummary,
  readName: typeof readMuseSessionName = readMuseSessionName,
): Promise<AcpSessionInfo[]> {
  return mapWithConcurrency(rows, 4, async (row, index) => {
    const summary = index < USAGE_ENRICH_CAP ? await readSummary(row.sessionId) : null;
    const { title: listedTitle, ...session } = row;
    const name = index < USAGE_ENRICH_CAP ? summary?.name : await readName(row.sessionId);
    const title = museDisplayTitle(name, listedTitle);
    const includeUsage = summary !== null;
    const usage = includeUsage ? museSessionUsage(summary) : null;
    return {
      ...session,
      ...(title ? { title } : {}),
      ...(includeUsage && summary.modelId ? { model: summary.modelId } : {}),
      ...(includeUsage && summary.providerId ? { provider: summary.providerId } : {}),
      ...(usage ? { usage } : {}),
    };
  });
}


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

/**
 * The inbound headers the sidecar reads.
 *
 * A header arrives from the network, so it is parsed before any of it is
 * believed: a value that is not a string is a malformed request, not a
 * value to guess at on the way to the authentication branch.  The schema
 * strips the rest, so the sidecar works with the headers it names and
 * nothing else.
 */
const InboundHeadersSchema = z
  .object({
    host: z.string().optional(),
    authorization: z.string().optional(),
    cookie: z.string().optional(),
  })
  .strip();

/** The headers the sidecar reads, once they have been parsed. */
export interface InboundHeaders {
  /** The authority the client addressed. */
  host?: string | undefined;
  /** The Bearer credential the client sent. */
  authorization?: string | undefined;
  /** The cookies the client sent; parsed here so no header goes unparsed. */
  cookie?: string | undefined;
}

/**
 * The parsed inbound headers, or the reason the request is refused.
 *
 * This is the trust boundary: everything after it works with the parsed
 * headers alone, so a value that did not survive the schema never reaches
 * the host check or the authentication branch.
 */
export function parseInboundHeaders(
  headers: unknown,
): { ok: true; headers: InboundHeaders } | { ok: false; error: string } {
  const parsed = InboundHeadersSchema.safeParse(headers);
  if (!parsed.success) return { ok: false, error: "malformed request headers" };
  return { ok: true, headers: parsed.data };
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

/**
 * Wait for a promise, but not forever.
 *
 * A host that does not answer must not hold the island's state back:  the
 * thread keeps its fallback title and the push still goes out.
 */
async function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error("the host did not answer in time")), ms);
    timer.unref?.();
  });
  try {
    return await Promise.race([work, timeout]);
  } finally {
    if (timer) clearTimeout(timer);
    // A late answer is not an error:  the race has already settled.
    void work.catch(() => undefined);
  }
}

async function main(): Promise<void> {
  const token = loadOrMintToken();
  // Clutch's own settings (Infisical is the sole source of truth).  The bridge
  // is a separate process from start-web.ts, so it initializes its own
  // instance; this is what backs the native Infisical settings panel.
  const settings = await initClutchSettings();
  // The drop-in engine plugins, read once at boot.  A plugin that maps to an
  // engine Clutch runs contributes to the catalog; one that maps to no known
  // engine is reported rather than turned into a phantom picker entry, and
  // one that does not load contributes nothing.  A new drop-in needs a
  // restart of the sidecar to show up.
  const pluginReport: EnginePluginReport = await loadEnginePluginReport();
  for (const unmapped of pluginReport.unmapped) {
    log(`engine plugin "${unmapped.id}" names no engine Clutch runs — it is not in the picker`);
  }
  for (const problem of pluginReport.problems) {
    log(`engine plugin ${problem.file} did not load — it contributes nothing`);
  }
  const diagnostics = createTurnDiagnostics({
    directory: join(dirname(TOKEN_FILE), "diagnostics"),
    endpoint: settings.get("CLUTCH_TELEMETRY_ENDPOINT"),
    authorization: settings.get("CLUTCH_TELEMETRY_AUTHORIZATION"),
  });
  void diagnostics.flush();
  const tokenFingerprint = createHash("sha256").update(token).digest("hex").slice(0, 12);
  const tailnetHost = await detectTailnetHost();
  if (!tailnetHost) log("no tailnet host detected; remote (Tailscale) requests will 403 until tailscale is up — set CLUTCH_TAILNET_HOST to override");
  const extraHosts = (process.env.CLUTCH_TRUSTED_HOSTS ?? "").split(",");
  const ipv4 = process.env.CLUTCH_TAILNET_IPV4?.trim() || null;
  const allowed = trustedAuthoritySet([tailnetHost, ipv4, ...extraHosts], String(PORT));

  const bridges = new Map<Engine, Bridge>();
  const sessions = new Map<string, ChatSession>();
  /**
   * Tells the Live Activity relay that the sidecar's knowledge moved.
   *
   * The relay pushes what the island shows, so every place the waiting or the
   * running work changes is a place the phone has to hear about:  an approval
   * arrived, one was answered, a turn started, a turn ended.
   */
  function notifyActivityPush(): void {
    // Coalesce bursts before snapshotting:  the relay keeps one push per
    // interval, so concurrent notifies would repeat session scans whose
    // results are then dropped.  One trailing retry keeps the final state.
    const state = notifyActivityPush as unknown as { pending?: boolean; queued?: boolean };
    if (state.pending) {
      state.queued = true;
      return;
    }
    state.pending = true;
    // A push is a courtesy to the island, never a turn failure:  the relay
    // swallows its own errors, and this catch is the backstop that keeps a
    // surprise from surfacing as an unhandled rejection in the sidecar.
    const settled = activityPush.notify().catch(() => undefined).finally(() => {
      state.pending = false;
      if (state.queued) {
        state.queued = false;
        notifyActivityPush();
      }
    });
    void settled;
  }
  const knownModelMetadata = new Map<string, SessionModelMetadata>();
  // Fallback supplied by the Muse ACP catalog, never Clutch-local metadata.
  const museListedTitles = new Map<string, string>();
  function rememberMuseListedTitles(rows: readonly AcpSessionInfo[]): void {
    for (const row of rows) {
      museListedTitles.delete(row.sessionId);
      const title = museDisplayTitle(undefined, row.title);
      if (title) museListedTitles.set(row.sessionId, title.slice(0, 512));
    }
    while (museListedTitles.size > 5_000) museListedTitles.delete(museListedTitles.keys().next().value!);
  }
  const modelMetadataKey = (engine: Engine, remoteSessionId: string): string => `${engine}\u0000${remoteSessionId}`;
  const rememberModelMetadata = (engine: Engine, remoteSessionId: string, metadata: SessionModelMetadata | null): void => {
    if (!metadata || (!metadata.provider && !metadata.model)) return;
    const key = modelMetadataKey(engine, remoteSessionId);
    knownModelMetadata.set(key, { ...knownModelMetadata.get(key), ...metadata });
  };
  let museAuth: MuseAuthController | null = null;
  // The operator's permission posture wins, so the sidecar does not force
  // one over the top of it: `danger-full-access` (the default) means the
  // engine never asks, and anything else means it asks and the native app
  // answers.
  const bridgeEnv: Record<string, string | undefined> = {
    ...process.env,
    CLUTCH_RUNTIME_ROOT: ROOT,
    DSH_PERMISSION_MODE: process.env.DSH_PERMISSION_MODE ?? "danger-full-access",
  };
  // The APNs signing key is the sidecar's own business:  it is read from the
  // settings cache, and it must not ride into every engine the sidecar
  // spawns.  The two ids are names rather than secrets, and they are the
  // relay's business too, so the whole trio is stripped here.
  delete bridgeEnv.APNS_KEY_P8_BASE64;
  delete bridgeEnv.APNS_KEY_ID;
  delete bridgeEnv.APNS_TEAM_ID;
  // CometChat relay is additive: SSE stays the primary transport, and the
  // relay only runs when the backend is configured AND the caller names a
  // target. Backend-only key; never leaves this process.
  const ccConfig = cometchatConfigFromEnv();
  const ccRelay = ccConfig ? new CometChatRelay(ccConfig, { onLog: log }) : null;
  if (ccRelay) log("cometchat relay armed");

  function bridgeFor(engine: Engine): Bridge {
    let b = bridges.get(engine);
    if (!b) {
      const created = new Bridge(engine, bridgeEnv);
      b = created;
      b.setUpdateHandler((u) => {
        const target = [...sessions.values()].find((s) => s.engine === engine && s.bridgeSessionId === u.sessionId && s.busy);
        target?.stream?.(u);
      });
      b.setProcessFailureHandler(() => {
        for (const session of sessions.values()) {
          if (session.engine === engine) session.bridgeSessionId = "";
        }
        if (engine === "muse") museAuth?.bridgeFailed();
      });
      // A permission request belongs to the turn that asked for it, so it is
      // routed the same way an update is: by the ACP session that raised it.
      // A turn whose client cannot answer is answered here, the way the
      // sidecar has always answered them.
      b.setPermissionHandler((request) => {
        const target = [...sessions.values()].find(
          (s) => s.engine === engine && s.bridgeSessionId === request.sessionId && s.busy,
        );
        if (target?.permission) {
          // The turn owns the request from here on, so an answer is only
          // accepted when it names a request this turn raised.
          target.pendingPermissions.set(request.requestId, request);
          notifyActivityPush();
          target.permission(request);
          return;
        }
        created.answerPermission(request.requestId, fallbackPermissionOption(request.options));
      });
      bridges.set(engine, b);
    }
    return b;
  }

  museAuth = new MuseAuthController(bridgeFor("muse"));

  /**
   * The dsh host client, created on first use.
   *
   * The host is only needed for the engines it owns, so a machine that runs
   * only the code engines never opens a connection to it.
   */
  const hostClient = new DshHostClientCache(() => DshHostClient.connect(), Date.now, HOST_RETRY_COOLDOWN_MS);

  /**
   * The cached host client, for callers that hold it across a turn or a relay.
   * Opening goes through the cache, so the retry cooldown still applies.
   */
  async function openDshHost(): Promise<DshHostClient> {
    return hostClient.run(async (client) => client);
  }

  /**
   * Whether the dsh host answers.
   *
   * The host owns the dsh-hosted engines, so the picker has to know which
   * path a turn would take: the host, or the Python bridge that is the
   * fallback.  The client is cached, so the probe costs nothing once a host
   * has answered once, and it is bounded so a host that never answers
   * cannot hold the catalog back.
   */
  async function hostAnswers(): Promise<boolean> {
    let timer: NodeJS.Timeout | undefined;
    try {
      await Promise.race([
        hostClient.run(async (client) => client),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error("the dsh host did not answer in time")), HOST_PROBE_TIMEOUT_MS);
          timer.unref?.();
        }),
      ]);
      return true;
    } catch {
      return false;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  /**
   * The sidecar's end of the host's approval channel.
   *
   * The relay is opened once and kept open, because the host asks every
   * connected client at once: the sidecar has to be listening before the turn
   * that will be asked has started.
   */
  let approvalRelay: DshHostApprovalRelay | null = null;
  async function hostApprovals(): Promise<DshHostApprovalRelay> {
    if (approvalRelay) return approvalRelay;
    const relay = DshHostApprovalRelay.start({
      client: () => openDshHost(),
      onClientError: (client, error) => hostClient.noteFailure(client, error),
      onApproval: (approval) => routeHostApproval(approval),
      onSettled: (eventId) => settleHostApproval(eventId),
      onLog: (message) => log(message),
    });
    approvalRelay = relay;
    return relay;
  }

  /**
   * The host id the island's threads are keyed by.
   *
   * The phone keys a thread by the host and the session, because two hosts
   * can hold a session with the same id.  The sidecar is one host, so its
   * threads share one id.
   */
  const ACTIVITY_HOST_ID = "local";

  /** How long the host's own thread titles are kept before they are read again. */
  const ACTIVITY_TITLE_TTL_MS = 20_000;

  /** How long the host has to answer a title request. */
  const ACTIVITY_TITLE_TIMEOUT_MS = 2_000;

  /** The title a thread has when nothing else names it. */
  const ACTIVITY_FALLBACK_TITLE = "Thread";

  /**
   * The names of the threads, as the phone would show them.
   *
   * The phone's title is the one Clutch stores for the thread, and the host's
   * own title is the fallback:  the same two sources the sidecar's session
   * list reads, so the island says what the thread list says.  The host's
   * titles cost a call and change slowly, so they are cached.
   */
  let activityTitleCache: { at: number; titles: Map<string, string> } | null = null;
  async function activityThreadTitles(ids: string[]): Promise<Map<string, string>> {
    const titles = new Map<string, string>();
    const meta = loadSessionMeta(SESSION_META_FILE);
    for (const id of ids) {
      const title = meta.sessions[id]?.title;
      if (title) titles.set(id, title);
    }
    const missing = ids.filter((id) => !titles.has(id));
    if (missing.length === 0) return titles;
    const now = Date.now();
    if (!activityTitleCache || now - activityTitleCache.at > ACTIVITY_TITLE_TTL_MS) {
      const cache = { at: now, titles: new Map<string, string>() };
      activityTitleCache = cache;
      try {
        const listed = await withTimeout(
          hostClient.run((client) => listDshHostSessions(client, { limit: 200 })),
          ACTIVITY_TITLE_TIMEOUT_MS,
        );
        for (const row of listed) {
          if (row.title) cache.titles.set(row.sessionId, row.title);
        }
      } catch {
        /* the host is not answering:  the thread keeps its fallback title */
      }
    }
    for (const id of missing) {
      const title = activityTitleCache?.titles.get(id);
      if (title) titles.set(id, title);
    }
    return titles;
  }

  /**
   * The work the island shows.
   *
   * The sidecar's own knowledge:  the turns it is running and the approvals
   * they are waiting on.  A thread waiting on the owner is blocked rather
   * than working, so the split counts it once, as waiting; and a thread that
   * waits on two requests is one thread and one row.
   *
   * The title is the thread's name.  The tool a request is about, the reason
   * it gives and the directory it runs in never reach this state, because
   * the island shows without being opened.
   */
  async function activitySnapshot(): Promise<ActivitySnapshot> {
    const threadIds = new Set<string>();
    for (const session of sessions.values()) {
      const threadId = session.resumeSessionId ?? session.bridgeSessionId;
      if (threadId) threadIds.add(threadId);
    }
    const titles = await activityThreadTitles([...threadIds]);
    const approvals: ActivityThreadApproval[] = [];
    const runs: ActivityThreadRun[] = [];
    const running = new Set<string>();
    for (const session of sessions.values()) {
      const threadId = session.resumeSessionId ?? session.bridgeSessionId;
      if (!threadId) continue;
      const title = titles.get(threadId) ?? ACTIVITY_FALLBACK_TITLE;
      for (const request of session.pendingPermissions.values()) {
        approvals.push({
          hostId: ACTIVITY_HOST_ID,
          sessionId: threadId,
          requestId: request.requestId,
          title,
        });
      }
      if (!session.busy) continue;
      // One row per thread:  two turns on one thread are one thread.
      if (running.has(threadId)) continue;
      running.add(threadId);
      runs.push({ hostId: ACTIVITY_HOST_ID, sessionId: threadId, title });
    }
    return { approvals, runs };
  }

  /**
   * The relay that keeps a backgrounded phone's Live Activity current.
   *
   * It is part of the sidecar:  no daemon, no second process and no new
   * port.  It pushes only when the APNs settings are all there, and the
   * registrations are accepted either way, so a phone that paired before the
   * key was in place is ready when it is.
   */
  const activityTokens = new ActivityTokenStore(ACTIVITY_TOKEN_FILE);
  const apnsKeyId = settings.get("APNS_KEY_ID").trim();
  const apnsTeamId = settings.get("APNS_TEAM_ID").trim();
  const apnsKeyP8 = settings.get("APNS_KEY_P8_BASE64").trim();
  let apnsClient: ApnsClient | null = null;
  if (apnsKeyId && apnsTeamId && apnsKeyP8) {
    try {
      const pem = Buffer.from(apnsKeyP8, "base64").toString("utf8");
      apnsClient = new ApnsClient({
        keyId: apnsKeyId,
        teamId: apnsTeamId,
        privateKey: createPrivateKey(pem),
        topic: CLUTCH_IOS_PUSH_TOPIC,
      });
    } catch {
      // The key could not be read.  The reason is never the key.
      apnsClient = null;
    }
  }
  if (apnsClient) log("activity push relay armed");
  else log("activity push relay disabled: APNS_KEY_ID, APNS_TEAM_ID and APNS_KEY_P8_BASE64 are not all set");
  const activityPush = new ActivityPushRelay({
    store: activityTokens,
    enabled: apnsClient !== null,
    sender: apnsClient,
    snapshot: () => activitySnapshot(),
    onLog: (message) => log(message),
  });

  /**
   * Hand one host approval to the turn that owns it.
   *
   * The host asks every connected client, so a question about a thread
   * nobody here is driving belongs to another client — the web canvas, most
   * likely — and is left for it to answer.  Answering it here would take the
   * question away from the person looking at it.
   */
  function routeHostApproval(approval: HostApproval): void {
    const target = [...sessions.values()].find(
      (s) => s.busy && isDshHostedEngine(s.engine) && s.resumeSessionId === approval.agentId,
    );
    if (!target) {
      log(`host approval left to its own client agent=${approval.agentId} tool=${approval.toolName}`);
      return;
    }
    const request: PermissionRequest = {
      requestId: `perm-${(permissionCounter += 1)}`,
      sessionId: approval.agentId,
      title: approval.reason ?? `Tool ${approval.toolName} requests privileged execution`,
      toolName: approval.toolName,
      options: HOST_APPROVAL_OPTIONS,
    };
    target.hostApprovals.set(request.requestId, approval);
    if (!target.permission) {
      // Nobody is watching this turn: do not auto-grant privileged tools.
      // Reject so the host unblocks without running the tool.
      void answerHostApproval(target, request.requestId, "rejected");
      return;
    }
    // The turn owns the request from here on, so an answer is only accepted
    // when it names a request this turn raised.
    target.pendingPermissions.set(request.requestId, request);
    notifyActivityPush();
    target.permission(request);
  }

  /** Put one answer on the host's wire. */
  async function answerHostApproval(
    session: ChatSession,
    requestId: string,
    outcome: HostApprovalOutcome,
  ): Promise<boolean> {
    const approval = session.hostApprovals.get(requestId);
    if (!approval) return false;
    try {
      const relay = await hostApprovals();
      const ok = await relay.answer(approval.eventId, outcome);
      // Keep the request retryable until the host accepts the answer.
      if (ok) {
        session.hostApprovals.delete(requestId);
        notifyActivityPush();
      }
      return ok;
    } catch (err) {
      log(`host approval answer failed request=${requestId} message=${(err as Error).message.slice(0, 120)}`);
      return false;
    }
  }

  /**
   * The host settled a question somewhere else, so the card the client is
   * holding is stale.
   */
  function settleHostApproval(eventId: string): void {
    for (const session of sessions.values()) {
      for (const [requestId, approval] of session.hostApprovals) {
        if (approval.eventId !== eventId) continue;
        session.hostApprovals.delete(requestId);
        session.pendingPermissions.delete(requestId);
        const timer = session.permissionTimers.get(requestId);
        if (timer) {
          clearTimeout(timer);
          session.permissionTimers.delete(requestId);
        }
      }
    }
    notifyActivityPush();
  }

  /**
   * Let go of the permission requests one turn is waiting on.
   *
   * A turn that is cancelled, or that ends, cannot answer a question any
   * more.  The engine is blocked on that answer, so it is released here:
   * otherwise it would wait for a reply that can never come.
   */
  function releasePermissions(session: ChatSession): void {
    for (const timer of session.permissionTimers.values()) clearTimeout(timer);
    session.permissionTimers.clear();
    // Host approvals must be rejected, never auto-allowed, when a turn ends
    // or disconnects: otherwise an unwatched cancel still grants the tool.
    for (const requestId of [...session.hostApprovals.keys()]) {
      void answerHostApproval(session, requestId, "rejected");
    }
    for (const request of session.pendingPermissions.values()) {
      if (session.hostApprovals.has(request.requestId)) continue;
      void session.answerPermission?.(
        request.requestId,
        fallbackPermissionOption(request.options),
      );
    }
    session.pendingPermissions.clear();
    session.hostApprovals.clear();
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
      const listed = await hostClient.run((client) => listDshHostSessions(client, {
        engine,
        limit,
        ...(cwd ? { cwd } : {}),
      }));
      return sortSessionsByUpdated(listed);
    }
    const bridge = bridgeFor(engine);
    await bridge.initialize();
    return sortSessionsByUpdated(await bridge.listSessions(cwd, limit));
  }

  /**
   * Whether an engine can actually run a turn here, and why not when it
   * cannot.  The catalog says "not installed" for a missing launcher and
   * names the missing credential for a key the engine never receives, so
   * the picker never offers an engine whose every turn would fail.
   */
  async function engineAvailable(engine: Engine, hostReachable: boolean): Promise<EngineAvailability> {
    return engineAvailability(engine, { settings, hostReachable });
  }

  /**
   * The last availability answers, and when they were taken.
   *
   * The catalog asks for them on every request, and the probes behind them
   * read the filesystem, so the answers are kept for as long as the catalog
   * entry they fed.
   */
  let availabilityCache: CachedAnswer<Record<Engine, EngineAvailability>> | null = null;

  /**
   * The notes this sidecar has published, per engine.
   *
   * A note that is in here and no longer current was the sidecar's own, so
   * it is dropped from a cached descriptor instead of being left behind.
   */
  const publishedNotes: PublishedNotes = new Map();

  /**
   * The availability of every engine, reused for as long as the catalog is
   * cached.
   *
   * The check reads the filesystem, and the catalog that uses its answer is
   * cached for the same few minutes, so a warm catalog must not pay for the
   * probes again: the picker is asked for on every request, and the probes
   * block the event loop while they run.
   */
  async function currentAvailability(): Promise<Record<Engine, EngineAvailability>> {
    const cached = cachedAnswer(availabilityCache, AVAILABILITY_TTL_MS, Date.now());
    if (cached) return cached;
    const hostReachable = await hostAnswers();
    const answers = await Promise.all(
      ENGINE_ORDER.map(async (engine) => [engine, await engineAvailable(engine, hostReachable)] as const),
    );
    const values = Object.fromEntries(answers) as Record<Engine, EngineAvailability>;
    availabilityCache = { at: Date.now(), value: values };
    return values;
  }

  /**
   * The catalog for this host, with the real launchers wired in.
   *
   * The notes on the answer are always the current ones.  The catalog is
   * cached for a few minutes, so a descriptor that was built earlier can
   * carry a note about a credential the owner has since supplied, and the
   * picker would keep asking for a key that is already there.
   */
  async function catalog(selectedEngine?: Engine): Promise<EngineCatalog> {
    const availability = await currentAvailability();
    const notes: Partial<Record<Engine, string>> = {};
    for (const engine of ENGINE_ORDER) {
      const note = availability[engine].note;
      if (note) {
        notes[engine] = note;
        const published = publishedNotes.get(engine) ?? new Set<string>();
        published.add(note);
        publishedNotes.set(engine, published);
      }
    }
    const built = await engineCatalog({
      launchers: LAUNCHERS,
      available: Object.fromEntries(
        ENGINE_ORDER.map((engine) => [engine, availability[engine].available]),
      ) as Record<Engine, boolean>,
      notes,
      probeCwd: process.env.HOME ?? "/tmp",
      readMuseSessionOptions: () => bridges.get("muse")?.catalogOptions() ?? null,
      probeScope: selectedEngine === undefined
        ? "full"
        : selectedEngine === "mcode" || selectedEngine === "zcode"
          ? selectedEngine
          : "passive",
      plugins: pluginReport,
    });
    return withCurrentNotes(built, notes, publishedNotes);
  }

  /**
   * Apply the client's model and effort choices to a session.
   *
   * Both are ACP config options, and every engine spells them differently,
   * so the catalog is what maps a requested model to the wire value.  A
   * Muse refuses the turn if a requested choice cannot be applied, so it
   * cannot silently run on a different model or effort.
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
    const reported = bridge.modelMetadata(session.bridgeSessionId);
    if (reported) {
      session.modelMetadata = { ...session.modelMetadata, ...reported };
      rememberModelMetadata(session.engine, session.bridgeSessionId, session.modelMetadata);
    }
    return { modelApplied, effortApplied };
  }

  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? "/", `http://${HOST}:${PORT}`);
    // The headers come off the network, so they are parsed before any of
    // them is believed.  A malformed value is a bad request, not a value
    // that reaches the host check or the authentication branch.
    const parsedHeaders = parseInboundHeaders(req.headers);
    if (!parsedHeaders.ok) {
      res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: parsedHeaders.error }));
      return;
    }
    const headers = parsedHeaders.headers;
    if (!isTrustedHostHeader(headers.host, allowed)) {
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
    if (!bearerOk(headers.authorization, token)) {
      res.writeHead(401, { "content-type": "application/json" }).end(JSON.stringify({ error: "unauthorized" }));
      return;
    }

    if (req.method === "POST" && url.pathname === "/clutch/v1/auth/start") {
      let body: unknown;
      try {
        body = await readJsonBody(req);
      } catch {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
        return;
      }
      if (!body || typeof body !== "object" || Array.isArray(body) || (body as Record<string, unknown>).engine !== "muse") {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "engine must be muse" }));
        return;
      }
      try {
        const attempt = await museAuth!.start();
        res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify(attempt));
      } catch {
        const active = museAuth!.activeSnapshot();
        res.writeHead(409, { "content-type": "application/json", "cache-control": "no-store" }).end(
          JSON.stringify(active ?? { state: "failed", error: "A Muse sign-in attempt is already active." }),
        );
      }
      return;
    }

    const authStatus = /^\/clutch\/v1\/auth\/([^/]+)$/.exec(url.pathname);
    const authAnswer = /^\/clutch\/v1\/auth\/([^/]+)\/answer$/.exec(url.pathname);
    if ((req.method === "GET" && authStatus) || (req.method === "DELETE" && authStatus)) {
      const attemptId = authStatus![1]!;
      if (!isMuseAuthAttemptId(attemptId)) {
        res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: "unknown Muse sign-in attempt" }));
        return;
      }
      const attempt = req.method === "GET" ? museAuth!.get(attemptId) : museAuth!.cancel(attemptId);
      if (!attempt) {
        res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: "unknown Muse sign-in attempt" }));
        return;
      }
      res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify(attempt));
      return;
    }
    if (req.method === "POST" && authAnswer) {
      const attemptId = authAnswer[1]!;
      if (!isMuseAuthAttemptId(attemptId)) {
        res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: "unknown Muse sign-in attempt" }));
        return;
      }
      let body: unknown;
      try {
        body = await readJsonBody(req);
      } catch {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
        return;
      }
      const action = body && typeof body === "object" && !Array.isArray(body)
        ? (body as Record<string, unknown>).action
        : undefined;
      if (action !== "accept" && action !== "cancel") {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "action must be accept or cancel" }));
        return;
      }
      const attempt = museAuth!.answer(attemptId, action);
      if (!attempt) {
        res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: "no pending Muse sign-in request" }));
        return;
      }
      res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify(attempt));
      return;
    }

    if (req.method === "GET" && url.pathname === "/clutch/v1/health") {
      res.writeHead(200, { "content-type": "application/json" }).end(
        JSON.stringify({
          ok: true,
          engines: ENGINE_ORDER,
          mcode: { available: mcodeAvailable() },
          zcode: { available: zcodeAvailable() && (LAUNCHERS.zcode.override === true || resolveZcodeCli() !== null) },
          tailnetHost,
          activeTurns: [...sessions.values()].filter((session) => session.busy).length,
          diagnostics: await diagnostics.status(),
        }),
      );
      return;
    }

    // The engine catalog: which engines this host runs, which models each
    // offers right now, and which effort levels it accepts.  The native
    // model picker reads this instead of shipping a list that goes stale.
    if (req.method === "GET" && url.pathname === "/clutch/v1/engines") {
      try {
        const requestedEngine = url.searchParams.get("engine");
        if (requestedEngine !== null && !isEngine(requestedEngine)) {
          res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "unknown engine" }));
          return;
        }
        const value = await catalog(requestedEngine ?? undefined);
        res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify(value));
      } catch (err) {
        log(`engine catalog failed message=${(err as Error).message.slice(0, 120)}`);
        res.writeHead(502, { "content-type": "application/json" }).end(
          JSON.stringify({ error: (err as Error).message.slice(0, 300) }),
        );
      }
      return;
    }

    if (req.method === "POST" && url.pathname === "/clutch/v1/permissions") {
      // The answer to a permission request the engine is waiting on.  The
      // request was pushed to the client as it happened, and the client
      // sends back the option it picked.
      let body: { sessionId?: unknown; requestId?: unknown; optionId?: unknown };
      try {
        body = (await readJsonBody(req)) as typeof body;
      } catch {
        res.writeHead(400, { "content-type": "application/json" }).end(
          JSON.stringify({ error: "invalid JSON body" }),
        );
        return;
      }
      const chatId = typeof body.sessionId === "string" ? body.sessionId : "";
      const requestId = typeof body.requestId === "string" ? body.requestId : "";
      const optionId = typeof body.optionId === "string" ? body.optionId : null;
      if (!chatId || !requestId) {
        res.writeHead(400, { "content-type": "application/json" }).end(
          JSON.stringify({ error: "sessionId and requestId are required" }),
        );
        return;
      }
      const session = sessions.get(chatId);
      if (!session) {
        res.writeHead(404, { "content-type": "application/json" }).end(
          JSON.stringify({ error: "no such session" }),
        );
        return;
      }
      // The request must be one this turn raised.  The ids are process-wide
      // and predictable, so without this check a stale card could answer a
      // different turn's question.
      const pending = session.pendingPermissions.get(requestId);
      if (!pending) {
        res.writeHead(404, { "content-type": "application/json" }).end(
          JSON.stringify({ error: "no such permission request" }),
        );
        return;
      }
      // The option must be one the engine offered.  An unknown id is refused
      // rather than forwarded, so a typo cannot stall the blocked turn.
      if (optionId !== null && !pending.options.some((option) => option.optionId === optionId)) {
        res.writeHead(400, { "content-type": "application/json" }).end(
          JSON.stringify({ error: "unknown permission option" }),
        );
        return;
      }
      // The fallback timer is cleared first, so a request that was already
      // let go is not answered twice.
      const timer = session.permissionTimers.get(requestId);
      if (timer) {
        clearTimeout(timer);
        session.permissionTimers.delete(requestId);
      }
      session.pendingPermissions.delete(requestId);
      notifyActivityPush();
      // The turn knows how to answer: a bridge turn answers the bridge, and a
      // turn that runs in the host answers the host.
      const answered = (await session.answerPermission?.(requestId, optionId)) ?? false;
      session.diagnostics?.record("permission", { permissionKind: "approval", outcome: answered ? "success" : "error" });
      log(`permission answer session=${chatId} request=${requestId} answered=${answered}`);
      res.writeHead(answered ? 200 : 404, { "content-type": "application/json" }).end(
        JSON.stringify(answered ? { ok: true } : { error: "no such permission request" }),
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
      // A cancelled turn cannot answer a question any more, so the engine is
      // released instead of waiting on an answer that will never come.
      if (session) releasePermissions(session);
      log(`chat cancel-request session=${chatId || "none"} cancelled=${cancelled}`);
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ ok: true, cancelled }));
      return;
    }

    if (req.method === "POST" && url.pathname === "/clutch/v1/chat/steer") {
      let body: { sessionId?: unknown; text?: unknown };
      try {
        body = await readJsonBody(req) as typeof body;
      } catch {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
        return;
      }
      const parsedBody = MuseSteerBodySchema.safeParse(body);
      if (!parsedBody.success) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "sessionId and text are required; text must be 4000 characters or fewer" }));
        return;
      }
      const { sessionId: chatId, text } = parsedBody.data;
      const session = sessions.get(chatId);
      if (!session || session.engine !== "muse" || !session.bridgeSessionId) {
        res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: "no active Muse session" }));
        return;
      }
      if (!session.busy) {
        res.writeHead(409, { "content-type": "application/json" }).end(JSON.stringify({ error: "Muse session is not processing a turn" }));
        return;
      }
      try {
        await bridgeFor("muse").steer(session.bridgeSessionId, text);
        session.diagnostics?.record("steer", { outcome: "success" });
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ outcome: "injected" }));
      } catch (error) {
        const diagnostic = museErrorDiagnostics(error);
        session.diagnostics?.record("steer", { outcome: "error", errorCategory: diagnostic.category, errorCode: diagnostic.code });
        log(`chat steer error session=${chatId} engine=muse code=${diagnostic.code ?? "none"} category=${diagnostic.category}`);
        if (error instanceof MuseSteeringError) {
          const failures = {
            unsupported: { status: 501, error: "Muse steering is not supported by this host." },
            idle: { status: 409, error: "Muse has no active turn to steer." },
            stale: { status: 409, error: "The active Muse turn changed before steering was accepted.\u00A0 Queue this message instead." },
            inactive: { status: 409, error: "The Muse bridge is no longer active.\u00A0 Retry after the turn ends." },
          } as const;
          const failure = failures[error.reason];
          res.writeHead(failure.status, { "content-type": "application/json" }).end(JSON.stringify({ error: failure.error }));
        } else {
          res.writeHead(502, { "content-type": "application/json" }).end(JSON.stringify({ error: safeMuseBridgeError(error) }));
        }
      }
      return;
    }

    // Clutch-owned settings surface (service-token bootstrap + managed key
    // write-through), consumed by the native Hosts and Settings sheet.
    if (await handleQuotasRequest(req, res, url.pathname, token)) return;
    if (await handleInfisicalSettingsRequest(req, res, url.pathname, { settings })) return;
    if (await handleActivityTokensRequest(req, res, url.pathname, token, activityPush)) return;

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
      const folderScope = url.searchParams.get("scope") ?? "exact";
      if (!["exact", "tree"].includes(folderScope) || (requestedCwd && !normalizeSessionFolder(requestedCwd))) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid folder scope" }));
        return;
      }
      const limit = parseLimitParam(url.searchParams.get("limit"), 100, 1_000);
      try {
        const includeArchived = url.searchParams.get("archived") === "include";
        // Archived threads are dropped after listing, so over-fetch candidates
        // (capped well past the page size) to keep `limit` visible rows when
        // possible, then trim back to the requested page size after filtering.
        const fetchLimit = requestedCwd && folderScope === "tree" ? 5_000 : includeArchived ? limit : Math.max(limit, 500);
        const listed = await listSessionsFor(listEngine, folderScope === "tree" ? undefined : requestedCwd, fetchLimit);
        const scoped = requestedCwd ? listed.filter((row) => sessionIsInFolder(row.cwd, requestedCwd, folderScope === "tree")) : listed;
        const sessionMeta = loadSessionMeta(SESSION_META_FILE);
        const visible = applySessionMeta(scoped, sessionMeta, includeArchived, listEngine !== "muse");
        const page = visible.slice(0, limit);
        if (listEngine === "muse") rememberMuseListedTitles(page);
        // Bound list I/O; details for an individual Muse row are read on demand.
        const modelPage = isDshHostedEngine(listEngine)
          ? attachSessionModelMetadata(page.slice(0, USAGE_ENRICH_CAP), DSH_HOME).concat(page.slice(USAGE_ENRICH_CAP))
          : page;
        const withKnownMetadata = modelPage.map((row) => ({
          ...knownModelMetadata.get(modelMetadataKey(listEngine, row.sessionId)),
          ...row,
        }));
        const enrichedHead = withKnownMetadata.slice(0, USAGE_ENRICH_CAP);
        const enrichedTail = withKnownMetadata.slice(USAGE_ENRICH_CAP);
        const sessions = listEngine === "muse"
          ? await enrichMuseSessionPage(withKnownMetadata)
          : listEngine === "zcode"
          // Z Code keeps its own model I/O log, not a dsh session log, so the
          // usage comes from the engine's own record.
          ? await mapWithConcurrency(enrichedHead, 4, async (row) => {
            const usage = await readZcodeSessionUsage(row.sessionId);
            if (!usage) return row;
            return {
              ...row,
              ...(usage.model ? { model: usage.model } : {}),
              ...(usage.provider ? { provider: usage.provider } : {}),
              usage,
            };
          }).then((enriched) => enriched.concat(enrichedTail))
          : attachUsage(enrichedHead).concat(enrichedTail);
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ sessions, hasMore: visible.length > limit || listed.length >= fetchLimit }));
      } catch (err) {
        if (listEngine === "muse") log("muse list failed");
        else log(`${listEngine} list failed message=${(err as Error).message.slice(0, 120)}`);
        res.writeHead(502, { "content-type": "application/json" }).end(
          JSON.stringify({ error: listEngine === "muse" ? safeMuseBridgeError(err) : (err as Error).message.slice(0, 300) }),
        );
      }
      return;
    }

    // Details read one bounded log summary and never acquire an ACP session.
    if (req.method === "GET" && url.pathname === "/clutch/v1/sessions/details") {
      const engine = url.searchParams.get("engine");
      const id = url.searchParams.get("sessionId");
      if (engine !== "muse" || !id || id.length > 200) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "Muse engine and sessionId are required" }));
        return;
      }
      try {
        const summary = await readMuseSessionSummary(id);
        if (!summary) {
          res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: "Recorded details are unavailable for this thread." }));
          return;
        }
        const usage = museSessionUsage(summary);
        res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify({
          readOnly: true, sessionId: id,
          cwd: summary.workspaceRoot ?? url.searchParams.get("cwd") ?? undefined,
          title: museDisplayTitle(summary.name, museListedTitles.get(id)), model: summary.modelId, provider: summary.providerId,
          ...(usage ? { usage } : {}),
        }));
      } catch {
        res.writeHead(502, { "content-type": "application/json" }).end(JSON.stringify({ error: "Recorded thread details could not be read." }));
      }
      return;
    }

    // Preview never calls session/load or creates a sidecar chat session.
    if (req.method === "GET" && url.pathname === "/clutch/v1/sessions/preview") {
      const engine = url.searchParams.get("engine");
      const id = url.searchParams.get("sessionId");
      if (!isEngine(engine) || !id || id.length > 200) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "engine and sessionId are required" }));
        return;
      }
      const limit = parseLimitParam(url.searchParams.get("limit"), 200, 1_000);
      const { running, liveSessionId } = findLiveTurn(sessions, engine, id);
      try {
        if (engine === "muse") {
          const log = await readMuseSessionLog(id);
          if (!log) {
            res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: "A read-only preview is unavailable for this thread.\u00A0 Choose Resume Thread to open it with Muse." }));
            return;
          }
          const usage = museSessionUsage(log);
          res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({
            readOnly: true, remoteSessionId: id, cwd: log.workspaceRoot ?? url.searchParams.get("cwd") ?? undefined,
            title: museDisplayTitle(log.name, museListedTitles.get(id)), model: log.modelId, provider: log.providerId,
            history: sliceThreadHistory(compactToolHistory(log.transcript), limit),
            ...(usage ? { usage } : {}), running, ...(liveSessionId ? { liveSessionId } : {}),
            truncated: log.truncated || log.transcriptTruncated || log.transcript.length > limit,
          }));
          return;
        }
        if (isDshHostedEngine(engine)) {
          const history = await hostClient.run((client) => loadDshHostHistory(client, { sessionId: id, limit }));
          const metadata = attachSessionModelMetadata([{ sessionId: id }], DSH_HOME)[0];
          res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({
            readOnly: true, remoteSessionId: id, cwd: url.searchParams.get("cwd") ?? undefined,
            title: loadSessionMeta(SESSION_META_FILE).sessions[id]?.title,
            model: metadata?.model, provider: metadata?.provider,
            history: sliceThreadHistory(compactToolHistory(history), limit),
            usage: readSessionUsage(DSH_HOME, id) ?? undefined, running, truncated: false,
          }));
          return;
        }
        res.writeHead(501, { "content-type": "application/json" }).end(JSON.stringify({ error: "This engine does not provide a read-only preview.\u00A0 Choose Resume Thread to open it." }));
      } catch {
        res.writeHead(502, { "content-type": "application/json" }).end(JSON.stringify({ error: "The thread preview could not be read.\u00A0 Resume it when you are ready to continue." }));
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
      if ([...sessions.values()].some((session) => session.engine === loadEngine &&
          session.resumeSessionId === body.sessionId && session.busy)) {
        res.writeHead(409, { "content-type": "application/json" }).end(JSON.stringify({ error: "This thread is running in Clutch.\u00A0 Preview it or wait for its current turn to finish." }));
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
        engine: loadEngine,
        bridgeSessionId: body.sessionId,
        resumeSessionId: body.sessionId,
        cwd,
        busy: true,
        stream: (update) => {
          if (history.length < 20_000) history.push(update);
        },
        permissionTimers: new Map(),
        pendingPermissions: new Map(),
        hostApprovals: new Map(),
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
        const loadedModelMetadata = isDshHostedEngine(loadEngine)
          ? attachSessionModelMetadata([{ sessionId: body.sessionId }], DSH_HOME)[0]
          : bridge.modelMetadata(body.sessionId);
        if (loadedModelMetadata) session.modelMetadata = loadedModelMetadata;
        rememberModelMetadata(loadEngine, body.sessionId, loadedModelMetadata ?? null);
        if (isDshHostedEngine(loadEngine)) {
          // The host owns this thread's log, so its history is read there.
          // The next turn still goes through the ACP bridge, which resumes
          // the host's own session id, so the thread continues where it left
          // off rather than starting a new one.
          const updates = await hostClient.run((client) => loadDshHostHistory(client, {
            sessionId: body.sessionId,
            limit: historyLimit,
          }));
          history.push(...updates);
        } else if (session.model || session.effort) {
          // A resumed thread keeps the model it was created with unless the
          // client asks for another one, so the choices land after the load.
          await applySessionChoices(bridge, session, await catalog(session.engine));
        }
        session.busy = false;
        session.stream = null;
        res.writeHead(200, { "content-type": "application/json" }).end(
          JSON.stringify({
            sessionId: chatId,
            remoteSessionId: body.sessionId,
            cwd,
            ...(session.modelMetadata?.model ? { model: session.modelMetadata.model } : {}),
            ...(session.modelMetadata?.provider ? { provider: session.modelMetadata.provider } : {}),
            ...(loadEngine === "muse" ? { contextControls: bridge.contextControls(body.sessionId) } : {}),
            history: sliceThreadHistory(compactToolHistory(history), historyLimit),
          }),
        );
      } catch (err) {
        sessions.delete(chatId);
        if (loadEngine === "muse") log(`muse load failed session=${chatId}`);
        else log(`${loadEngine} load failed session=${chatId} message=${(err as Error).message.slice(0, 120)}`);
        res.writeHead(502, { "content-type": "application/json" }).end(
          JSON.stringify({ error: loadEngine === "muse" ? safeMuseBridgeError(err) : (err as Error).message.slice(0, 300) }),
        );
      }
      return;
    }

    if (req.method === "GET" && url.pathname === "/clutch/v1/sessions/context") {
      const id = url.searchParams.get("sessionId");
      const session = id ? sessions.get(id) : undefined;
      if (!session || session.engine !== "muse" || !session.bridgeSessionId) {
        res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: "Resume a Muse thread to view its context controls." }));
        return;
      }
      const controls = bridges.get("muse")?.contextControls(session.bridgeSessionId) ?? { supportsCompaction: false };
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(controls));
      return;
    }

    // Crons: the host's schedule projection, and the engine-mediated
    // create/delete the schedule tools are the management surface for.
    if (url.pathname === "/clutch/v1/crons" && (req.method === "GET" || req.method === "POST" || req.method === "DELETE")) {
      try {
        if (req.method === "GET") {
          const crons = await hostClient.run((client) => listCrons(client));
          res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify({ crons }));
          return;
        }
        // POST always carries a body.  A DELETE may name its target in
        // the query or in a body; whether it carries one is a fact about
        // the bytes that arrive, not the headers that announce them, so
        // an empty chunked envelope is an absent body, never bad JSON.
        let body: unknown = {};
        if (req.method === "POST") {
          try {
            body = await readJsonBody(req);
          } catch {
            res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
            return;
          }
        } else {
          const chunks: Buffer[] = [];
          let size = 0;
          for await (const chunk of req) {
            size += (chunk as Buffer).length;
            if (size > 1_000_000) {
              // The unread remainder would desync the next request on
              // this keep-alive socket, so the stream dies with the 400.
              req.destroy();
              res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
              return;
            }
            chunks.push(chunk as Buffer);
          }
          const raw = Buffer.concat(chunks).toString("utf8").trim();
          if (raw.length > 0) {
            try {
              body = JSON.parse(raw) as unknown;
            } catch {
              res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid JSON body" }));
              return;
            }
          }
        }
        const parsedBody = z.object({
          sessionId: z.string().optional(),
          id: z.string().optional(),
          prompt: z.string().optional(),
          afterSeconds: z.number().optional(),
          at: z.string().optional(),
          everySeconds: z.number().optional(),
        }).passthrough().safeParse(body);
        const record = parsedBody.success ? parsedBody.data : {};
        const sessionId = record.sessionId ?? url.searchParams.get("sessionId") ?? "";
        if (req.method === "DELETE") {
          const id = typeof record.id === "string" ? record.id : url.searchParams.get("id") ?? "";
          if (!sessionId || !id) {
            res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "sessionId and id are required" }));
            return;
          }
          await hostClient.run((client) => deleteCron(client, { sessionId, id }));
          res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify({ deleted: true, id }));
          return;
        }
        const prompt = typeof record.prompt === "string" ? record.prompt.trim() : "";
        const rules: CronRule[] = [];
        if (typeof record.afterSeconds === "number") rules.push({ kind: "after", afterSeconds: record.afterSeconds });
        if (typeof record.at === "string") rules.push({ kind: "at", at: record.at });
        if (typeof record.everySeconds === "number") rules.push({ kind: "every", everySeconds: record.everySeconds });
        const rule = rules.length === 1 ? rules[0]! : undefined;
        const ruleValid = rule !== undefined && (
          rule.kind === "every"
            ? Number.isInteger(rule.everySeconds) && rule.everySeconds >= 300
            : rule.kind === "after"
              ? Number.isInteger(rule.afterSeconds) && rule.afterSeconds > 0
              : !Number.isNaN(Date.parse(rule.at)) && Date.parse(rule.at) > Date.now()
        );
        if (!sessionId || !prompt || !ruleValid) {
          res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "sessionId, a non-empty prompt, and exactly one valid rule (afterSeconds, at, or everySeconds >= 300) are required" }));
          return;
        }
        const cron = await hostClient.run((client) => createCron(client, { sessionId, prompt, rule }));
        res.writeHead(201, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify({ cron }));
        return;
      } catch (err) {
        const message = err instanceof Error ? err.message : "the dsh host could not answer";
        res.writeHead(502, { "content-type": "application/json" }).end(JSON.stringify({ error: message.slice(0, 200) }));
        return;
      }
    }

    if (req.method === "GET" && url.pathname === "/clutch/v1/session-meta") {
      const meta = loadSessionMeta(SESSION_META_FILE);
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ projects: meta.projects, sessions: meta.sessions }));
      return;
    }

    // The files of the folder a thread works in, and one of them to look at.
    // The web canvas shows both, and the native apps ask for them here.
    if (req.method === "GET" && url.pathname === "/clutch/v1/files") {
      // Do not trim root/path: a name with edge spaces is a real name.
      const root = url.searchParams.get("root") || defaultCwd();
      const path = url.searchParams.get("path") ?? "";
      try {
        const listing = await listDirectory(root, path);
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(listing));
      } catch (err) {
        res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: (err as Error).message.slice(0, 200) }));
      }
      return;
    }

    if (req.method === "GET" && url.pathname === "/clutch/v1/file") {
      const root = url.searchParams.get("root") || defaultCwd();
      const path = url.searchParams.get("path") ?? "";
      if (!path) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "the file is missing" }));
        return;
      }
      try {
        const preview = await readPreview(root, path);
        // The absolute path is only for a client on this machine; a remote
        // caller keeps the root-relative path and never learns the layout.
        const loopback = isLoopbackRemoteAddress(req.socket.remoteAddress ?? "");
        const out = loopback ? preview : { ...preview, absolute: undefined };
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(out));
      } catch (err) {
        res.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: (err as Error).message.slice(0, 200) }));
      }
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
      const patch: { projectId?: string | null; archived?: boolean; title?: string | null } = {};
      if (parsed.data.title !== undefined) patch.title = parsed.data.title;
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
        permissions?: unknown;
        museOptions?: unknown;
        contextPolicy?: unknown;
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
      // An engine the sidecar does not know is a client mistake, not a
      // fallback: routing it to DeepSeek would silently run the turn on
      // another provider.  A request that names no engine keeps routing by
      // its model id, exactly as before.  The name is validated by schema
      // first, so a malformed or oversized value never reaches the routing.
      const parsedEngine = EngineNameSchema.safeParse(body.engine);
      if (!parsedEngine.success) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({
          error: "unknown engine",
          engine: typeof body.engine === "string" ? body.engine.trim().slice(0, 40) : "",
          knownEngines: ENGINE_ORDER,
        }));
        return;
      }
      const namedEngine = parsedEngine.data ?? "";
      if (namedEngine && !isEngine(namedEngine)) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({
          error: "unknown engine",
          engine: namedEngine.slice(0, 40),
          knownEngines: ENGINE_ORDER,
        }));
        return;
      }
      const engine = routeForModel(
        typeof body.model === "string" ? body.model : undefined,
        namedEngine || undefined,
      );
      const cwd = typeof body.cwd === "string" && body.cwd.length > 0 ? body.cwd : process.env.HOME ?? "/tmp";
      // A client that can answer a permission request says so, and the
      // sidecar holds the request until the answer comes back.  A client
      // that does not say keeps the behaviour the sidecar has always had,
      // where it answers the request itself.
      const asksForPermissions = body.permissions === "ask";
      // The model the client picked and the effort it wants.  Both are
      // optional: without them the engine keeps its own defaults.
      const requestedModel = typeof body.model === "string" && body.model.trim().length > 0 ? body.model.trim() : undefined;
      const requestedEffort = typeof body.effort === "string" && body.effort.trim().length > 0 ? body.effort.trim() : undefined;
      const parsedMuseOptions = body.museOptions === undefined ? null : MuseLaunchOptionsSchema.safeParse(body.museOptions);
      if (parsedMuseOptions && (!parsedMuseOptions.success || engine !== "muse")) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid Muse settings" }));
        return;
      }
      const museOptions = parsedMuseOptions?.success ? parsedMuseOptions.data : undefined;
      const parsedContextPolicy = body.contextPolicy === undefined ? null : ContextPolicySchema.safeParse(body.contextPolicy);
      if (parsedContextPolicy && (!parsedContextPolicy.success || engine !== "muse")) {
        res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "invalid context policy" }));
        return;
      }
      const contextPolicy = parsedContextPolicy?.success ? parsedContextPolicy.data : undefined;
      // Images attached to the turn, the way the web canvas attaches files.
      const images = parsePromptImages(body.images);

      let chatId = typeof body.sessionId === "string" && body.sessionId.length > 0 ? body.sessionId : null;
      let session = chatId ? sessions.get(chatId) : undefined;
      if (!session || session.engine !== engine) {
        chatId = randomBytes(16).toString("hex");
        session = {
          engine,
          bridgeSessionId: "",
          resumeSessionId: null,
          cwd,
          busy: false,
          stream: null,
          permissionTimers: new Map(),
          pendingPermissions: new Map(),
          hostApprovals: new Map(),
        };
        sessions.set(chatId, session);
      }
      if (session.busy) {
        res.writeHead(409, { "content-type": "application/json" }).end(JSON.stringify({ error: "session busy", sessionId: chatId }));
        return;
      }
      if (session.resumeSessionId && [...sessions.values()].some((other) => other !== session &&
          other.engine === engine && other.resumeSessionId === session.resumeSessionId && other.busy)) {
        res.writeHead(409, { "content-type": "application/json" }).end(JSON.stringify({ error: "This thread is already running in another Clutch window.", sessionId: chatId }));
        return;
      }
      if (requestedModel) session.model = requestedModel;
      if (requestedEffort) session.effort = requestedEffort;

      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });
      const turnDiagnostics = diagnostics.start({ engine });
      sseSend(res, "start", { sessionId: chatId, engine, diagnosticId: turnDiagnostics.turnId });
      if (engine !== "muse") sseSend(res, "capabilities", { supportsSteering: false });
      log(`chat start session=${chatId} engine=${engine} promptChars=${prompt.length}`);

      const active = session;
      active.busy = true;
      notifyActivityPush();
      active.diagnostics = turnDiagnostics;
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
      // The name a call was given, so an update that carries only a status
      // does not replace the name with the answer.
      const toolNames = new Map<string, string>();
      active.stream = (u) => {
        if (u.kind === "tool_call" || u.kind === "tool_call_update") {
          turnDiagnostics.record("tool", { status: u.toolStatus ?? "running" });
          const id = u.toolCallId ?? "";
          if (u.kind === "tool_call" && u.text) toolNames.set(id, u.text);
          const name = u.kind === "tool_call" ? u.text : (toolNames.get(id) ?? u.text);
          sseSend(res, "tool", {
            id,
            name,
            status: u.toolStatus ?? "running",
            // A tool that runs other tools is the parent of them, and the
            // client shows the children hanging under it.
            ...(u.parentToolCallId ? { parentId: u.parentToolCallId } : {}),
            ...(u.toolInput ? { input: u.toolInput } : {}),
            ...(u.toolOutput ? { output: u.toolOutput } : {}),
          });
          return;
        }
        if (u.kind === "plan") {
          turnDiagnostics.record("plan", { stepCount: u.plan?.length ?? 0 });
          // The plan is a state, not a line of the transcript: the client
          // shows the list the engine last reported.
          sseSend(res, "plan", { entries: u.plan ?? [] });
          return;
        }
        const r = route(u);
        turnDiagnostics.record("progress", { phase: r.event === "thought" ? "thinking" : "streaming", count: r.text.length });
        sseSend(res, r.event, { text: r.text });
        if (u.kind !== "user_message_chunk") sink?.onUpdate(u.kind, r.text);
      };
      // A permission request the engine is waiting on.  It goes to the client
      // as it is, and the answer comes back through the permissions route.
      // A turn whose client did not ask for this keeps the sidecar's own
      // answer, which is what the bridge does when no turn is watching.
      if (asksForPermissions) {
        active.permission = (request) => {
          turnDiagnostics.record("permission", { permissionKind: "approval", outcome: "pending" });
          sseSend(res, "permission", {
            requestId: request.requestId,
            title: request.title,
            toolName: request.toolName,
            options: request.options,
            ...(request.evidence ? { evidence: request.evidence } : {}),
          });
          // The engine waits, so a client that never answers must not hang
          // the turn: the sidecar falls back to the allow-once it has always
          // sent.
          const timer = setTimeout(() => {
            active.permissionTimers.delete(request.requestId);
            active.pendingPermissions.delete(request.requestId);
            // Host approvals time out as rejected; bridge turns keep the
            // historical allow-once fallback for unattended ACP prompts.
            const optionId = active.hostApprovals.has(request.requestId)
              ? null
              : fallbackPermissionOption(request.options);
            void active.answerPermission?.(request.requestId, optionId);
          }, PERMISSION_TIMEOUT_MS);
          active.permissionTimers.set(request.requestId, timer);
        };
      }
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
      let compactionInProgress = false;
      const stopUsage = (): void => {
        if (usageTimer) clearInterval(usageTimer);
        usageTimer = null;
      };
      const finish = (event: string, data: unknown): void => {
        if (settled) return;
        settled = true;
        const parsedTerminal = z.object({ stopReason: z.string().optional() }).safeParse(data);
        const reason = parsedTerminal.success ? parsedTerminal.data.stopReason : undefined;
        if (compactionInProgress) {
          turnDiagnostics.record("compaction", { status: reason === "cancelled" ? "cancelled" : event === "error" ? "failed" : "unknown" });
          compactionInProgress = false;
        }
        const outcome: TurnOutcome = event === "error" ? "error" : reason === "cancelled" ? "cancelled" : reason === "endTurn" || reason === "end_turn" ? "success" : "unknown";
        turnDiagnostics.finish(outcome);
        log(`chat diagnostic id=${turnDiagnostics.turnId} outcome=${outcome}`);
        delete active.diagnostics;
        stopUsage();
        active.busy = false;
        notifyActivityPush();
        active.stream = null;
        if (active.bridgeSessionId) bridges.get(engine)?.clearActiveTurn(active.bridgeSessionId);
        active.permission = null;
        // A turn that ended cannot answer a permission request any more, so
        // the pending ones are let go rather than left waiting: the engine is
        // blocked on the answer, and a cancelled turn would never send it.
        releasePermissions(active);
        active.answerPermission = null;
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
        // The dsh-hosted engines live in the host: it owns their threads, so
        // the turn runs there and the client sees the same events the web
        // canvas does.  A host that cannot be reached falls back to the
        // bridge, which is the older path and still works on its own.
        if (isDshHostedEngine(engine)) {
          let host: DshHostClient | null = null;
          try {
            host = await openDshHost();
          } catch (err) {
            log(`chat host unavailable session=${chatId} message=${(err as Error).message.slice(0, 120)}`);
          }
          if (host) {
            // A refused identity on the held client drops it from the cache, as
            // it does for the one-shot reads.
            let heldHost: DshHostClient = host;
            // A refused identity must not be reused for the rest of the turn.
            // The cache is told, a fresh client is acquired for the next call,
            // and a call made before the turn started (session creation, model
            // selection) is retried once on it.  The turn itself is never
            // replayed: it may already have begun on the host.
            const viaHost = async <R>(
              call: (client: DshHostClient) => Promise<R>,
              retryFresh = false,
            ): Promise<R> => {
              try {
                return await call(heldHost);
              } catch (err) {
                hostClient.noteFailure(heldHost, err);
                if (!isRefusedIdentity(err)) throw err;
                try {
                  heldHost = await openDshHost();
                } catch {
                  throw err;
                }
                if (!retryFresh) throw err;
                const fresh = heldHost;
                try {
                  return await call(fresh);
                } catch (retryErr) {
                  hostClient.noteFailure(fresh, retryErr);
                  throw retryErr;
                }
              }
            };
            // The relay has to be listening before the turn starts: the host
            // asks every connected client, and a question asked before the
            // sidecar is listening is a question nobody hears.
            const relay = await hostApprovals();
            const ready = await relay.ready();
            if (!ready) {
              finish("error", {
                message: "the host approval relay did not become ready in time",
                sessionId: chatId,
                remoteSessionId: remoteId(),
              });
              return;
            }
            // Only a host session id resumes a host thread.  The bridge
            // session id is a different namespace and must not be reused.
            const sessionId =
              active.resumeSessionId ||
              (await viaHost((client) => createDshHostSession(client, { cwd }), true));
            // A host thread is resumable by its own id, so the next turn picks
            // the same thread up after a restart of the sidecar.
            active.resumeSessionId = sessionId;
            const turnAbort = new AbortController();
            const abortTurn = (): void => {
              if (!turnAbort.signal.aborted) turnAbort.abort();
            };
            req.on("close", abortTurn);
            // This turn answers its own questions: the host's approval arrives
            // as a waterfall, and the answer goes back over the host's wire.
            active.answerPermission = async (requestId, optionId) =>
              answerHostApproval(active, requestId, hostOutcomeFor(optionId));
            // The host's own model selection decides which provider the turn
            // runs on, so the engine the client picked is applied before the
            // prompt.  A refusal is not fatal: the turn still runs on the
            // host's default.
            try {
              const provider = await viaHost((client) => hostProviderFor(client, engine), true);
              if (provider) {
                const catalogValue = await catalog(engine);
                const wanted = session.model
                  ? resolveModelValue(catalogValue, engine, session.model)
                  : null;
                const chosen = await viaHost((client) =>
                  selectHostModel(client, sessionId, provider, wanted ?? null, session.effort ?? null),
                  true,
                );
                turnDiagnostics.record("metadata", { model: chosen, provider: provider.provider, sessionId });
                log(`chat host-model session=${chatId} provider=${provider.provider} model=${chosen}`);
              } else {
                log(`chat host has no provider for engine=${engine}`);
              }
            } catch (err) {
              log(`chat host-model refused session=${chatId} message=${(err as Error).message.slice(0, 120)}`);
            }
            log(`chat host-turn session=${chatId} hostSession=${sessionId}`);
            const result = await viaHost((client) => runDshHostTurn(client, {
              sessionId,
              prompt,
              images: images.map((image) => ({
                mediaType: image.mimeType,
                data: image.data,
                ...(image.name ? { name: image.name } : {}),
              })),
              onUpdate: (update) => active.stream?.(update),
              signal: turnAbort.signal,
            }));
            log(`chat end session=${chatId} stopReason=${result.stopReason}`);
            if (sink) {
              try {
                await sink.onDone();
              } catch (err) {
                /* relay failures must not break the SSE transport */
              }
            }
            finish("done", { stopReason: result.stopReason, sessionId: chatId, remoteSessionId: remoteId() });
            return;
          }
        }
        const bridge = bridgeFor(engine);
        if (engine === "muse") {
          if ([...sessions.values()].some((other) => other !== active && other.engine === "muse" && other.busy)) {
            // An unchanged policy can share the host; a different policy must not interrupt another turn.
            if (!bridge.matchesMuseLaunchOptions(museOptions ?? null)) throw new MuseSettingsError("busy");
          }
          if (await bridge.configureMuseLaunch(museOptions ?? null)) {
            for (const other of sessions.values()) if (other.engine === "muse") other.bridgeSessionId = "";
          }
        }
        await bridge.initialize();
        if (engine === "muse") sseSend(res, "capabilities", { supportsSteering: bridge.steeringSupported() });
        // This turn answers its own questions, the way a bridge always has.
        active.answerPermission = (requestId, optionId) =>
          bridge.answerPermission(requestId, optionId);
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
          const currentModelMetadata = bridge.modelMetadata(active.bridgeSessionId);
          if (currentModelMetadata) active.modelMetadata = { ...active.modelMetadata, ...currentModelMetadata };
          rememberModelMetadata(engine, active.bridgeSessionId, active.modelMetadata ?? null);
          log(`chat session=${chatId} bridgeSession=${active.bridgeSessionId} cwdChars=${cwd.length}`);
        }
        if (engine === "muse" && museOptions && active.bridgeSessionId) {
          await bridge.applyMuseApprovalMode(active.bridgeSessionId, museOptions.yolo);
          if (!active.model && !museContributorModelId(active.modelMetadata?.model)) {
            active.model = contributorDefaultModel(active.modelMetadata?.model);
          }
        } else if (engine === "muse" && active.bridgeSessionId && bridge.hasMuseApprovalModes(active.bridgeSessionId)) {
          // Legacy clients did not opt into YOLO for this turn.
          await bridge.applyMuseApprovalMode(active.bridgeSessionId, false);
        }
        if (engine === "muse" && active.effort === "max" &&
            isMuseContributorModel(active.model ?? active.modelMetadata?.model)) {
          throw new MuseSettingsError("effort");
        }
        // The model's and the effort's choices land before the turn, so the
        // first prompt of a new session already runs on the picked model.
        if (active.model || active.effort) {
          const applied = await applySessionChoices(bridge, active, await catalog(active.engine));
          log(`chat choices session=${chatId} model=${applied.modelApplied} effort=${applied.effortApplied}`);
          if (engine === "muse" && active.model && !applied.modelApplied) throw new MuseSettingsError("model");
          if (engine === "muse" && active.effort && !applied.effortApplied) throw new MuseSettingsError("effort");
        }
        if (settled) return;
        turnDiagnostics.record("metadata", { ...active.modelMetadata, sessionId: remoteId() });
        if (engine === "mcode" && active.bridgeSessionId) {
          const sessionIdForUsage = active.bridgeSessionId;
          usageTimer = setInterval(() => {
            const fresh = readSessionUsage(DSH_HOME, sessionIdForUsage);
            if (!fresh) return;
            // Only re-announce when the engine actually wrote something new.
            if (lastUsage && fresh.updatedAtMs === lastUsage.updatedAtMs) return;
            const measured = withRate(fresh, lastUsage ?? undefined);
            lastUsage = fresh;
            turnDiagnostics.record("context", { ...measured, basis: "latest-response" });
            if (!settled) sseSend(res, "usage", { sessionId: sessionIdForUsage, usage: measured });
          }, 1500);
          usageTimer.unref?.();
        }
        if (engine === "zcode" && active.bridgeSessionId) {
          const sessionIdForUsage = active.bridgeSessionId;
          // Z Code appends to its own model I/O log as the turn runs, so the
          // log is re-read on a timer and only real records are pushed.  The
          // read is guarded, so a slow file never piles up behind itself.
          let reading = false;
          const publishZcodeUsage = async (): Promise<void> => {
            if (reading || settled) return;
            reading = true;
            try {
              const fresh = await readZcodeSessionUsage(sessionIdForUsage);
              if (!fresh || settled) return;
              // Only re-announce when the engine actually wrote something new.
              // The timestamp is optional, so the counters decide: a record
              // without one must not freeze the strip at the first reading.
              if (lastUsage && sameUsageReading(lastUsage, fresh)) return;
              lastUsage = fresh;
              turnDiagnostics.record("context", { ...fresh, basis: "latest-response" });
              sseSend(res, "usage", { sessionId: sessionIdForUsage, usage: fresh });
            } catch {
              log("zcode usage read failed");
            } finally {
              reading = false;
            }
          };
          await publishZcodeUsage();
          if (settled) return;
          usageTimer = setInterval(() => { void publishZcodeUsage(); }, 1500);
          usageTimer.unref?.();
        }
        let publishMuseState: ((fresh?: boolean) => Promise<void>) | null = null;
        if (engine === "muse" && active.bridgeSessionId) {
          const nativeId = active.bridgeSessionId;
          let reading: Promise<void> | null = null;
          let lastState = "";
          publishMuseState = async (fresh = false): Promise<void> => {
            if (reading) {
              await reading;
              if (!fresh) return;
            }
            if (settled) return;
            const sample = (async (): Promise<void> => {
              try {
              const log = await readMuseSessionLog(nativeId);
              if (settled) return;
              const controls = bridge.contextControls(nativeId);
              const usage = withMuseContext(log ? museSessionUsage(log) : null, controls);
              const state = JSON.stringify({ controls, usage });
              if (state === lastState) return;
              lastState = state;
              sseSend(res, "context_controls", controls);
              if (usage) {
                sseSend(res, "usage", { sessionId: nativeId, usage });
                // Snapshots are observations, never fresh per-call billing events.
                turnDiagnostics.record("metrics", {
                  snapshotBasis: "session-snapshot", totalsComplete: usage.totalsComplete === true,
                  ...(usage.inputTokensReported !== false ? { recordedInputTokens: usage.inputTokens } : {}),
                  ...(usage.outputTokensReported !== false ? { recordedOutputTokens: usage.outputTokens } : {}),
                  cachedTokens: usage.cachedTokens,
                  responseTokensPerSecond: usage.responseTokensPerSecond,
                  completionDurationMs: usage.completionDurationMs,
                });
              }
              if (controls.contextUsedTokens !== undefined && controls.contextWindow !== undefined) {
                turnDiagnostics.record("context", {
                  basis: "engine-context", totalTokens: controls.contextUsedTokens, contextWindow: controls.contextWindow,
                });
              }
            } catch {
              log("muse metrics read failed");
              }
            })();
            reading = sample;
            try { await sample; } finally { if (reading === sample) reading = null; }
          };
          await publishMuseState();
          if (settled) return;
          usageTimer = setInterval(() => { void publishMuseState?.(); }, 2_500);
          usageTimer.unref?.();
          if (prompt.trim() === "/compact" && !bridge.contextControls(nativeId).supportsCompaction) {
            throw new MuseSettingsError("compaction");
          }
          if (prompt.trim() === "/compact") {
            compactionInProgress = true;
            turnDiagnostics.record("compaction", { status: "in_progress" });
          }
          if (prompt.trim() !== "/compact" && contextPolicy && bridge.takeEarlyCompaction(nativeId, contextPolicy)) {
            compactionInProgress = true;
            turnDiagnostics.record("compaction", { status: "in_progress" });
            sseSend(res, "thought", { text: "Compacting context before sending your message…" });
            try {
              const compacted = await bridge.prompt(nativeId, "/compact", [], active.cwd);
              if (settled) return;
              if (!["endTurn", "end_turn"].includes(compacted.stopReason)) {
                turnDiagnostics.record("compaction", { status: compacted.stopReason === "cancelled" ? "cancelled" : "failed" });
                compactionInProgress = false;
                throw new MuseSettingsError("auto-compact");
              }
              turnDiagnostics.record("compaction", { status: "completed" });
              compactionInProgress = false;
              sseSend(res, "message", { text: "\n\n" });
              await publishMuseState(true);
            } catch {
              if (compactionInProgress) turnDiagnostics.record("compaction", { status: "failed" });
              compactionInProgress = false;
              throw new MuseSettingsError("auto-compact");
            }
          }
        }
        if (settled) return;
        const result = await bridge.prompt(active.bridgeSessionId, prompt, images, active.cwd);
        if (engine === "muse" && prompt.trim() === "/compact") {
          turnDiagnostics.record("compaction", { status: ["endTurn", "end_turn"].includes(result.stopReason) ? "completed" : result.stopReason === "cancelled" ? "cancelled" : "failed" });
          compactionInProgress = false;
        }
        await publishMuseState?.(true);
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
        if (compactionInProgress) turnDiagnostics.record("compaction", { status: settled ? "cancelled" : "failed" });
        compactionInProgress = false;
        const turnError = museErrorDiagnostics(err);
        turnDiagnostics.record("progress", { phase: "finalizing", outcome: "error", errorCategory: turnError.category, errorCode: turnError.code });
        if (engine === "muse") {
          const diagnostic = museErrorDiagnostics(err);
          log(`chat error session=${chatId} engine=muse code=${diagnostic.code ?? "none"} category=${diagnostic.category}`);
        } else log(`chat error session=${chatId} message=${(err as Error).message.slice(0, 120)}`);
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
        finish("error", {
          message: engine === "muse" ? safeMuseBridgeError(err) : (err as Error).message.slice(0, 300),
          sessionId: chatId,
          remoteSessionId: remoteId(),
        });
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
