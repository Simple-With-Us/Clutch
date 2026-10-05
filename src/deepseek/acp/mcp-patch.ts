/**
 * DSH MCP patcher — pure YAML overlay generation.
 *
 * Stock `@deepseek-ai/dsh-acp` rejects non-empty session/new mcpServers.
 * BotFleet still builds the same stdio mounts every other ACP engine gets.
 * For a stock `dsh` binary this module generates the `dsh --patch` overlay
 * that delivers those mounts as `dsh-mcp-client` rows, one per stdio server.
 *
 * BotFleet owns the actual spawn-time assembly: it reads
 * `dshMcpPatchYaml(serverList)`, writes the overlay to a 0700 directory via
 * `writeDshMcpPatch`, and routes the child through `dsh-acp-bridge` so the
 * wire can keep sending mcpServers.  That BotFleet-side code stays where it
 * is — this module is the *engine-side* helper that BotFleet composes into
 * its own driver.
 *
 * Ported from BotFleet `server/drivers/acp/dsh-mcp.ts` on 2026-09-19; the
 * patch YAML and the temp-file write pattern are unchanged because they are
 * pure DSH-shape data, not ACP runtime.
 */
import { randomUUID } from "node:crypto";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

const SERVER_NAME_PATTERN = /^[A-Za-z0-9_-]{1,32}$/;
export const DSH_MCP_PATCH_PREFIX = "botfleet-dsh-mcp-";

/** A single stdio MCP server the host wants to mount.  Mirrors BotFleet's
 * `AcpStdioMcpServer`; redeclared here so Clutch's pure code is import-free. */
export interface DshStdioMcpServer {
  readonly name: string;
  readonly command: string;
  readonly args: readonly string[];
  readonly env: ReadonlyArray<{ readonly name: string; readonly value: string }>;
}

/** CLI stems that resolve to the DSH engine.
 *
 * The engine ships as `dsh`, and Clutch ships its own pinned `clutch` wrapper
 * around that binary (same engine, separate state home).  Every engine-scoped
 * policy — MCP mounting, the minimum ACP version gate — has to recognise
 * both.  Matching on the literal `dsh` alone is what made those policies
 * silently switch off the moment a wrapper was configured.
 */
const DSH_ENGINE_STEMS: ReadonlySet<string> = new Set(["dsh", "clutch"]);

/** Whether a configured CLI is the DSH engine, under any of its names.
 *
 *  The extension strip is what lets an absolute path to a shell wrapper count
 *  as its engine, so `clutch.sh` and `dsh.sh` both resolve to the engine. */
export function isDshEngineCli(cli: string): boolean {
  const stem = basename(cli).toLowerCase().replace(/\.(sh|bash|js|mjs|cjs|ts)$/u, "");
  return DSH_ENGINE_STEMS.has(stem);
}

export function dshMcpServerName(name: string, used: Set<string>): string {
  let cleaned = name.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 32);
  if (!SERVER_NAME_PATTERN.test(cleaned)) cleaned = "mcp";
  if (!used.has(cleaned)) {
    used.add(cleaned);
    return cleaned;
  }
  for (let index = 2; index < 100; index += 1) {
    const suffix = `_${index}`;
    const candidate = `${cleaned.slice(0, 32 - suffix.length)}${suffix}`;
    if (!used.has(candidate)) {
      used.add(candidate);
      return candidate;
    }
  }
  const fallback = `mcp_${used.size}`;
  used.add(fallback);
  return fallback;
}

function yamlString(value: string): string {
  return JSON.stringify(value);
}

function yamlEnv(env: DshStdioMcpServer["env"]): string {
  const entries = env.filter((item) => item.name.length > 0);
  if (entries.length === 0) return " {}";
  const lines = entries.map((item) => {
    const key = /^[A-Za-z_][A-Za-z0-9_]*$/.test(item.name) ? item.name : JSON.stringify(item.name);
    return `          ${key}: ${yamlString(item.value)}`;
  });
  return `\n${lines.join("\n")}`;
}

/** Cordis `--patch` overlay that loads one dsh-mcp-client instance per stdio mount. */
export function dshMcpPatchYaml(servers: readonly DshStdioMcpServer[]): string {
  const used = new Set<string>();
  const rows = servers.map((server, index) => {
    const serverName = dshMcpServerName(server.name, used);
    const argsYaml =
      server.args.length === 0
        ? " []"
        : `\n${server.args.map((arg) => `          - ${yamlString(arg)}`).join("\n")}`;
    return `    - id: ${DSH_MCP_PATCH_PREFIX}${index}-${serverName}
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: ${yamlString(serverName)}
        transport: stdio
        command: ${yamlString(server.command)}
        args:${argsYaml}
        env:${yamlEnv(server.env)}
        failOnStartupError: false`;
  });
  return `# BotFleet session/new mcpServers, delivered through dsh-mcp-client.\n- insert:\n${rows.join("\n")}\n`;
}

/** Write the overlay somewhere only this user can read it.
 *
 * The YAML carries every mount's environment verbatim, so for BotFleet's own
 * mounts it holds OMB_COMMS_TOKEN, OMB_CONTROL_TOKEN and any Composio key —
 * the same values treated as secrets everywhere else in the codebase.  Written
 * at the process umask into a shared temp directory it would sit there
 * world-readable for the whole DSH session, so it gets the pattern the
 * Antigravity driver already uses for a private file: a 0700 directory of its
 * own, and 0600 on the file.
 */
export function writeDshMcpPatch(servers: readonly DshStdioMcpServer[]): string {
  const directory = mkdtempSync(join(tmpdir(), DSH_MCP_PATCH_PREFIX));
  try {
    chmodSync(directory, 0o700);
  } catch {
    /* no POSIX mode bits on this platform */
  }
  const path = join(directory, `${DSH_MCP_PATCH_PREFIX}${randomUUID()}.yml`);
  try {
    writeFileSync(path, dshMcpPatchYaml(servers), { encoding: "utf8", mode: 0o600 });
    try {
      chmodSync(path, 0o600);
    } catch {
      /* no POSIX mode bits on this platform */
    }
  } catch (error) {
    rmSync(directory, { recursive: true, force: true });
    throw error;
  }
  return path;
}

/** The BotFleet-side spawn rewrite shape.  This is what BotFleet's driver
 * composes with `writeDshMcpPatch` and `dsh-acp-bridge` to satisfy stock
 * `dsh`.  Re-declared here so Clutch consumers can typecheck the spawn
 * rewrite without importing the ACP runtime. */
export interface DshSpawnRewrite {
  readonly cli: string;
  readonly args: readonly string[];
  readonly env?: Record<string, string | undefined>;
}
