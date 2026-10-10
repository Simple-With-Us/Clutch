import { describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * `npm run sync` copied nothing for days on this Mac because the destination
 * profile directory holds engine-created trees (`.dsh-module-fallback/`,
 * `node_modules/`) and the pre-copy cleanup called `rmSync` on them without
 * `recursive`, which throws ERR_FS_EISDIR and aborts the whole run.  This test
 * runs the real script against a throwaway CLUTCH_HOME that has both trees.
 */

const ROOT = join(__dirname, "..");
const SCRIPT = join(ROOT, "scripts", "sync-profiles.ts");
const TSX = join(ROOT, "node_modules", ".bin", "tsx");

describe("sync-profiles.ts", () => {
  it("syncs over the engine's runtime directories instead of failing with EISDIR", () => {
    const home = mkdtempSync(join(tmpdir(), "clutch-sync-"));
    try {
      const profile = join(home, "dsh", "profiles", "deepseek-headless");
      const fallback = join(profile, ".dsh-module-fallback");
      mkdirSync(join(fallback, "node_modules"), { recursive: true });
      mkdirSync(join(profile, "node_modules"), { recursive: true });
      writeFileSync(join(profile, "stale.yml"), "a tracked file that no longer exists\n");

      const env: NodeJS.ProcessEnv = { ...process.env, CLUTCH_HOME: home };
      // Force the offline settings path so the test never waits on Infisical.
      delete env.INFISICAL_CLIENT_ID;
      delete env.INFISICAL_CLIENT_SECRET;
      execFileSync(TSX, [SCRIPT], { env, stdio: "pipe" });

      // The engine's trees are left alone.
      expect(statSync(fallback).isDirectory()).toBe(true);
      expect(statSync(join(profile, "node_modules")).isDirectory()).toBe(true);
      // Tracked files are refreshed, and one that no longer exists is cleared.
      expect(existsSync(join(profile, "cordis.yml"))).toBe(true);
      expect(existsSync(join(profile, "stale.yml"))).toBe(false);
      // Presets land in the same run that used to abort before reaching them.
      const preset = join(home, "dsh", ".agent-presets", "fleet-recall");
      expect(existsSync(join(preset, "preset.yml"))).toBe(true);
      expect(existsSync(join(preset, "plugins", "fleet-recall-tools.mjs"))).toBe(true);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  }, 60000);
});
