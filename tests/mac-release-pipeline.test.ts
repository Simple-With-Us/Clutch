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
const UPDATE_CMD = read("scripts", "update-mac-app.sh");
const WORKFLOW = read(".github", "workflows", "mac-app-build.yml");
const PROJECT_YML = read("ios", "project.yml");
const PBXPROJ = read("ios", "Clutch.xcodeproj", "project.pbxproj");

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

describe("build-mac-app.sh protects the installed app and the build", () => {
  const body = code(BUILD);
  const at = (needle: string) => {
    const i = body.indexOf(needle);
    expect(i, `build-mac-app.sh must contain ${needle}`).toBeGreaterThan(-1);
    return i;
  };

  it("stops the running app only after xcodebuild has produced a replacement", () => {
    // A failed build used to leave the Mac with no app, and the auto-updater
    // does not retry a commit it already attempted.
    const build = at('xcodebuild "${XCODE_ARGS[@]}" build');
    const produced = at('if [[ ! -d "$BUILT" ]]');
    const kill = at("pkill");
    const replace = at('rm -rf "$APP"');
    expect(body.match(/pkill/g)).toHaveLength(1);
    expect(kill).toBeGreaterThan(build);
    expect(kill).toBeGreaterThan(produced);
    expect(kill).toBeLessThan(replace);
  });

  it("checks for a usable xcodebuild before touching anything", () => {
    const preflight = at("xcodebuild -version");
    expect(preflight).toBeLessThan(at('xcodebuild "${XCODE_ARGS[@]}" build'));
    expect(preflight).toBeLessThan(at("xcodegen generate"));
    expect(BUILD).toMatch(/full Xcode/);
    expect(BUILD).toMatch(/xcode-select/);
  });

  it("keeps DerivedData where the exit trap does not delete it", () => {
    const dd = BUILD.split("\n").find((l) => l.startsWith("DD="));
    expect(dd, "DD must be assigned").toBeTruthy();
    expect(dd).not.toContain("TMP");
    expect(dd).toContain("CLUTCH_MAC_DERIVED_DATA");
    expect(body).not.toContain("mktemp");
    expect(body).not.toMatch(/trap '[^']*rm -rf "\$DD"/);
  });

  it("removes a stale product before building so it can never be shipped as this commit", () => {
    expect(at('rm -rf "$BUILT"')).toBeLessThan(at('xcodebuild "${XCODE_ARGS[@]}" build'));
  });

  it("stamps 0.1.0 with the Central merge-minute build number and lets explicit values win", () => {
    expect(body).toContain("show -s --format=%ct");
    expect(body).toContain("TZ=America/Chicago");
    expect(body).toMatch(/BUILD_NUMBER="\$\{CLUTCH_MAC_BUILD_NUMBER:-\$DEFAULT_BUILD_NUMBER\}"/);
    expect(body).toContain('MARKETING_VERSION_VALUE="${CLUTCH_MAC_MARKETING_VERSION:-0.1.0}"');
    expect(body).toContain("must be a 12-digit YYYYMMDDHHMM value");
    expect(body).toContain('"CURRENT_PROJECT_VERSION=${BUILD_NUMBER}"');
    expect(body).toContain('"MARKETING_VERSION=${MARKETING_VERSION_VALUE}"');
  });

  it("records both version fields in the release manifest", () => {
    expect(body).toContain('"marketingVersion": marketing_version');
    expect(body).toContain('"buildNumber": build_number');
  });

  it("serializes builds that share the DerivedData directory", () => {
    // Two overlapping runs (the updater's rebuild, update:mac, clutch-install-dock)
    // would otherwise delete or half-overwrite each other's product.
    expect(body).toContain("clutch-build-lock.sh");
    const acquire = at('clutch_build_lock_acquire "$DD/.build.lock"');
    expect(acquire).toBeGreaterThan(at('mkdir -p "$DD"'));
    expect(acquire).toBeLessThan(at('rm -rf "$BUILT"'));
    expect(body).toMatch(/trap '[^']*clutch_build_lock_release[^']*' EXIT/);
  });

  it("regenerates the project from project.yml when asked, or when it is missing", () => {
    expect(body).toContain('"${CLUTCH_MAC_REGENERATE_PROJECT:-0}" == "1"');
    expect(body).toContain('! -d "$PROJECT"');
    expect(body).toContain("xcodegen generate");
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

  it("does not ship the iOS target's Info.plist inside the Mac bundle", () => {
    // XcodeGen adds every file under a source path, App/Info.plist included,
    // to Copy Bundle Resources.  Released Mac apps then carried a second,
    // foreign Contents/Resources/Info.plist with iOS-only keys and an
    // unexpanded $(PRODUCT_BUNDLE_IDENTIFIER).
    const macTarget = PROJECT_YML.split(/^ {2}Clutch macOS:$/m)[1]?.split(/^[a-z]/m)[0] ?? "";
    expect(macTarget, "Clutch macOS target in project.yml").toContain("path: App");
    expect(macTarget).toMatch(/excludes:[\s\S]*?- Info\.plist/);
    expect(PBXPROJ).not.toContain("Info.plist in Resources");
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

  it("rebuilds for the scripts that build the bundle", () => {
    const re = dockRe();
    for (const p of ["scripts/install-dock-app.sh", "scripts/build-mac-app.sh", "scripts/lib/clutch-build-lock.sh"]) {
      expect(re.test(p), `DOCK_RE must match ${p}`).toBe(true);
    }
  });

  it("does not react to paths CI publishes no Mac build for", () => {
    // do_dock tries the CI artifact first.  A path outside the release
    // workflow's filter never has one, so matching it would force a local
    // native build and app swap for a file that is in no bundle.
    const re = dockRe();
    for (const p of [
      "src/web/dock-app/ClutchWindow.swift",
      "assets/clutch-icon-1024.png",
      "scripts/update-mac-app.sh",
    ]) {
      expect(re.test(p), `DOCK_RE must not match ${p}`).toBe(false);
    }
  });

  it("leaves docs, tests and CI config to the web-server filter", () => {
    const re = dockRe();
    for (const p of ["docs/dsh-native-clients.md", "tests/mac-release-pipeline.test.ts", "README.md"]) {
      expect(re.test(p), `DOCK_RE must not match ${p}`).toBe(false);
    }
  });
});

describe("the local rebuild fallback refreshes an installed native app", () => {
  it("lets install-dock-app.sh replace it from both updaters", () => {
    // install-dock-app.sh refuses to pave a native install unless told to.  The
    // updaters only reach it when no CI build exists yet, and without the
    // override that fallback refuses the app it is meant to refresh.
    expect(code(UPDATER)).toMatch(/CLUTCH_DOCK_OVERWRITE_NATIVE=1 bash scripts\/install-dock-app\.sh/);
    expect(code(UPDATER)).toMatch(/CLUTCH_DOCK_OVERWRITE_NATIVE=1 bash -c "\$CMD_DOCK"/);
    expect(code(UPDATE_CMD)).toMatch(/CLUTCH_DOCK_OVERWRITE_NATIVE=1 bash "\$LIVE\/scripts\/install-dock-app\.sh"/);
  });
});

describe("the release workflow can see the native Mac sources", () => {
  /** The quoted entries of the `paths:` list under one trigger. */
  const triggerPaths = (trigger: "push" | "pull_request"): string[] => {
    const lines = WORKFLOW.split("\n");
    const start = lines.findIndex((l) => l === `  ${trigger}:`);
    expect(start, `${trigger} trigger`).toBeGreaterThan(-1);
    const out: string[] = [];
    for (const line of lines.slice(start + 1)) {
      if (/^ {2}[a-z_]+:/.test(line) || /^[a-z]/.test(line)) break;
      const m = line.match(/^ {6}- '([^']+)'$/);
      if (m) out.push(m[1]);
    }
    return out;
  };
  const pushPaths = triggerPaths("push");
  const prPaths = triggerPaths("pull_request");

  it("watches the Mac target's own inputs on both push and pull_request", () => {
    for (const paths of [pushPaths, prPaths]) {
      for (const p of [
        "ios/Mac/**",
        "ios/App/**",
        "ios/Resources/**",
        "ios/Assets.xcassets/**",
        "ios/project.yml",
        "ios/Clutch.xcodeproj/**",
        "scripts/build-mac-app.sh",
        "scripts/lib/clutch-build-lock.sh",
        "scripts/install-dock-app.sh",
        ".github/workflows/mac-app-build.yml",
      ]) {
        expect(paths).toContain(p);
      }
    }
  });

  it("compiles on the PR everything that would ship from main", () => {
    expect(pushPaths.length).toBeGreaterThan(0);
    expect([...prPaths].sort()).toEqual([...pushPaths].sort());
  });

  it("no longer gates on the retired shell directory", () => {
    for (const paths of [pushPaths, prPaths]) {
      expect(paths).not.toContain("src/web/dock-app/**");
      expect(paths).not.toContain("assets/clutch-icon-1024.png");
    }
  });

  it("builds from project.yml in both the release job and the PR compile", () => {
    // ci.yml and build-ios.sh both regenerate before building this scheme, so
    // the release path must too or it ships a stale committed pbxproj.
    for (const job of ["build", "pr-build-only"]) {
      const lines = WORKFLOW.split("\n");
      const start = lines.findIndex((l) => l === `  ${job}:`);
      expect(start, `job ${job}`).toBeGreaterThan(-1);
      const rest = lines.slice(start + 1);
      const end = rest.findIndex((l) => /^ {2}[a-z0-9-]+:$/.test(l));
      const body = rest.slice(0, end === -1 ? undefined : end).join("\n");
      expect(body, job).toContain("bash scripts/ios-install-xcodegen.sh");
      expect(body, job).toContain('CLUTCH_MAC_REGENERATE_PROJECT: "1"');
    }
  });

  it("checks the release build out with full history for the commit timestamp version", () => {
    const lines = WORKFLOW.split("\n");
    const start = lines.findIndex((l) => l === "  build:");
    const rest = lines.slice(start + 1);
    const end = rest.findIndex((l) => /^ {2}[a-z0-9-]+:$/.test(l));
    expect(rest.slice(0, end).join("\n")).toMatch(/fetch-depth: 0/);
  });

  it("still runs build-mac-app.sh for both build and PR compile jobs", () => {
    // Two invocations: the Release build and the PR ad-hoc compile smoke.  The
    // path filters mention the script too, so count the run steps specifically.
    expect(WORKFLOW.match(/run: bash scripts\/build-mac-app\.sh/g) ?? []).toHaveLength(2);
  });
});
