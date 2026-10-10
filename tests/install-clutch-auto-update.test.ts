import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * The LaunchAgent is what makes the deployment unattended, so the plist it
 * writes is checked directly (rendered without touching launchd) and the
 * file-writing mode is exercised against a throwaway HOME.  A dummy label keeps
 * the test away from the real com.jay.clutch-auto-update job.
 */

const SCRIPT = join(__dirname, "..", "scripts", "install-clutch-auto-update.sh");
const UPDATER = join(__dirname, "..", "scripts", "auto-update-mac.sh");
const LABEL = "com.jay.clutch-auto-update.test";

let home: string;

function run(...args: string[]): string {
  return execFileSync("bash", [SCRIPT, ...args], {
    // GIT_* isolation is not needed here, but HOME must be the fixture.
    env: { ...process.env, HOME: home, CLUTCH_AUTO_UPDATE_LABEL: LABEL },
    encoding: "utf8",
  });
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "clutch-autoupdate-install-"));
});

afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

describe("install-clutch-auto-update.sh", () => {
  it("renders a 5-minute RunAtLoad LaunchAgent pointing at the stable live copy", () => {
    const plist = run("--print-plist");
    expect(plist).toContain(`<string>${LABEL}</string>`);
    expect(plist).toContain("<key>StartInterval</key>\n  <integer>300</integer>");
    expect(plist).toContain("<key>RunAtLoad</key>\n  <true/>");
    expect(plist).toContain(`<string>${home}/apps/clutch-auto-update.sh</string>`);
    // The live copy must sit outside the checkout the updater moves.
    expect(plist).not.toContain("clutch-runtime/scripts/auto-update-mac.sh</string>");
  });

  it("writes the live copy and the plist without loading anything", () => {
    const output = run("--no-load");
    const live = join(home, "apps", "clutch-auto-update.sh");
    const plist = join(home, "Library", "LaunchAgents", `${LABEL}.plist`);

    expect(existsSync(live)).toBe(true);
    expect(statSync(live).mode & 0o111).not.toBe(0);
    expect(readFileSync(live, "utf8")).toBe(readFileSync(UPDATER, "utf8"));
    expect(existsSync(plist)).toBe(true);
    expect(readFileSync(plist, "utf8")).toBe(run("--print-plist"));
    expect(output).toContain("not loaded");
  });

  it("removes both files on --uninstall", () => {
    run("--no-load");
    const live = join(home, "apps", "clutch-auto-update.sh");
    const plist = join(home, "Library", "LaunchAgents", `${LABEL}.plist`);
    run("--uninstall");
    expect(existsSync(live)).toBe(false);
    expect(existsSync(plist)).toBe(false);
  });
});
