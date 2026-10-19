import { readFileSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { bundledEngineDir, loadEnginePlugins } from "../src/shared/engines/index.ts";
import { minimaxSupport } from "../src/minimax/acp/index.ts";
import type { AcpSupport } from "../src/shared/acp-core.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const LAUNCHER = join(ROOT, "scripts", "minimax-acp.sh");

/** Load the shipped MiniMax plugin out of the repo's own `engines/` directory. */
async function loadMinimax(): Promise<AcpSupport> {
  const result = await loadEnginePlugins({ dirs: [bundledEngineDir()] });
  expect(result.problems, JSON.stringify(result.problems, null, 2)).toEqual([]);
  const plugin = result.plugins.find((candidate) => candidate.id === "minimax");
  expect(plugin, "the minimax plugin is discoverable").toBeDefined();
  expect(plugin!.kind).toBe("module");
  expect(plugin!.origin).toBe("bundled");
  expect(plugin!.file.endsWith("engines/minimax.engine.mjs")).toBe(true);
  return plugin!.support;
}

describe("the shipped MiniMax plugin", () => {
  it("describes the dsh engine with MiniMax as the model, reached over ACP", async () => {
    const support = await loadMinimax();
    expect(support.driverKind).toBe("minimaxAgent");
    expect(support.displayName).toBe("Clutch (MiniMax)");
    // `scripts/minimax-acp.sh` -> `bridges/minimax/minimax-acp.py` ->
    // `dsh --profile minimax-headless`.  The frames Clutch sees are JSON-RPC;
    // the engine reaches MiniMax's HTTP API from inside its pi-ai route, which
    // is not this transport.  An earlier `minimax.http` label described the
    // retired HTTP-only adapter and mislabelled native transcripts.
    expect(support.nativeSource).toBe("minimax.acp");
    expect(support.defaultCli).toBe("minimax-acp.sh");
    expect(support.resumeMethod).toBe("session/resume");
    expect(support.mcpServers).toBe(true);
  });

  it("offers a default model that is actually in its catalog", async () => {
    const support = await loadMinimax();
    const ids = support.models.options.map((option) => option.id);
    expect(ids).toContain(support.models.default);
    expect(support.models.default).toBe("MiniMax-M2.7-highspeed");
  });

  it("opens the engine-wide image gate and keeps per-model truth exact", async () => {
    const support = await loadMinimax();
    // The gate is only the fallback for a row the catalog does not list, and
    // M3 really does take images.  The per-model map is what stops a
    // consumer offering an attachment the M2.7 family would refuse.
    // MiniMax-M3.1-Flash-Preview was retired on 2026-10-18 (BF-2494) and
    // must not reappear here without a verified stable replacement.
    expect(support.images).toBe(true);
    expect(support.perModelImages).toEqual({
      "MiniMax-M3": true,
      "MiniMax-M2.7-highspeed": false,
      "MiniMax-M2.7": false,
    });
  });

  it("gives MiniMax-M3 the full effort range and leaves the rest on the default", async () => {
    const support = await loadMinimax();
    expect(support.effortLevels).toEqual(["none"]);
    expect(support.perModelEffortLevels).toEqual({
      "MiniMax-M3": ["none", "low", "medium", "high", "max"],
    });
  });

  it("follows the CLUTCH_MINIMAX_API_KEY_NAME indirection for credentials", async () => {
    const support = await loadMinimax();
    expect(support.credentialEnv).toContain("MINIMAX_API_KEY");
    expect(support.credentialEnv).toContain("CLUTCH_MINIMAX_API_KEY_NAME");
    expect(support.isAuthenticated!({})).toBe(false);
    expect(support.isAuthenticated!({ MINIMAX_API_KEY: "k" })).toBe(true);
    // The operator can point the indirection at any variable, which is the whole
    // reason this engine needs the programmatic tier rather than a manifest.
    expect(support.isAuthenticated!({ CLUTCH_MINIMAX_API_KEY_NAME: "OTHER_KEY", OTHER_KEY: "k" })).toBe(true);
    expect(support.isAuthenticated!({ CLUTCH_MINIMAX_API_KEY_NAME: "OTHER_KEY" })).toBe(false);
  });

  it("publishes no ACP authMethods, so negotiation always returns nothing", async () => {
    const support = await loadMinimax();
    expect(support.pickAuthMethod!([])).toBeNull();
    expect(support.authFailure).toBe("continue");
    expect(support.loginNote).toMatch(/MINIMAX_API_KEY/);
  });

  it("defaults the env the Python bridge shares, without overwriting an operator", async () => {
    const support = await loadMinimax();
    const fresh: Record<string, string | undefined> = {};
    support.transformEnv!(fresh);
    expect(fresh.CLUTCH_MINIMAX_BASE_URL).toBe("https://api.minimax.io/v1");
    expect(fresh.CLUTCH_MINIMAX_MODEL).toBe("MiniMax-M2.7-highspeed");
    expect(fresh.CLUTCH_MINIMAX_API_KEY_NAME).toBe("MINIMAX_API_KEY");

    const chosen: Record<string, string | undefined> = {
      CLUTCH_MINIMAX_MODEL: "MiniMax-M3",
      CLUTCH_MINIMAX_API_KEY_NAME: "OTHER_KEY",
    };
    support.transformEnv!(chosen);
    expect(chosen.CLUTCH_MINIMAX_MODEL).toBe("MiniMax-M3");
    expect(chosen.CLUTCH_MINIMAX_API_KEY_NAME).toBe("OTHER_KEY");
  });

  it("classifies failures from an Error and from a plain ACP error object", async () => {
    const support = await loadMinimax();
    const REJECTION = "MiniMax: 401 unauthorized, invalid api key";
    // String() on a bare { code, message } is "[object Object]", so a
    // classifier that only unwraps Error loses the only text worth matching.
    expect(support.classifyError!(new Error(REJECTION))).toBe("invalid_credentials");
    expect(support.classifyError!({ code: -32000, message: REJECTION })).toBe("invalid_credentials");
    expect(support.classifyError!(new Error("insufficient balance"))).toBe("quota_or_region_restriction");
    expect(support.classifyError!(new Error("upgrade your plan"))).toBe("inactive_subscription");
    expect(support.classifyError!(new Error("upstream service unavailable"))).toBe("upstream_outage");
    expect(support.classifyError!(new Error("unknown model xyz"))).toBe("model_catalog_outage");
    expect(support.classifyError!("who knows")).toBeUndefined();
  });

  it("prepends the system prompt the way the dsh path expects", async () => {
    const support = await loadMinimax();
    expect(support.buildPromptText!({ system: "sys", text: "hi" })).toBe("sys\n\nhi");
    expect(support.buildPromptText!({ text: "hi" })).toBe("hi");
  });
});

// The plugin and the compiled driver are two public surfaces for one engine:
// the plugin is what runtime discovery sees, the driver is what BotFleet
// imports as `clutch/minimax/acp/driver`.  Both exist today, so the only thing
// keeping them honest is this file — a change to one without the other is a
// CI failure, not a silent divergence.
describe("the MiniMax plugin and the compiled driver agree", () => {
  it.each([
    "driverKind",
    "displayName",
    "images",
    "mcpServers",
    "defaultCli",
    "nativeSource",
    "resumeMethod",
    "authFailure",
    "loginNote",
    "credentialEnv",
    "effortLevels",
    "perModelEffortLevels",
    "perModelImages",
  ] as const)("carries the same %s", async (key) => {
    const support = await loadMinimax();
    expect(support[key]).toEqual(minimaxSupport[key]);
  });

  it("ships the same catalog, badge copy and all", async () => {
    const support = await loadMinimax();
    expect(support.models).toEqual(minimaxSupport.models);
    expect(support.resolveModels!({})).toEqual(minimaxSupport.resolveModels!({}));
  });

  it("installs the same bridge on every platform", async () => {
    const support = await loadMinimax();
    expect(support.install).toEqual(minimaxSupport.install);
    expect(support.install!.command.darwin).toContain("bridges/minimax/minimax-acp.py");
  });

  it("takes no spawn arguments, because the launcher carries the spawn contract", async () => {
    const support = await loadMinimax();
    expect(support.spawnArgs({ cli: "minimax-acp.sh" }, {})).toEqual([]);
    expect(support.spawnArgs({ cli: "minimax-acp.sh" }, {})).toEqual(minimaxSupport.spawnArgs({ cli: "minimax-acp.sh" }, {}));
  });

  it("transforms env identically", async () => {
    const support = await loadMinimax();
    const cases: Array<Record<string, string | undefined>> = [
      {},
      { MINIMAX_API_KEY: "k" },
      { CLUTCH_MINIMAX_MODEL: "MiniMax-M3" },
      { CLUTCH_MINIMAX_API_KEY_NAME: "OTHER_KEY", OTHER_KEY: "k" },
    ];
    for (const start of cases) {
      const pluginEnv = { ...start };
      const driverEnv = { ...start };
      support.transformEnv!(pluginEnv);
      minimaxSupport.transformEnv!(driverEnv);
      expect(pluginEnv).toEqual(driverEnv);
    }
  });

  it("reports authentication identically", async () => {
    const support = await loadMinimax();
    const cases: Array<Record<string, string | undefined>> = [
      {},
      { MINIMAX_API_KEY: "k" },
      { MINIMAX_API_KEY: "k", CLUTCH_MINIMAX_API_KEY_NAME: "OTHER_KEY" },
      { CLUTCH_MINIMAX_API_KEY_NAME: "OTHER_KEY", OTHER_KEY: "k" },
      { CLUTCH_MINIMAX_API_KEY_NAME: "OTHER_KEY" },
    ];
    for (const env of cases) {
      expect(support.isAuthenticated!(env)).toBe(minimaxSupport.isAuthenticated!(env));
    }
  });

  it("classifies errors identically", async () => {
    const support = await loadMinimax();
    const cases: unknown[] = [
      new Error("unauthorized"),
      new Error("service unavailable"),
      new Error("rate limit exceeded"),
      new Error("unknown model"),
      { code: -32000, message: "invalid api key" },
      { code: -32603, message: "insufficient balance" },
      { message: "upstream overloaded" },
      "quota exhausted",
      "nothing interesting",
      {},
      undefined,
    ];
    for (const value of cases) {
      expect(support.classifyError!(value)).toBe(minimaxSupport.classifyError!(value));
    }
  });
});

describe("the MiniMax launcher", () => {
  it("is executable and keeps stdout clean for JSON-RPC", () => {
    expect(statSync(LAUNCHER).mode & 0o111).toBeTruthy();
    const source = readFileSync(LAUNCHER, "utf8");
    expect(source.startsWith("#!/usr/bin/env bash")).toBe(true);
    // Every diagnostic must go to stderr; stdout carries ACP.
    expect(source).not.toMatch(/^\s*echo\s/m);
  });

  it("does source the DSH engine home, because this engine is a dsh profile", () => {
    // Muse and Grok must stay out of it, but MiniMax drives
    // `dsh --profile minimax-headless` with DSH_HOME at $CLUTCH_HOME/dsh, so
    // it needs the same engine home the DeepSeek launcher sets up.
    expect(readFileSync(LAUNCHER, "utf8")).toMatch(/source .*lib\/clutch-env\.sh/);
  });
});