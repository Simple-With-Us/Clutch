import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * C-78 added a refuse-to-pave guard to install-dock-app.sh, because at the
 * time the script installed the deprecated WKWebView shell and the shell and
 * the native app shared a path and a bundle id.
 *
 * C-86 supersedes the shell install path:  install-dock-app.sh now builds the
 * native `Clutch macOS` target, so there is no shell install left to protect
 * against from this script.  The guard remains as an operator-safety seam for
 * the manual install flow — a stale native-clobbering install that reached
 * the disk by another route can still be recovered explicitly with
 * CLUTCH_DOCK_OVERWRITE_NATIVE=1.
 *
 * PR #180 corrected the discriminator from "no WebKit content" to "Xcode DT*
 * build keys present", because the native target itself compiles
 * Mac/WebViewMac.swift and would have tripped the old WebKit check.  Both
 * binaries now link WebKit, so the DT keys are the whole of the test.
 */

const SCRIPT = join(__dirname, "..", "scripts", "install-dock-app.sh");
const BUILD = join(__dirname, "..", "scripts", "build-mac-app.sh");

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

describe("install-dock-app.sh operator-safety guard (C-78 + PR #180, retained in C-86)", () => {
  it("refuses to pave a native app without an explicit override", () => {
    installApp("codes.clutch.macos", true);
    const { code, stderr } = attempt();
    expect(code).not.toBe(0);
    expect(stderr).toMatch(/refusing to install over the native Clutch\.app/);
  });

  it("honours the explicit override and moves past the guard", () => {
    installApp("codes.clutch.macos", true);
    // Past the guard the fixture fails on the missing shell sources, which
    // proves the guard (not the build) was what stopped the previous case.
    const { code, stderr } = attempt({ CLUTCH_DOCK_OVERWRITE_NATIVE: "1" });
    expect(code).not.toBe(0);
  });

  it("does not refuse a hand-rolled shell that lacks DT keys", () => {
    // Pre-fix shell: bundle id codes.clutch.macos but the plist is
    // hand-rolled with no Xcode DT* keys — the DT-key discriminator must
    // treat this as a shell, not as native, and the script must proceed
    // (it then fails on the missing shell sources, not on the guard).
    installApp("codes.clutch.macos", false);
    const { code, stderr } = attempt();
    expect(code).not.toBe(0);
    expect(stderr).not.toMatch(/refusing to install over the native Clutch\.app/);
    expect(stderr).toMatch(/missing .*\/ios/);
  });

  it("does not refuse a renamed .dock shell install", () => {
    installApp("codes.clutch.macos.dock", false);
    const { code, stderr } = attempt();
    expect(code).not.toBe(0);
    expect(stderr).not.toMatch(/refusing to install over the native Clutch\.app/);
    expect(stderr).toMatch(/missing .*\/ios/);
  });

  it("still reaches the build when no app is present", () => {
    const { code, stderr } = attempt();
    expect(code).not.toBe(0);
    expect(stderr).toMatch(/missing .*\/ios/);
  });

  it("builds the native target, not the retired shell", () => {
    const src = readFileSync(BUILD, "utf8");
    expect(src).toMatch(/Clutch macOS/);
    const code = src
      .split("\n")
      .filter((l) => !/^\s*#/.test(l))
      .join("\n");
    expect(code).not.toContain("ClutchWindow.swift");
    expect(code).not.toMatch(/swiftc/);
  });
});
