/**
 * How the sidecar starts the Z Code engine over ACP.
 *
 * Z Code's own CLI has no ACP command.  It speaks the ZCode Protocol through
 * `zcode app-server --stdio`, and the Agent Client Protocol comes from the
 * `zcode-acp-server` bridge (npm `zcode-acp-server`,
 * https://github.com/william0wang/zcode-acp), which drives that app-server and
 * translates its stream into ACP v1.  It is the same bridge BotFleet's ZCode
 * ACP engine runs (BF-2654).  The sidecar used to launch `zcode acp`, which
 * exits with "Unknown command: acp" on every release (C-129), so the engine
 * could never start.
 *
 * The bridge also fixes the second half of C-129:  a CLI launched straight
 * out of `ZCode.app` cannot find its built-in provider table
 * (`Resources/config/provider/zcode-builtin.json`), and the bridge hands the
 * app-server that table when it can see the CLI's real `zcode.cjs`.  A
 * `zcode` symlink on PATH hides that path (the bridge treats a name without a
 * `.cjs` suffix as an opaque wrapper), so the sidecar resolves the CLI itself
 * and passes the bridge its real path in `ZCODE_BIN`.
 *
 *   sidecar (ACP)  ->  zcode-acp-server  ->  zcode app-server --stdio
 */

import { accessSync, constants, existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";

import { z } from "zod";

type Env = Record<string, string | undefined>;

/** The bridge's stdio server bin.  The package also installs `zcode-acp`, its setup CLI. */
export const ZCODE_ACP_SERVER = "zcode-acp-server";

/** The one install line the engine needs:  the bridge finds the Z Code CLI itself. */
export const ZCODE_ACP_INSTALL = "npm install -g zcode-acp-server";

/** The sign-in command the bridge ships, for a host without the Z Code app. */
export const ZCODE_ACP_SETUP = "zcode-acp setup --provider zai";

/**
 * Variables removed from the bridge's environment.
 *
 * The bridge lets an inherited `ANTHROPIC_API_KEY` override the Z Code
 * sign-in it reads from disk (dist/backend/credentials.js
 * `mergeEnvWithCreds`), and the sidecar's environment is shared with every
 * other engine.  A key meant for another provider would otherwise go to the
 * Z Code endpoint, and a z.ai or GLM key would move the turn off the Coding
 * Plan onto metered API billing.  `ZCODE_BASE_URL` is dropped by the bridge
 * already;  it is listed so the rule lives in one place.
 */
export const ZCODE_STRIPPED_ENV = [
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "ZCODE_BASE_URL",
  "ZAI_API_KEY",
  "Z_AI_API_KEY",
  "ZHIPUAI_API_KEY",
  "GLM_API_KEY",
  "BIGMODEL_API_KEY",
] as const;

function homeOf(env: Env): string {
  return env.HOME?.trim() || homedir();
}

function executableFile(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

/** A JavaScript entry, which the bridge runs with its own Node rather than executing. */
const JS_ENTRY = /\.(cjs|mjs|js)$/;

function pathDirs(env: Env): string[] {
  return (env.PATH ?? "").split(delimiter).filter(Boolean);
}

/**
 * Where `npm install -g zcode-acp-server` puts the bridge.
 *
 * The first place is the bin directory of the Node running the sidecar:  npm
 * installs global bins next to its own node (Homebrew, nvm and the official
 * installer all do), and that is the one directory a launchd-started sidecar
 * can count on.  The rest are the usual npm prefixes.  PATH is searched after
 * these, by the caller.
 */
export function zcodeAcpServerCandidates(env: Env = process.env, nodeBinDir: string = dirname(process.execPath)): string[] {
  const home = homeOf(env);
  return [
    join(nodeBinDir, ZCODE_ACP_SERVER),
    join(home, ".local", "bin", ZCODE_ACP_SERVER),
    join(home, ".npm-global", "bin", ZCODE_ACP_SERVER),
    join("/opt/homebrew/bin", ZCODE_ACP_SERVER),
    join("/usr/local/bin", ZCODE_ACP_SERVER),
  ];
}

/**
 * The bridge command the sidecar launches.
 *
 * `CLUTCH_ZCODE_ACP_CLI` names one the search misses.  With nothing found the
 * bare name is returned, so the availability check resolves it against PATH
 * and reports the engine as not installed rather than failing the first send.
 */
export function defaultZcodeAcpServer(env: Env = process.env, nodeBinDir?: string): string {
  const explicit = env.CLUTCH_ZCODE_ACP_CLI?.trim();
  if (explicit) return explicit;
  return zcodeAcpServerCandidates(env, nodeBinDir).find(executableFile) ?? ZCODE_ACP_SERVER;
}

/**
 * Where the Z Code CLI can live, in the order the sidecar trusts them:  the
 * two install locations Clutch has always searched, PATH, then the desktop
 * app bundles the bridge itself knows (dist/backend/resolve.js
 * `bundledZcodeCandidates`).
 */
export function zcodeCliCandidates(env: Env = process.env): string[] {
  const home = homeOf(env);
  return [
    join(home, ".local", "bin", "zcode"),
    join(home, ".zcode", "bin", "zcode"),
    ...pathDirs(env).map((dir) => join(dir, "zcode")),
    "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
    join(home, "Applications", "ZCode.app", "Contents", "Resources", "glm", "zcode.cjs"),
    "/opt/ZCode/resources/glm/zcode.cjs",
    "/usr/share/zcode/resources/glm/zcode.cjs",
  ];
}

/**
 * The real path of the Z Code CLI the bridge should drive, or null when this
 * host has none.
 *
 * `ZCODE_BIN` (the bridge's own variable) and then `CLUTCH_ZCODE_CLI` name
 * one explicitly;  an explicit path that is not there is not replaced by a
 * guess.  An explicit bare name such as `zcode` is a command the bridge spawns
 * through PATH, so it is looked up there.  Symlinks are followed, because the
 * bridge only finds the provider table next to the real `zcode.cjs`.
 *
 * The bridge runs a `.cjs`, `.mjs` or `.js` entry with its own Node
 * (dist/backend/resolve.js `resolveZcodeCommandOnce`), so only another kind
 * of entry has to be executable.
 */
export function resolveZcodeCli(env: Env = process.env): string | null {
  const explicit = env.ZCODE_BIN?.trim() || env.CLUTCH_ZCODE_CLI?.trim();
  const candidates = !explicit
    ? zcodeCliCandidates(env)
    : /[\\/]/.test(explicit)
      ? [explicit]
      : pathDirs(env).map((dir) => join(dir, explicit));
  for (const candidate of candidates) {
    const real = realFile(candidate);
    if (real && (JS_ENTRY.test(real) || executableFile(real))) return real;
  }
  return null;
}

/** The real path of a regular file, following symlinks, or null. */
function realFile(path: string): string | null {
  if (!existsSync(path)) return null;
  try {
    const real = realpathSync(path);
    return statSync(real).isFile() ? real : null;
  } catch {
    return null;
  }
}

/** The Z Code data root the bridge reads:  `ZCODE_HOME`, else `~/.zcode`. */
export function zcodeCredentialPaths(env: Env = process.env): { accounts: string; desktop: string } {
  const root = env.ZCODE_HOME?.trim() || join(homeOf(env), ".zcode");
  return { accounts: join(root, "v2", "acp-accounts.json"), desktop: join(root, "v2", "config.json") };
}

/** A saved `zcode-acp setup` account file:  one JSON object with at least one entry. */
const SetupAccountsSchema = z.record(z.string(), z.unknown());

/** The desktop app's provider config, decoded only as far as the sign-in check reads it. */
const DesktopConfigSchema = z
  .object({
    provider: z
      .record(
        z.string(),
        z
          .object({
            enabled: z.boolean().optional().catch(undefined),
            options: z
              .object({ apiKey: z.string().optional().catch(undefined) })
              .passthrough()
              .optional()
              .catch(undefined),
          })
          .passthrough(),
      )
      .optional()
      .catch(undefined),
  })
  .passthrough();

function readJson(path: string): unknown {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return undefined;
  }
  if (!raw.trim()) return undefined;
  try {
    return JSON.parse(raw);
  } catch {
    return undefined;
  }
}

/**
 * Whether Z Code is signed in, as far as files on this host show.
 *
 * Two of the bridge's own rungs (dist/config/account-provider.js):  a saved
 * `zcode-acp setup` account, or a desktop-app provider entry that carries a
 * key, where a built-in Coding Plan entry only counts while the app left it
 * enabled.  The desktop app's newer sign-in that keeps no key in this file is
 * not replicated, so a false answer is a note in the picker, never a block:
 * the bridge itself settles that case on the first turn.
 */
export function zcodeSignedIn(env: Env = process.env): boolean {
  const { accounts, desktop } = zcodeCredentialPaths(env);
  const setup = SetupAccountsSchema.safeParse(readJson(accounts));
  if (setup.success && Object.keys(setup.data).length > 0) return true;
  const config = DesktopConfigSchema.safeParse(readJson(desktop));
  if (!config.success) return false;
  for (const [id, entry] of Object.entries(config.data.provider ?? {})) {
    if (!entry.options?.apiKey?.trim()) continue;
    if (!id.startsWith("builtin:") || entry.enabled === true) return true;
  }
  return false;
}

/**
 * The bridge's permission mode for the sidecar's posture.
 *
 * `danger-full-access` (the sidecar's default) means the engine never asks,
 * which is the bridge's unrestricted `yolo` mode.  Any other posture means
 * the engine asks and the native app answers, which is the bridge's `build`
 * mode:  every ask then reaches the sidecar as `session/request_permission`.
 */
export function zcodeAcpMode(permissionMode: string | undefined): "yolo" | "build" {
  const mode = permissionMode?.trim();
  return !mode || mode === "danger-full-access" ? "yolo" : "build";
}

/**
 * The environment the bridge starts in:  the sidecar's own, minus the keys
 * that must not reach Z Code, plus the CLI's real path and the permission
 * mode.  A `ZCODE_BIN` or `ZCODE_ACP_MODE` the operator set wins.
 */
export function zcodeSpawnEnv(env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const out: NodeJS.ProcessEnv = { ...env };
  for (const name of ZCODE_STRIPPED_ENV) delete out[name];
  if (!out.ZCODE_BIN?.trim()) {
    const cli = resolveZcodeCli(out);
    if (cli) out.ZCODE_BIN = cli;
  }
  if (!out.ZCODE_ACP_MODE?.trim()) out.ZCODE_ACP_MODE = zcodeAcpMode(out.DSH_PERMISSION_MODE);
  return out;
}
