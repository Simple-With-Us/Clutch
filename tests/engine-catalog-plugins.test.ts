import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

import {
  buildEngineCatalog,
  loadEnginePluginReport,
  type EnginePluginReport,
} from "../src/web/engine-catalog.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const BUNDLED = join(ROOT, "engines");

const temps: string[] = [];

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "clutch-engine-plugins-"));
  temps.push(dir);
  return dir;
}

afterEach(() => {
  while (temps.length > 0) rmSync(temps.pop()!, { recursive: true, force: true });
});

/** A valid manifest for the Muse engine, as a drop-in would ship it. */
const MUSE_MANIFEST = {
  $schema: "clutch.engine/v1",
  id: "muse-code",
  driverKind: "museCodeAgent",
  displayName: "Muse Code",
  defaultCli: "muse-code-acp.sh",
  nativeSource: "muse.acp",
  models: {
    default: "muse-floor-model",
    options: [{ id: "muse-floor-model", label: "Muse Floor Model" }],
  },
};

function writePlugin(dir: string, name: string, manifest: unknown): void {
  writeFileSync(join(dir, name), `${JSON.stringify(manifest, null, 2)}\n`);
}

/**
 * Catalog sources that start nothing: every launcher points at a path that
 * is not there, so the only engine that can be available is Muse.
 */
function sources(plugins?: EnginePluginReport) {
  return {
    launchers: {
      deepseek: { command: "/unused", args: [] },
      minimax: { command: "/unused", args: [] },
      mcode: { command: "/unused", args: [] },
      muse: { command: "/never-start-muse", args: [] },
      zcode: { command: "/unused", args: ["acp"] },
    },
    available: { deepseek: false, minimax: false, mcode: false, muse: true, zcode: false },
    probeCwd: "/unused",
    readMuseCatalog: () => [],
    ...(plugins ? { plugins } : {}),
  };
}

describe("engine plugin wiring", () => {
  it("maps the shipped plugins onto the engines Clutch runs", async () => {
    const report = await loadEnginePluginReport({ dirs: [BUNDLED] });

    const mapped = report.contributions.map((entry) => [entry.pluginId, entry.engine]);
    expect(mapped).toContainEqual(["muse-code", "muse"]);
    expect(mapped).toContainEqual(["minimax", "minimax"]);
    expect(mapped).toContainEqual(["zcode", "zcode"]);
    expect(report.unmapped).toEqual([]);
    expect(report.problems).toEqual([]);
  });

  it("reports a plugin that names no engine Clutch runs, and never makes one up", async () => {
    const dir = tempDir();
    writePlugin(dir, "grok.engine.json", { ...MUSE_MANIFEST, id: "grok" });

    const report = await loadEnginePluginReport({ dirs: [dir] });
    expect(report.unmapped.map((entry) => entry.id)).toEqual(["grok"]);
    expect(report.contributions).toEqual([]);

    const catalog = await buildEngineCatalog(sources(report));
    expect(catalog.engines.map((engine) => engine.id)).toEqual(["deepseek", "minimax", "mcode", "muse", "zcode"]);
    expect(catalog.engines.some((engine) => engine.id === "grok")).toBe(false);
  });

  it("lets the Muse plugin contribute to the muse engine id", async () => {
    const dir = tempDir();
    writePlugin(dir, "muse-code.engine.json", MUSE_MANIFEST);

    const report = await loadEnginePluginReport({ dirs: [dir] });
    expect(report.contributions.map((entry) => entry.engine)).toEqual(["muse"]);

    const catalog = await buildEngineCatalog(sources(report));
    const muse = catalog.engines.find((engine) => engine.id === "muse");
    expect(muse?.models.map((model) => model.id)).toContain("muse-floor-model");
  });

  it("keeps the catalog intact when a plugin file does not load", async () => {
    const dir = tempDir();
    writeFileSync(join(dir, "broken.engine.json"), "{ not json\n");
    writePlugin(dir, "muse-code.engine.json", MUSE_MANIFEST);

    const report = await loadEnginePluginReport({ dirs: [dir] });
    expect(report.problems.map((problem) => problem.file)).toEqual([join(dir, "broken.engine.json")]);
    expect(report.contributions.map((entry) => entry.pluginId)).toEqual(["muse-code"]);

    const catalog = await buildEngineCatalog(sources(report));
    expect(catalog.engines.map((engine) => engine.id)).toEqual(["deepseek", "minimax", "mcode", "muse", "zcode"]);
    expect(catalog.engines.find((engine) => engine.id === "muse")?.models.map((model) => model.id))
      .toContain("muse-floor-model");
  });

  it("leaves the dsh engines' model list to their profile", async () => {
    const report = await loadEnginePluginReport({ dirs: [BUNDLED] });

    const catalog = await buildEngineCatalog(sources(report));
    const minimax = catalog.engines.find((engine) => engine.id === "minimax");
    // The MiniMax plugin lists a model the minimax-headless profile does
    // not declare, so the profile keeps owning the list.
    expect(minimax?.models.map((model) => model.id)).toEqual(["MiniMax-M3.1-Flash", "MiniMax-M3"]);
  });
});
