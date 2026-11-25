import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("clutch-pair-ios CLI", () => {
  const dirs: string[] = [];
  afterEach(() => {
    for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  it("reports a tokenless launch URL as a clean error, not a crash", () => {
    const dir = mkdtempSync(join(tmpdir(), "pair-ios-test-"));
    dirs.push(dir);
    const launchFile = join(dir, "web-launch-url");
    writeFileSync(launchFile, "https://example.ts.net:3180/no-token-here");
    const result = spawnSync(join(ROOT, "node_modules", ".bin", "tsx"), [join(ROOT, "src", "web", "pair-ios.ts"), "--print"], {
      cwd: ROOT,
      encoding: "utf8",
      env: { ...process.env, CLUTCH_LAUNCH_URL_FILE: launchFile },
    });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("launch URL has no token");
    expect(result.stderr).not.toContain("at main (");
  });
});
