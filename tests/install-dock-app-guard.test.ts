import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * C-78: install-dock-app.sh installs the deprecated WKWebView shell to the
 * same path the native app uses.  It must refuse to pave a native install
 * unless the operator opts in explicitly.
 */

const SCRIPT = join(__dirname, "..", "scripts", "install-dock-app.sh");

let home: string;
let live: string;

function installApp(bundleId: string, xcode: boolean): void {
  const app = join(home, "Applications", "Clutch.app");
  mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
  writeFileSync(
    join(app, "Contents", "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>` +
      `<key>CFBundleIdentifier</key><string>${bundleId}</string>` +
      (xcode ? `<key>DTXcodeBuild</key><string>27A9275</string>` : ``) +
      `</dict></plist>\n`,
  );
  writeFileSync(join(app, "Contents", "MacOS", "Clutch"), "fake-macho-binary\n");
}

function attempt(extraEnv: Record<string, string> = {}): { code: number; stderr: string } {
  try {
    execFileSync("bash", [SCRIPT], {
      env: { ...process.env, HOME: home, CLUTCH_RUNTIME_ROOT: live, ...extraEnv },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { code: 0, stderr: "" };
  } catch (error) {
    const failed = error as { status?: number; stderr?: string };
    return { code: failed.status ?? 1, stderr: String(failed.stderr ?? "") };
  }
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "clutch-install-dock-"));
  live = join(home, "runtime");
  mkdirSync(live, { recursive: true });
});

afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

describe("install-dock-app.sh native guard", () => {
  it("refuses to pave a native app without an explicit override", () => {
    installApp("codes.clutch.macos", true);
    const { code, stderr } = attempt();
    expect(code).not.toBe(0);
    expect(stderr).toMatch(/refusing to install the Dock shell over the native/);
  });

  it("honours the explicit override and moves past the guard", () => {
    installApp("codes.clutch.macos", true);
    // Past the guard the fixture fails on the missing shell sources, which
    // proves the guard (not the build) was what stopped the previous case.
    const { code, stderr } = attempt({ CLUTCH_DOCK_OVERWRITE_NATIVE: "1" });
    expect(code).not.toBe(0);
    expect(stderr).not.toMatch(/refusing to install the Dock shell over the native/);
    expect(stderr).toMatch(/missing .*clutch-icon-1024\.png/);
  });

  it("still serves a shell install with no native app present", () => {
    const { code, stderr } = attempt();
    expect(code).not.toBe(0);
    expect(stderr).not.toMatch(/refusing to install the Dock shell over the native/);
    expect(stderr).toMatch(/missing .*clutch-icon-1024\.png/);
  });
});
