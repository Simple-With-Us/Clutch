import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { bundledEngineDir, loadEnginePlugins } from "../src/shared/engines/index.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/**
 * Load the shipped plugin from the repo's own `engines/` directory.
 *
 * The shape mirrors `muse-code-plugin.test.ts`: the plugin is discovered the
 * way runtime discovery finds it, and every claim about the engine is read
 * off the loaded plugin rather than off the file's own text.
 */
async function loadZcode() {
  const result = await loadEnginePlugins({ dirs: [bundledEngineDir()] });
  expect(result.problems, JSON.stringify(result.problems, null, 2)).toEqual([]);
  const plugin = result.plugins.find((candidate) => candidate.id === "zcode");
  expect(plugin, "zcode plugin is discoverable").toBeDefined();
  return plugin!;
}

describe("the shipped Z Code plugin", () => {
  it("loads from engines/ as a declarative manifest", async () => {
    const plugin = await loadZcode();
    expect(plugin.kind).toBe("manifest");
    expect(plugin.origin).toBe("bundled");
    expect(plugin.file.endsWith("engines/zcode.engine.json")).toBe(true);
  });

  it("describes the native ACP shape, not a dsh profile", async () => {
    const { support } = await loadZcode();
    expect(support.driverKind).toBe("zcodeAgent");
    expect(support.displayName).toBe("Z Code");
    expect(support.nativeSource).toBe("zcode.acp");
    expect(support.defaultCli).toBe("zcode");
  });

  it("declares a default model the options list contains", async () => {
    const { support } = await loadZcode();
    const ids = support.models.options.map((option) => option.id);
    expect(ids).toContain(support.models.default);
    expect(ids).toContain("glm-5.3");
  });

  it("authenticates from the environment and continues without a key", async () => {
    const { support } = await loadZcode();
    expect(support.authFailure).toBe("continue");
    // The CLI's own login is a credential too, so the plugin declares the
    // key check without gating the engine on it.
    expect(support.isAuthenticated?.({})).toBe(false);
    expect(support.isAuthenticated?.({ ZAI_API_KEY: "present" })).toBe(true);
  });

  it("classifies the failure text every provider shares", async () => {
    const { support } = await loadZcode();
    expect(support.classifyError?.({ message: "not logged in" })).toBe("invalid_credentials");
    expect(support.classifyError?.({ message: "rate limit exceeded" })).toBe("quota_or_region_restriction");
    expect(support.classifyError?.({ message: "upstream bad gateway" })).toBe("upstream_outage");
    expect(support.classifyError?.({ message: "unknown model" })).toBe("model_catalog_outage");
    expect(support.classifyError?.({ message: "something else" })).toBeUndefined();
  });

  it("ships no installer command until the CLI's own one is known", async () => {
    const { support } = await loadZcode();
    // Inventing an npm package name here would tell the owner to install
    // something that may not exist; the docs name the CLI instead.
    expect(support.install).toBeUndefined();
  });
});
