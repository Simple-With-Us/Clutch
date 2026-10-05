import { describe, expect, it } from "vitest";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const PROFILES = join(__dirname, "..", "src", "profiles");

describe("tracked profiles", () => {
  const names = readdirSync(PROFILES, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();

  it("ship one headless profile per Shellular agent id", () => {
    expect(names).toEqual(["deepseek-headless", "minimax-headless"]);
  });

  it("name their settings file after the profile and point at the engine-home placeholder", () => {
    for (const name of names) {
      // sync-profiles.ts copySettingsFile builds the filename from the profile name.
      expect(existsSync(join(PROFILES, name, `settings-${name}.yaml`)), name).toBe(true);
      const patch = readFileSync(join(PROFILES, name, "cordis.patch.yml"), "utf8");
      expect(patch).toContain(`path: __DSH_HOME__/settings-${name}.yaml`);
      expect(patch).not.toMatch(/\/Users\/|~\/\.dsh/);
      const pkg = JSON.parse(readFileSync(join(PROFILES, name, "package.json"), "utf8")) as { name: string };
      expect(pkg.name).toBe(`dsh-profile-${name}`);
    }
  });
});

const PRESETS = join(__dirname, "..", "src", "presets");

describe("tracked presets", () => {
  it("tracks the fleet-recall agent preset with cordis composition and tools", () => {
    expect(existsSync(join(PRESETS, "fleet-recall", "preset.yml"))).toBe(true);
    expect(existsSync(join(PRESETS, "fleet-recall", "agent.cordis.yml"))).toBe(true);
    expect(existsSync(join(PRESETS, "fleet-recall", "plugins", "fleet-recall-tools.mjs"))).toBe(true);

    const presetYaml = readFileSync(join(PRESETS, "fleet-recall", "preset.yml"), "utf8");
    expect(presetYaml).toContain("name: Fleet Recall");

    const toolsMjs = readFileSync(join(PRESETS, "fleet-recall", "plugins", "fleet-recall-tools.mjs"), "utf8");
    expect(toolsMjs).toContain("recall_search");
    expect(toolsMjs).toContain("recall_stats");
    expect(toolsMjs).toContain("recall_contribute");
  });
});
