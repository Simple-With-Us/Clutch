import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * The manual Dock-app updater shares the auto-updater's lock, because two
 * concurrent `npm ci` runs in one checkout can leave node_modules broken.  The
 * checkout here is deliberately not a git repo, so the script stops immediately
 * after the lock and never reaches npm or the Dock rebuild.
 */

const SCRIPT = join(__dirname, "..", "scripts", "update-mac-app.sh");

let home: string;
let live: string;

function runUpdate(): void {
  execFileSync("bash", [SCRIPT], {
    env: { ...process.env, HOME: home, CLUTCH_HOME: join(home, ".clutch"), CLUTCH_RUNTIME_ROOT: live },
    encoding: "utf8",
    stdio: "pipe",
  });
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "clutch-update-mac-"));
  live = join(home, "runtime");
  mkdirSync(live, { recursive: true });
});

afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

describe("update-mac-app.sh", () => {
  it("takes the auto-updater lock and releases it", () => {
    const lock = join(home, ".clutch", "auto-update.lock");
    expect(() => runUpdate()).toThrow();
    expect(existsSync(lock)).toBe(false);
  });

  it("waits for a held lock instead of running npm ci alongside it", async () => {
    const lock = join(home, ".clutch", "auto-update.lock");
    mkdirSync(lock, { recursive: true });

    const child = spawn("bash", [SCRIPT], {
      env: { ...process.env, HOME: home, CLUTCH_HOME: join(home, ".clutch"), CLUTCH_RUNTIME_ROOT: live },
      stdio: "ignore",
    });

    // While the lock is held the script can only wait, so it must still be
    // running after a couple of seconds.  Event-driven, not a wall-clock margin.
    const exitedWhileLocked = await new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => resolve(false), 2000);
      child.on("exit", () => {
        clearTimeout(timer);
        resolve(true);
      });
    });
    expect(exitedWhileLocked).toBe(false);
    expect(child.exitCode).toBeNull();

    rmSync(lock, { recursive: true, force: true });
    const code = await new Promise<number | null>((resolve) => child.on("exit", resolve));
    expect(code).not.toBe(0); // the fixture checkout is not a git repo
    expect(existsSync(lock)).toBe(false);
  }, 30000);

  it("leaves a native app in place without touching the checkout (C-78)", () => {
    const app = join(home, "Applications", "Clutch.app");
    mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
    writeFileSync(
      join(app, "Contents", "Info.plist"),
      `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>` +
        `<key>CFBundleIdentifier</key><string>codes.clutch.macos</string>` +
        `<key>DTXcodeBuild</key><string>27A9275</string>` +
        `</dict></plist>\n`,
    );
    writeFileSync(join(app, "Contents", "MacOS", "Clutch"), "fake-macho-binary\n");
    // The fixture checkout is not a git repo, so reaching git pull would
    // throw; the native guard exits 0 before that.
    expect(() => runUpdate()).not.toThrow();
    expect(existsSync(join(home, ".clutch", "auto-update.lock"))).toBe(false);
  });
});
