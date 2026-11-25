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
    // Z Code's own CLI has no ACP command (C-129); ACP comes from the
    // zcode-acp-server bridge, which drives `zcode app-server --stdio`.
    expect(support.defaultCli).toBe("zcode-acp-server");
  });

  it("declares a default model the options list contains", async () => {
    const { support } = await loadZcode();
    const ids = support.models.options.map((option) => option.id);
    expect(ids).toContain(support.models.default);
    expect(ids).toContain("glm-5.3");
  });

  it("leaves sign-in to the bridge and continues without one", async () => {
    const { support } = await loadZcode();
    expect(support.authFailure).toBe("continue");
    // The bridge reads Z Code's own sign-in from disk and never reads a key
    // from the environment, so no variable can stand for a sign-in.
    expect(support.isAuthenticated).toBeUndefined();
    expect(support.loginNote).toContain("zcode-acp setup --provider zai");
    expect(support.credentialEnv).not.toContain("ZAI_API_KEY");
  });

  it("classifies the failure text every provider shares", async () => {
    const { support } = await loadZcode();
    expect(support.classifyError?.({ message: "not logged in" })).toBe("invalid_credentials");
    expect(support.classifyError?.({ message: "rate limit exceeded" })).toBe("quota_or_region_restriction");
    expect(support.classifyError?.({ message: "upstream bad gateway" })).toBe("upstream_outage");
    expect(support.classifyError?.({ message: "unknown model" })).toBe("model_catalog_outage");
    expect(support.classifyError?.({ message: "something else" })).toBeUndefined();
  });

  it("installs the ACP bridge with npm on every platform", async () => {
    const { support } = await loadZcode();
    expect(support.install?.command).toEqual({
      darwin: "npm install -g zcode-acp-server",
      linux: "npm install -g zcode-acp-server",
      win32: "npm install -g zcode-acp-server",
    });
    expect(support.install?.needsNode).toBe(true);
    expect(support.install?.docsUrl).toBe("https://github.com/william0wang/zcode-acp");
  });
});
