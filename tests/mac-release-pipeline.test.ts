import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * C-86: the native `Clutch macOS` app had no release pipeline, and the one that
 * existed shipped a retired WKWebView shell under the native app's own bundle
 * id.  These assertions are static and cheap on purpose: every one of them
 * pins a specific defect the issue names, so a future edit that reintroduces
 * the shell, narrows the path filters, or lets the two builds collide on one
 * identifier fails here rather than in a Mac user's Dock.
 */

const ROOT = join(__dirname, "..");
const read = (...p: string[]) => readFileSync(join(ROOT, ...p), "utf8");

const BUILD = read("scripts", "build-mac-app.sh");
const INSTALL = read("scripts", "install-dock-app.sh");
const UPDATER = read("scripts", "auto-update-mac.sh");
const WORKFLOW = read(".github", "workflows", "mac-app-build.yml");
const PROJECT_YML = read("ios", "project.yml");

function dockRe(): RegExp {
  const m = UPDATER.match(/^DOCK_RE='(.*)'$/m);
  expect(m, "auto-update-mac.sh must define DOCK_RE").toBeTruthy();
  return new RegExp(m![1]);
}

/** Script body with full-line comments removed, so prose in a header that
 * explains what a script replaced is not mistaken for a use of it. */
const code = (src: string) =>
  src
    .split("\n")
    .filter((l) => !/^\s*#/.test(l))
    .join("\n");

describe("build-mac-app.sh builds the native target", () => {
  it("compiles the Clutch macOS scheme rather than the retired shell", () => {
    expect(BUILD).toMatch(/-scheme "\$SCHEME"/);
    expect(BUILD).toMatch(/SCHEME="\$\{CLUTCH_MAC_SCHEME:-Clutch macOS\}"/);
    expect(BUILD).toContain("xcodebuild");
  });

  it("never compiles src/web/dock-app/ClutchWindow.swift", () => {
    expect(code(BUILD)).not.toContain("ClutchWindow.swift");
    expect(code(BUILD)).not.toMatch(/swiftc/);
    expect(code(BUILD)).not.toContain("src/web/dock-app");
  });

  it("keeps every env seam the publish job and installer already pass", () => {
    for (const seam of [
      "CLUTCH_RUNTIME_ROOT",
      "CLUTCH_MAC_APP_OUT",
      "CLUTCH_MAC_KILL_RUNNING",
      "CLUTCH_MAC_BUILD_COMMIT",
      "CLUTCH_MAC_MANIFEST_OUT",
      "CLUTCH_MAC_SIGN",
      "CLUTCH_MAC_CODESIGN_IDENTITY",
    ]) {
      expect(BUILD).toContain(seam);
    }
  });

  it("keeps the release contract fetch-ci-mac-app.sh verifies", () => {
    // fetch-ci-mac-app.sh hard-requires a release asset named Clutch.app at
    // the root of Clutch-mac-arm64.zip and a manifest carrying commit + sha256.
    expect(BUILD).toMatch(/PRODUCT_NAME|Build\/Products\/\$\{CONFIGURATION\}\/Clutch\.app/);
    for (const key of ["schemaVersion", "commit", "signedAs", "bundleId"]) {
      expect(BUILD).toContain(key);
    }
  });
});

describe("the two builds cannot share one bundle identifier", () => {
  it("reads bundleId off the built app instead of asserting it", () => {
    expect(BUILD).toContain("CFBundleIdentifier");
    expect(BUILD).toMatch(/PlistBuddy/);
    // The whole point: the manifest must not be able to claim an identity the
    // binary does not carry.
    expect(BUILD).not.toMatch(/"bundleId":\s*"codes\.clutch\.macos"/);
  });

  it("declares codes.clutch.macos exactly once, on the native target", () => {
    const hits = PROJECT_YML.split("\n").filter((l) => l.includes("PRODUCT_BUNDLE_IDENTIFIER: codes.clutch.macos"));
    expect(hits).toHaveLength(1);
  });

  it("no longer hands the shipped app a hand-written Info.plist", () => {
    // The shell wrote its own plist, which is how a second bundle id got in.
    expect(BUILD).not.toContain("Contents/Info.plist <<");
    expect(INSTALL).not.toContain("WKWebView shell");
  });
});

describe("the auto-updater can see the native Mac sources", () => {
  it("rebuilds the Mac app when the Mac target's own sources change", () => {
    const re = dockRe();
    for (const p of [
      "ios/Mac/WebViewMac.swift",
      "ios/App/Services/DshHostClient.swift",
      "ios/App/Views/DshHostView.swift",
      "ios/Resources/x",
      "ios/Assets.xcassets/AppIcon.appiconset/Contents.json",
      "ios/project.yml",
      "ios/Clutch.xcodeproj/project.pbxproj",
    ]) {
      expect(re.test(p), `DOCK_RE must match ${p}`).toBe(true);
    }
  });

  it("still rebuilds for the legacy dock inputs", () => {
    const re = dockRe();
    for (const p of [
      "src/web/dock-app/ClutchWindow.swift",
      "assets/clutch-icon-1024.png",
      "scripts/install-dock-app.sh",
      "scripts/build-mac-app.sh",
    ]) {
      expect(re.test(p), `DOCK_RE must match ${p}`).toBe(true);
    }
  });

  it("leaves docs, tests and CI config to the web-server filter", () => {
    const re = dockRe();
    for (const p of ["docs/dsh-native-clients.md", "tests/mac-release-pipeline.test.ts", "README.md"]) {
      expect(re.test(p), `DOCK_RE must not match ${p}`).toBe(false);
    }
  });
});

describe("the release workflow can see the native Mac sources", () => {
  const filterBlock = WORKFLOW.split("workflow_dispatch")[0] ?? WORKFLOW;

  it("watches the Mac target's own inputs", () => {
    for (const p of [
      "ios/Mac/**",
      "ios/App/**",
      "ios/Resources/**",
      "ios/Assets.xcassets/**",
      "ios/project.yml",
      "ios/Clutch.xcodeproj/**",
    ]) {
      expect(filterBlock).toContain(p);
    }
  });

  it("no longer gates on the retired shell directory", () => {
    expect(filterBlock).not.toContain("src/web/dock-app/**");
    expect(filterBlock).not.toContain("assets/clutch-icon-1024.png");
  });

  it("still runs build-mac-app.sh for both build and PR compile jobs", () => {
    // Two invocations: the Release build and the PR ad-hoc compile smoke.  The
    // path filters mention the script too, so count the run steps specifically.
    expect(WORKFLOW.match(/run: bash scripts\/build-mac-app\.sh/g) ?? []).toHaveLength(2);
  });
});