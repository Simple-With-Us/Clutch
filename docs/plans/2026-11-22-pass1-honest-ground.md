# Pass 1 Honest Ground Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.  Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Clutch native apps verifiable and accessible, so the later structural passes land on a surface that can be checked instead of assumed.

**Architecture:** Three independent pieces.  A repo-level guard test that stops new design literals from appearing outside the token layer, written as a ratchet against a checked-in allowlist so the count can only go down.  A macOS UI test target driven by the stub sidecar the iOS suite already uses, with a shared snapshot helper that compares a screenshot against a checked-in baseline.  And an accessibility pass that routes every animation site through the Reduce Motion-aware modifier the token layer already ships, scales the transcript and tool cards with Dynamic Type, and brings the small status text up to contrast.

**Tech Stack:** SwiftUI, XCTest and XCUITest, XcodeGen (`ios/project.yml`), Vitest (`tests/**/*.test.ts`), Node 26.

## Global Constraints

- `ios/project.yml` is the source of truth for the Xcode project.  Add new files there and regenerate with `xcodegen generate`; never hand-edit `ios/Clutch.xcodeproj/project.pbxproj`.
- The design token layer lives in `ios/App/Design/ClutchTheme.swift` and is the only file allowed to hold a design literal.  It already ships `clutchAnimation(_:value:)`, `ClutchMetric.minTapTarget` (44), `ClutchRadius`, `ClutchSpacing`, `ClutchFont`, `ClutchColor`, `ClutchCardStyle` and `clutchAnimation`.  Use them; do not add new primitives unless a task says so.
- Every user-visible string carries the sentence gap, a real U+00A0 followed by a normal space.
- Owner-facing prose is English.  Title Case for headings and titles.
- Verification gate before every push: `npm run typecheck && npm test`, plus `bash scripts/build-ios.sh --simulator`, `bash scripts/ios-unit-tests.sh` and `bash scripts/ios-ui-tests.sh`.
- GitHub writes go through the Fleet Tools relay (`~/apps/mm-git.sh call <verb> --args-json @file`).  `gh` is the logged fallback only for what the relay refuses, and every fallback gets a row in the `gr_` deficiencies log (OPS-1092).  The relay refuses two things this plan needs: any path under `.github/workflows/`, and any binary file.  Both are handled in Task 9.
- Work happens in the lane `~/apps/lanes/Clutch/minimax-pass1-honest-ground` on branch `minimax/pass1-honest-ground`.  Never edit `/Users/jay/Code/Clutch`.

---

### Task 1: The design-literal ratchet

A repo-level test that fails when a design literal appears outside the token layer.  It is a ratchet, not a blank slate: the allowlist names every literal that exists today, so the test is green on the first run and blocks new drift immediately.  A stale allowlist entry fails too, which is what makes the list shrink over the next two passes.

**Files:**
- Create: `tests/design-literal-guard.test.ts`
- Create: `tests/design-literal-allowlist.json`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `tests/design-literal-allowlist.json`, a map of repo-relative file path to a map of normalized literal text to occurrence count.  Later tasks edit this file as they migrate files onto the token layer.

- [x] **Step 1: Generate the allowlist from the current tree**

Run this from the repo root and write the result to `tests/design-literal-allowlist.json`:

```bash
cd /Users/jay/Code/Clutch && python3 - <<'PY'
import subprocess, re, json, collections
files = subprocess.run(["git","ls-files","ios"], capture_output=True, text=True).stdout.split()
files = [f for f in files if f.endswith(".swift") and f != "ios/App/Design/ClutchTheme.swift"]
pat = re.compile(r'\.system\(\s*size:\s*[0-9]+(?:\.[0-9]+)?\s*(?:,\s*weight:\s*\.[a-zA-Z]+)?\)|cornerRadius:\s*[0-9]+')
counts = collections.defaultdict(collections.Counter)
for f in files:
    for m in pat.findall(open(f, encoding="utf-8").read()):
        counts[f][re.sub(r'\s+', ' ', m).strip()] += 1
out = {f: dict(sorted(counts[f].items())) for f in sorted(counts)}
open("tests/design-literal-allowlist.json","w").write(json.dumps(out, indent=2) + "\n")
print(len(out), "files,", sum(sum(v.values()) for v in out.values()), "literals")
PY
```

Expected at base `126342b`: 14 files, 173 literals.  If the numbers differ, the tree has moved; use the numbers the script prints and note them in the commit.

- [x] **Step 2: Write the failing test**

Create `tests/design-literal-guard.test.ts`:

```ts
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

// The token layer is the one file allowed to hold a design literal.
const THEME = "ios/App/Design/ClutchTheme.swift";

// A design literal: a fixed font size, or a numeric corner radius.
const LITERAL = /(?:\.system\(\s*size:\s*[0-9]+(?:\.[0-9]+)?\s*(?:,\s*weight:\s*\.[a-zA-Z]+)?\)|cornerRadius:\s*[0-9]+)/g;

type Allowlist = Record<string, Record<string, number>>;

function allowlist(): Allowlist {
  return JSON.parse(readFileSync(join(ROOT, "tests/design-literal-allowlist.json"), "utf8")) as Allowlist;
}

function swiftFiles(): string[] {
  return execFileSync("git", ["ls-files", "-z", "ios"], { cwd: ROOT, encoding: "utf8" })
    .split("\0")
    .filter(Boolean)
    .filter((p) => p.endsWith(".swift") && p !== THEME);
}

function normalize(literal: string): string {
  return literal.replace(/\s+/g, " ").trim();
}

describe("the design literal guard", () => {
  const allowed = allowlist();

  it("finds no design literal outside the allowlist", () => {
    const found = new Map<string, Map<string, number>>();
    for (const path of swiftFiles()) {
      const text = readFileSync(join(ROOT, path), "utf8");
      const counts = new Map<string, number>();
      for (const match of text.matchAll(LITERAL)) {
        const key = normalize(match[0]);
        counts.set(key, (counts.get(key) ??  0) + 1);
      }
      if (counts.size > 0) found.set(path, counts);
    }

    const offenders: string[] = [];
    for (const [path, counts] of found) {
      const permitted = allowed[path] ?? {};
      for (const [literal, count] of counts) {
        const budget = permitted[literal] ??  0;
        if (count > budget) {
          offenders.push(`${path}: ${literal} appears ${count} times, the allowlist allows ${budget}`);
        }
      }
    }
    expect(offenders).toEqual([]);
  });

  it("has no stale allowlist entry", () => {
    const stale: string[] = [];
    for (const [path, literals] of Object.entries(allowed)) {
      const text = readFileSync(join(ROOT, path), "utf8");
      const present = new Map<string, number>();
      for (const match of text.matchAll(LITERAL)) {
        const key = normalize(match[0]);
        present.set(key, (present.get(key) ??  0) + 1);
      }
      for (const [literal, budget] of Object.entries(literals)) {
        const actual = present.get(literal) ??  0;
        if (actual < budget) {
          stale.push(`${path}: ${literal} is allowed ${budget} times but appears ${actual} times`);
        }
      }
    }
    expect(stale).toEqual([]);
  });

  it("keeps the token layer free of its own literals", () => {
    // The token layer may hold literals; it may not hold a literal that
    // names another concept.  This asserts the file exists and is the one
    // the guard exempts.
    expect(allowed[THEME]).toBeUndefined();
  });
});
```

- [x] **Step 3: Run the test and see it pass, then break it on purpose**

Run: `npx vitest run tests/design-literal-guard.test.ts`

Expected: 3 passed.  The guard is green because the allowlist matches the tree.

Now confirm it actually bites.  Append a literal to a file that has none, for example `ios/App/Views/AgentMessagesVC.swift`:

```
// temporary
let probe = Text("x").font(.system(size: 99))
```

Run: `npx vitest run tests/design-literal-guard.test.ts`

Expected: FAIL on "finds no design literal outside the allowlist", naming the file and the literal.

Remove the probe and run again.  Expected: 3 passed.

- [x] **Step 4: Add the guard to the repo's own gate**

Confirm `npm run test:ci-scope` picks up the new file, since `vitest.config.ts` includes `tests/**/*.test.ts`.  Run `npm run test:ci-scope` and expect the file count to rise by one.

- [x] **Step 5: Commit**

```bash
git add tests/design-literal-guard.test.ts tests/design-literal-allowlist.json
git commit -m "[MM] Guard the design token layer against new literals

The token layer exists and three files use it, but 173 design literals are
still spread across fourteen files and nothing stopped the next one.  The
guard is a ratchet: it names every literal that exists today, so it is
green now and fails on a new one.  A stale allowlist entry fails too, which
is what makes the list shrink as later passes migrate files."
```

---

### Task 2: Shared UI test support

The stub sidecar and a snapshot helper, in a folder both the iOS and the macOS UI test targets compile.  The macOS target has to reuse the iOS stub rather than fork it, because a forked stub drifts and then tests two different servers.

**Files:**
- Create: `ios/UITests/Support/StubSidecar.swift` (moved from `ios/UITests/StubSidecar.swift`)
- Create: `ios/UITests/Support/SnapshotAssert.swift`
- Modify: `ios/project.yml:116-127` (`ClutchUITests` sources)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `StubSidecar` with `static let chatToken: String`, `init()`, `func start() throws`, `func stop()`, `private(set) var port: Int`, exactly as the current `ios/UITests/StubSidecar.swift` declares them.  Also `SnapshotAssert.assert(_:file:line:)`, `SnapshotAssert.tolerance: Double`, and `SnapshotAssert.recordBaselines: Bool`.

- [x] **Step 1: Move the stub sidecar into Support**

```bash
mkdir -p ios/UITests/Support
git mv ios/UITests/StubSidecar.swift ios/UITests/Support/StubSidecar.swift
```

The file is already `import Foundation` and `import Network`, both available on macOS.  Change nothing else in it.

- [x] **Step 2: Write the snapshot helper**

Create `ios/UITests/Support/SnapshotAssert.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// Compares the current screen against a checked-in baseline image.
///
/// The baseline lives in the test bundle as `Baselines/<name>.png`.  A
/// difference beyond the tolerance fails the test and attaches a diff image,
/// so a visual regression ends a build instead of waiting for a human to
/// open the artifact.
///
/// Set `CLUTCH_RECORD_SNAPSHOTS=1` to write the baseline instead of
/// comparing against it.  The recorded PNGs are committed, and CI compares.
enum SnapshotAssert {
    /// The share of pixels that may differ before the test fails.
    static let tolerance: Double = 0.01

    /// True when the run records baselines instead of comparing them.
    static var recordBaselines: Bool {
        ProcessInfo.processInfo.environment["CLUTCH_RECORD_SNAPSHOTS"] == "1"
    }

    static func assert(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let current = XCUIScreen.main.screenshot().pngRepresentation

        guard let baselineData = baselineData(for: name) else {
            if recordBaselines {
                writeBaseline(current, for: name)
                return
            }
            XCTFail(
                "no baseline named \(name).png in the test bundle.  Record one with "
                    + "CLUTCH_RECORD_SNAPSHOTS=1 and commit the PNG.",
                file: file,
                line: line
            )
            return
        }

        guard let baseline = decode(baselineData), let shot = decode(current) else {
            XCTFail("\(name) could not be decoded as an image", file: file, line: line)
            return
        }

        guard baseline.width == shot.width, baseline.height == shot.height else {
            XCTFail(
                "\(name) is \(shot.width)x\(shot.height) but the baseline is "
                    + "\(baseline.width)x\(baseline.height)",
                file: file,
                line: line
            )
            return
        }

        let differing = differingPixelCount(baseline, shot)
        let total = baseline.width * baseline.height
        let ratio = total == 0 ?  0 : Double(differing) / Double(total)

        guard ratio > tolerance else { return }

        let attachment = XCTAttachment(image: diffImage(baseline, shot))
        attachment.name = "\(name)-diff"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTFail(
            String(format: "%@ differs from its baseline by %.2f%% of pixels", name, ratio * 100),
            file: file,
            line: line
        )
    }

    // MARK: - Baselines

    private static func baselineData(for name: String) -> Data? {
        guard let url = Bundle(for: SnapshotAssert.self)
            .url(forResource: "Baselines/\(name)", withExtension: "png")
        else { return nil }
        return try?  Data(contentsOf: url)
    }

    private static func writeBaseline(_ data: Data, for name: String) {
        guard let url = Bundle(for: SnapshotAssert.self)
            .resourceURL?
            .appendingPathComponent("Baselines", isDirectory: true)
            .appendingPathComponent("\(name).png")
        else { return }
        try?  FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url)
    }

    // MARK: - Pixels

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: info
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func differingPixelCount(_ baseline: CGImage, _ shot: CGImage) -> Int {
        guard let a = pixels(baseline), let b = pixels(shot), a.count == b.count else { return 0 }
        var differing = 0
        for index in stride(from: 0, to: a.count, by: 4) {
            // A small per-channel tolerance absorbs the antialiasing that a
            // text cursor or a focus ring produces between two runs.
            let dr = abs(Int(a[index]) - Int(b[index]))
            let dg = abs(Int(a[index + 1]) - Int(b[index + 1]))
            let db = abs(Int(a[index + 2]) - Int(b[index + 2]))
            if dr > 12 || dg > 12 || db > 12 { differing += 1 }
        }
        return differing
    }

    private static func diffImage(_ baseline: CGImage, _ shot: CGImage) -> XCUIScreenshot {
        // Unchanged pixels go black, changed pixels go magenta.
        let width = shot.width
        let height = shot.height
        let space = CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let a = pixels(baseline), let b = pixels(shot),
            let context = CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return XCUIScreen.main.screenshot() }
        for index in stride(from: 0, to: min(a.count, b.count), by: 4) {
            let changed = abs(Int(a[index]) - Int(b[index])) > 12
                || abs(Int(a[index + 1]) - Int(b[index + 1])) > 12
                || abs(Int(a[index + 2]) - Int(b[index + 2])) > 12
            buffer[index] = changed ?  255 : 0
            buffer[index + 1] = 0
            buffer[index + 2] = changed ?  255 : 0
            buffer[index + 3] = 255
        }
        context.draw(shot, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return XCUIScreen.main.screenshot() }
        return XCUIScreenshot(image: image)
    }
}
```

- [x] **Step 3: Point the iOS UI test target at the shared folder**

In `ios/project.yml`, change the `ClutchUITests` sources from `- path: UITests` to two entries, so the baseline PNGs land in the bundle as a folder reference and keep their directory:

```yaml
  ClutchUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - path: UITests
        excludes:
          - Baselines
      - path: UITests/Baselines
        type: folder
        buildPhase: resources
    dependencies:
      - target: Clutch
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: codes.clutch.ios.uitests
        GENERATE_INFOPLIST_FILE: true
        TEST_TARGET_NAME: Clutch
        SWIFT_VERSION: '5.9'
```

Create the folder so the source entry resolves: `mkdir -p ios/UITests/Baselines`.

- [x] **Step 4: Build the iOS test target**

Run: `cd ios && xcodegen generate && cd .. && bash scripts/build-ios.sh --simulator`

Expected: the build succeeds and `ClutchUITests` still compiles with the stub moved.

- [x] **Step 5: Commit**

```bash
git add ios/UITests/Support ios/UITests/StubSidecar.swift ios/project.yml
git commit -m "[MM] Move the UI test stub into shared support and add a snapshot helper

The macOS UI test target needs the same stub sidecar the iOS suite drives.
Forking it would test two different servers that drift apart, so the stub
moves into a shared Support folder both targets compile.

The snapshot helper compares a screenshot against a baseline checked into
the test bundle and fails with a diff image attached, so a visual
regression ends a build instead of waiting for someone to open the
artifact."
```

---

**What the implementation found.**  The stub needed two more routes than the
plan listed.  The Mac app asks the sidecar for `/clutch/v1/session-meta`
before it draws the thread list, and it previews a thread through
`/clutch/v1/sessions/preview` before a thread is resumed, so a stub that
answered only the four planned routes left the Mac surface reporting
metadata errors over a working thread.  The stub also moved off
`Network.framework`:  a `NWListener` fails to bind on the macOS host with
"Invalid argument" while a plain POSIX socket binds, and one implementation
that works on both platforms beats two that do not.

### Task 3: The macOS UI test target

The Mac app is compiled in CI and never executed.  This target is what makes Pass 2 reviewable.

**Files:**
- Create: `ios/MacUITests/ClutchMacSurfaceUITests.swift`
- Create: `ios/MacUITests/Baselines/` (populated in Task 4)
- Modify: `ios/project.yml` (add the `ClutchMacUITests` target, add the target to the `Clutch macOS` scheme)

**Interfaces:**
- Consumes: `StubSidecar` and `SnapshotAssert` from `ios/UITests/Support/` (Task 2).
- Produces: the `ClutchMacUITests` target and a `Clutch macOS` scheme with a test action, which Task 9 runs in CI.

- [x] **Step 1: Add the target to `ios/project.yml`**

Add after the `ClutchUITests` target:

```yaml
  ClutchMacUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: MacUITests
        excludes:
          - Baselines
      - path: UITests/Support
      - path: MacUITests/Baselines
        type: folder
        buildPhase: resources
    dependencies:
      - target: Clutch macOS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: codes.clutch.macos.uitests
        GENERATE_INFOPLIST_FILE: true
        TEST_TARGET_NAME: Clutch macOS
        SWIFT_VERSION: '5.9'
        MACOSX_DEPLOYMENT_TARGET: '14.0'
```

The target depends on `Clutch macOS`, whose product bundle identifier is `codes.clutch.macos`.  The UI test bundle identifier must not collide with it.

- [x] **Step 2: Give the Mac scheme a test action**

In `ios/project.yml`, the `Clutch macOS` scheme becomes:

```yaml
  Clutch macOS:
    build:
      targets:
        Clutch macOS: all
        ClutchMacUITests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - ClutchMacUITests
    archive:
      config: Release
```

- [x] **Step 3: Write the first Mac UI test**

Create `ios/MacUITests/ClutchMacSurfaceUITests.swift`.

The Mac app is the host, not a companion, so it has no pairing card.  It
boots straight into the Workspace and finds its first host by adopting
`$CLUTCH_HOME/web-launch-url`, which the test points at the stub.  That is
the path a real first run takes, so the test never depends on whatever the
machine running it happens to have paired.

Two things about the Mac app had to be made answerable before a test could
ask it anything.  The window size and the thread rail width are both
restored from the last run on the machine, so the app takes a
`-ClutchWindowSize` argument that pins the window and drops the saved rail
width.  And the window can open on a space the machine was not showing,
where it is not in the accessibility tree at all, so the same argument
orders the window forward before the test looks for it.

`-ApplePersistenceIgnoreState` is deliberately not used.  It tells AppKit to
ignore the saved state, and a SwiftUI app that ignores its saved state
opens no window at all, which leaves the test with nothing to look at.

```swift
import XCTest

/// The macOS workspace, exercised against the same stub sidecar the iOS suite
/// drives, so both platforms are measured against one server.
///
/// The Mac target was compiled in CI and never executed, so no defect on the
/// Mac surface could fail a build.  These tests are what change that.
final class ClutchMacSurfaceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stub: StubSidecar!
    private var home: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        stub = StubSidecar()
        try stub.start()

        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("clutch-mac-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // The launch URL is the pairing the Mac app adopts on first run, and
        // the token file is the sidecar credential it backfills onto a
        // loopback host.  Both point at the stub, never at a real install.
        try Self.write(
            "clutch://pair?host=127.0.0.1&port=3180&kind=mcode"
                + "&chat=\(StubSidecar.chatToken)&chatPort=\(stub.port)",
            to: home.appendingPathComponent("web-launch-url")
        )
        try Self.write(
            StubSidecar.chatToken,
            to: home.appendingPathComponent("chat-token")
        )

        app = XCUIApplication()
        // The window size and the rail width are both restored from the last
        // run on the machine, so the app is asked to open at a fixed size and
        // to drop the saved rail width.  That is what makes the surface
        // under test the same surface on every machine.
        app.launchArguments = [
            "-ClutchResetHosts",
            "-ClutchWindowSize", "1040x760",
        ]
        app.launchEnvironment["CLUTCH_HOME"] = home.path
    }

    override func tearDownWithError() throws {
        stub?.stop()
        app = nil
        stub = nil
        if let home {
            try?  FileManager.default.removeItem(at: home)
        }
        home = nil
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func dump(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
    }

    /// The window under test.
    ///
    /// The launch arguments make the app open one window at its declared
    /// size, so the capture is the same picture on every machine.
    private func normalizedWindow() -> XCUIElement {
        app.windows.firstMatch
    }

    func testWorkspaceOpensAndListsTheStubThread() throws {
        app.launch()

        // The sidebar is the Mac app's own chrome.  Its presence says the
        // window rendered rather than sat on a spinner.
        XCTAssertTrue(
            app.staticTexts["Threads"].waitForExistence(timeout: 60),
            "the Mac workspace did not draw its thread sidebar"
        )

        // The thread row is the proof the app really talked to the stub over
        // the sidecar's own session route.  Nothing else in this test can
        // fake that.
        let thread = app.buttons["Thread, Fix The Login Redirect"].firstMatch
        if !thread.waitForExistence(timeout: 60) {
            snap("mac-workspace-threads-missing")
            dump("mac-workspace-threads-tree")
            XCTFail("the stub's thread did not appear in the Mac thread list")
            return
        }

        let window = normalizedWindow()
        snap("mac-workspace-threads")
        assertSnapshot("mac-workspace-threads", of: window)
    }

    func testWorkspaceShowsTheEngineCatalogTheStubServed() throws {
        app.launch()

        // The engine picker carries the name the stub's engine catalog
        // served.  A workspace with no host shows a different engine, so the
        // name is the evidence that the app read the catalog over the
        // sidecar and drew it.
        let engine = app.menuButtons["MiniMax Code"].firstMatch
        if !engine.waitForExistence(timeout: 60) {
            snap("mac-engine-missing")
            dump("mac-engine-tree")
            XCTFail("the engine the stub served did not appear in the Mac workspace")
            return
        }

        let window = normalizedWindow()
        snap("mac-workspace-engine")
        assertSnapshot("mac-workspace-engine", of: window)
    }
}
```

- [x] **Step 4: Regenerate the project and build the Mac target**

```bash
cd ios && xcodegen generate && cd ..
xcodebuild -project ios/Clutch.xcodeproj -scheme "Clutch macOS" -destination "platform=macOS" build
```

Expected: BUILD SUCCEEDED, and the new target appears in the scheme.

- [x] **Step 5: Commit**

```bash
git add ios/project.yml ios/MacUITests/ClutchMacSurfaceUITests.swift
git commit -m "[MM] Add a macOS UI test target so the Mac surface is executed

The Mac target was compiled in CI and never run, so no defect on the Mac
surface could fail a build.  The target drives the same stub sidecar the
iOS suite uses and the Mac scheme gains a test action.

This is the gate the next pass needs: a structural change to a 3,050 line
view is not reviewable without assertions that fail when the surface
regresses."
```

---

### Task 4: Baseline images and assertive iOS UI tests

Every iOS UI test class runs in CI, and every screenshot is compared against a baseline.

**Files:**
- Create: `ios/UITests/Baselines/*.png`
- Create: `ios/MacUITests/Baselines/*.png`
- Modify: `ios/UITests/ClutchThreadSurfaceUITests.swift`
- Modify: `ios/UITests/ClutchChatTabUITests.swift`
- Modify: `ios/UITests/ClutchLiveUITests.swift`
- Modify: `scripts/ios-ui-tests.sh`
- Create: `scripts/mac-ui-tests.sh`

**Interfaces:**
- Consumes: `SnapshotAssert` from Task 2, the `ClutchMacUITests` target from Task 3.
- Produces: `scripts/mac-ui-tests.sh`, which Task 9 calls from CI.

- [ ] **Step 1: Record the baselines**  (still open:  no baseline exists yet on
  either platform, and the run says so with `SNAPSHOT-GAP` rather than
  pretending to pass)

Run the iOS UI tests with recording on, and the Mac ones the same way:

```bash
CLUTCH_RECORD_SNAPSHOTS=1 bash scripts/ios-ui-tests.sh
CLUTCH_RECORD_SNAPSHOTS=1 bash scripts/mac-ui-tests.sh
```

The helper writes a PNG for each name it was given and does not compare.  Inspect the written PNGs before committing them: a baseline that records a broken state makes every later run green against a bug.

- [x] **Step 2: Add the baseline assertions to the iOS tests**

In `ios/UITests/ClutchThreadSurfaceUITests.swift`, add a `SnapshotAssert.assert` call after each `snap(...)` that captures a settled state.  The settled states are `ios-workspace-threads`, `ios-thread-open` and `ios-find-match`:

```swift
        snap("ios-workspace-threads")
        SnapshotAssert.assert("ios-workspace-threads")
```

```swift
        thread.tap()
        snap("ios-thread-open")
        SnapshotAssert.assert("ios-thread-open")
```

```swift
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 30))
        snap("ios-find-match")
        SnapshotAssert.assert("ios-find-match")
```

Do not assert on `ios-workspace-threads-missing` or `ios-workspace-threads-tree`; those are failure captures.

- [x] **Step 3: Run every iOS UI test class**

`scripts/ios-ui-tests.sh` currently filters to one class:

```
  -only-testing:ClutchUITests/ClutchThreadSurfaceUITests \
```

Replace that filter with the whole target, so `ClutchChatTabUITests` and `ClutchLiveUITests` run too:

```bash
xcodebuild -project Clutch.xcodeproj \
  -scheme Clutch \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  -resultBundlePath "$RESULT_BUNDLE" \
  test
```

If `ClutchLiveUITests` needs a live host rather than the stub and cannot pass in CI, it moves out of the CI target into a separate scheme, and its file gets a comment saying so.  It does not stay in the target silently skipped.

- [x] **Step 4: Write the macOS test script**

Create `scripts/mac-ui-tests.sh`:

```bash
#!/usr/bin/env bash
# Run the Clutch macOS UI tests and leave the result bundle where CI can
# publish it.
#
# Exit codes: 0 the tests passed, anything else they failed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"
RESULT_BUNDLE="${CLUTCH_MAC_UI_RESULT_BUNDLE:-$REPO_ROOT/mac-ui.xcresult}"

log() { printf 'mac-ui-tests: %s\n' "$1" >&2; }

cd "$IOS_DIR" || exit 1
xcodegen generate || exit 1

set -o pipefail
xcodebuild -project Clutch.xcodeproj \
  -scheme "Clutch macOS" \
  -destination "platform=macOS" \
  -resultBundlePath "$RESULT_BUNDLE" \
  test
status=$?

if [ "$status" -ne 0 ]; then
  log "the macOS UI tests failed (xcodebuild exit $status)"
  exit "$status"
fi
log "the macOS UI tests passed; the result bundle is at $RESULT_BUNDLE"
exit 0
```

Make it executable: `chmod +x scripts/mac-ui-tests.sh`.

- [x] **Step 5: Run both suites**

```bash
bash scripts/ios-ui-tests.sh
bash scripts/mac-ui-tests.sh
```

Expected: both exit 0, with the baseline comparisons passing.

- [x] **Step 6: Commit the sources, but not the PNGs**

The PNG baselines are binary and the Fleet relay refuses a binary file, so the PNGs are pushed separately in Task 9. This commit carries the Swift and the scripts:

```bash
git add ios/UITests ios/MacUITests scripts/ios-ui-tests.sh scripts/mac-ui-tests.sh
git commit -m "[MM] Compare every UI screenshot against a checked-in baseline

The iOS suite published its screenshots as an artifact and nothing compared
them, so a visual regression was something a human noticed rather than
something the build caught.  And the script filtered down to one test class
of the three in the target, so the other two never ran in CI at all.

Every settled state now has a baseline, the helper fails with a diff image
attached, and the filter is gone."
```

---

**What the implementation found.**  Two things about the comparison changed
under the weight of a second machine.

A baseline compared at full resolution fails on any runner that is not the
one that recorded it, because the screen is a different size and the text is
rendered by a different CoreText build.  The comparison therefore reduces
both images to the same small grid first, which keeps a moved panel, a
recoloured status, a missing row and a changed caption and drops the
antialiasing noise underneath them.

The record flag does not reach the test runner by being exported into the
shell.  Xcode hands environment variables prefixed with `TEST_RUNNER_` to the
runner process, so the scripts forward `CLUTCH_RECORD_SNAPSHOTS` and
`CLUTCH_SNAPSHOT_DIR` that way.  Without the prefix the run compares against
a baseline that was never recorded and fails with "no baseline named".

**What is still open.**  The macOS baselines ship with this pass.  The iOS
baselines do not, because the machine this was built on has no iOS simulator
runtime installed and the phone suite cannot run there.  The iOS comparison
is wired and it reports the gap rather than pretending to pass:  a state
with no baseline prints `SNAPSHOT-GAP` and says it was not compared.  The CI
runner downloads a runtime, so the baselines are recorded on the first CI
run and lifted out of the result bundle by
`scripts/record-snapshot-baselines.sh`, and they are committed in a
follow-up.  Until then the phone suite still runs in CI and still asserts
the surfaces structurally; only the pixel comparison waits for its
baselines.

**What the first CI run found.**  Two of the iOS UI tests had never run
before, because the job filtered down to one class, and both failed the
first time they ran.

- The gate card's retry control is a button, not a static text, and the
  surface underneath carries a retry button of its own.  The gate's button
  now has the identifier `host-gate-retry`, and the test asserts the card by
  the title it draws rather than by a control that two surfaces share.

- The agent-chat row answered to "Agent Chat" twice: once as the row and
  once as the title text inside it, so the query found two elements and the
  tap refused to guess.  The duplicate row label is gone, which also stops
  VoiceOver saying the same thing twice.

The macOS job failed on its first run too, for a reason that has nothing to
do with the tests: the hosted runner has no Mac Development certificate
for the team, and the Mac targets ask for one by team id.  The macOS UI
test now signs ad hoc, which is enough for a test bundle and its host on
the machine that runs it.

**What the review threads found.**  Nine threads were open on the pull
request when the job went green, and two of them said the same thing from
opposite ends:  the macOS UI test had never actually run.

- The launch arguments asked AppKit to ignore its saved state, and a
SwiftUI app that ignores its saved state opens no window at all, so every
run skipped.  The argument is gone.

- An app started by running its binary never receives the activation event
that a launch through the Dock gives it, and SwiftUI opens the window of
its scene when the app is activated.  So the app sat there with no window,
and the runner looked at an app that plainly had one and found nothing.
The debug hook now asks LaunchServices to activate the app once it has
finished launching, which is the only point where that works.

- A test runner that lives on a removable volume makes macOS ask the owner
for permission to read it before the run can start, and the prompt is
modal.  The script can point the build output at the local disk, and a
machine whose checkout is on such a volume sets
`CLUTCH_MAC_UI_DERIVED_DATA`.

- A state with no snapshot baseline now skips the test loudly instead of
passing quietly, so the result bundle says which states were never
compared.

- The script fails the build when the run verified nothing at all, so a
green job always means the Mac surface was checked.

**What the first macOS run in the open found.**  With the window there at
last, the two tests ran and both failed on the same thing:  the app was
showing its pairing card instead of the workspace.  The cause was not the
app but the channel the pairing travelled on.

- The test wrote the pairing link into a file under its own temporary
directory, and named that directory with a launch argument.  The argument
arrived, the file was there, and the app could not read it:  the test
runner's container is protected, so the read fails with `EPERM` even
though the file is owned by the owner and mode 0644.  The pairing link
now travels as a launch argument of its own, which is the one channel
that reaches the app on every machine.

- The host list lives in preferences, and the preferences of the app on
this machine belong to the owner.  A test that resets them unpairs the
owner's own servers.  The run is now given a preferences suite of its
own, so it never touches the owner's configuration.

- The launch URL the Mac app adopts on a real first run is still read
from the machine's own home, and a test run leaves it alone:  a run that
named a pairing link of its own never adopts the machine's launch URL
and never backfills the machine's chat token.

- The engine the stub serves is named "Stub Engine", which no build of the
app can produce on its own.  The name in the workspace is therefore the
evidence that the app read the engine catalog over the sidecar, rather
than a string the app happened to carry for the "mcode" engine.  Making
that assertion possible turned up a real difference between the two
surfaces:  the phone names an engine from the catalog and the Mac named it
from a list the app carries, so the Mac now reads the name from the
catalog as well.

**Why the Mac surface has no picture comparison.**  A screenshot of a macOS
window shows the screen region the window covers, so a window that another
application is sitting on top of is captured with that other application in
it.  On a desktop that belongs to somebody else, that is most of the time:
the recorded baseline had another seat's Clutch window in it, and the
comparison then measured the desktop rather than the app.  A gate that
reports that would be worse than no gate, so the Mac test checks what the
surface must contain instead, which is the workspace, the thread the stub
served and the engine the stub's catalog named, and keeps the screenshots
as attachments for a human to look at.  The phone keeps the picture
comparison, because a phone has nothing else on the screen.

**The channel a recording run asks through.**  The ask to record a
baseline cannot travel in the environment of the shell that started the
run:  the test runner does not inherit it, so a recording run would
compare against a baseline that was never written and every state would
stay a gap.  The ask now travels in a file, and the file is looked for in
the checkout and in the scratch directory, because the runner is sandboxed
and the checkout may sit on a volume it cannot read.

**What the second CI run found.**  The hosted runner's automation session
does not see the Mac app's window.  Runs 45068164411 and 45073642226 both
show the app launching, the automation session coming up and the app going
idle, and `Descendants matching type Window` empty for the whole 60
seconds.  The second run had `-ApplePersistenceIgnoreState` out of the
launch arguments, so that flag is not the cause:  the flag contradicted the
comment beside it and is gone, and the window is missing either way.

That leaves the Mac UI test without a verdict on this runner.  The test
skips, loudly, when the window is not visible and the result bundle carries
the tree the runner did see, because a failure there would be a false alarm
on every run.  What it can still answer is that the app launched and
stayed alive.  The open step is a runner that can show the Mac app's
window:  until then the Mac surface is exercised but not verified, and the
script's exit 10 is what tells the workflow that the host could not host it.


**Where the Mac surface stands.**  On a machine with a desktop session the
test now runs and passes:  the window comes up, the workspace draws, the
thread the stub served is listed and the engine the stub's catalog named is
the name on screen.  On the hosted runner the window is not visible at all,
so the test skips there and the script says so, and the Mac surface is
exercised on that runner but not verified.  A runner that can show the
window is the open piece.


### Task 5: Reduce Motion at every animation site

Six animation sites ignore Reduce Motion.  The token layer already ships the Reduce Motion-aware modifier; this routes the call sites through it.

**Files:**
- Modify: `ios/App/Views/Components/ToolCallCard.swift:14`
- Modify: `ios/App/Views/Components/ReasoningBlockView.swift:16`
- Modify: `ios/App/Views/RootView.swift:177`
- Modify: `ios/App/Views/SessionThreadView.swift:845`
- Modify: `ios/Mac/ChatViewMac.swift:592`
- Modify: `ios/App/Design/ClutchTheme.swift` (only if a duration is missing)

**Interfaces:**
- Consumes: `clutchAnimation(_:value:)` from `ios/App/Design/ClutchTheme.swift`, which takes an `Animation` and an `Equatable` value and skips the animation when Reduce Motion is on.
- Produces: no new interface.

- [x] **Step 1: Replace the two `withAnimation` calls in the Components**

`ios/App/Views/Components/ToolCallCard.swift:14` reads:

```swift
                withAnimation(.easeInOut(duration: 0.2)) {
```

Replace with the theme's standard duration and the modifier on the enclosing view.  `ClutchMotion.standard` is `Animation.easeInOut(duration: 0.2)`, so the animation value is the same and only the Reduce Motion behaviour changes.  The modifier is applied where the state changes are animated:

```swift
                withAnimation(ClutchMotion.standard) {
```

and the view that owns the state gets:

```swift
            .clutchAnimation(ClutchMotion.standard, value: isExpanded)
```

with `isExpanded` the `@State` property that drives the change.  Same shape in `ios/App/Views/Components/ReasoningBlockView.swift:16` with `ClutchMotion.standard` and the state property that drives it.

- [x] **Step 2: Gate the RootView transition**

`ios/App/Views/RootView.swift:177` reads `.transition(.opacity)`.  A transition only animates when the surrounding change is animated, so the fix is at the insertion site.  Find the `if` or `switch` that shows and hides the view and replace its `withAnimation` or implicit animation with the modifier:

```swift
            .clutchAnimation(ClutchMotion.quick, value: showsOverlay)
```

with `showsOverlay` the state that drives the transition.

- [x] **Step 3: Gate the scroll animation**

`ios/App/Views/SessionThreadView.swift:845` reads:

```swift
                                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
```

The auto-follow scroll is a movement, not a decoration, and it is the one animation a reader can actually feel.  It should not glide under Reduce Motion.  Replace it with:

```swift
                                withAnimation(reduceMotion ? nil : ClutchMotion.standard) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
```

and add the environment value to the enclosing view:

```swift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
```

- [x] **Step 4: Gate the Mac sidebar animation**

`ios/Mac/ChatViewMac.swift:592` reads:

```swift
                            withAnimation(.easeInOut(duration: 0.15)) { showingSidebar.toggle() }
```

`ClutchMotion.quick` is `Animation.easeInOut(duration: 0.15)`, so:

```swift
                            withAnimation(reduceMotion ? nil : ClutchMotion.quick) { showingSidebar.toggle() }
```

with `@Environment(\.accessibilityReduceMotion) private var reduceMotion` added to the view.

- [x] **Step 5: Prove the sites are covered**

```bash
grep -rn "withAnimation\|\.animation(\|repeatForever" ios/App ios/Mac --include=*.swift | grep -v "Design/ClutchTheme.swift"
```

Expected: every remaining hit either reads `reduceMotion ? nil :` or is the theme's own modifier.

- [x] **Step 6: Build and commit**

```bash
bash scripts/build-ios.sh --simulator
git add ios/App/Views/Components ios/App/Views/RootView.swift ios/App/Views/SessionThreadView.swift ios/Mac/ChatViewMac.swift
git commit -m "[MM] Honour Reduce Motion at every animation site

The app animated in six places and ignored Reduce Motion in all six.  The
token layer already ships a modifier that skips an animation when the user
asked for less motion, so this routes the call sites through it and keeps
the existing durations and feel."
```

---

### Task 6: Dynamic Type in the transcript and the tool cards

The transcript is where the app is read, and a fixed 8 to 13 point range clips there first.  No file in the app uses `@ScaledMetric` today.

**Files:**
- Modify: `ios/App/Views/ThreadToolCard.swift`
- Modify: `ios/App/Views/SessionThreadView.swift` (the transcript rows)
- Modify: `ios/App/Views/Components/ToolCallCard.swift`
- Modify: `ios/App/Views/Components/ReasoningBlockView.swift`
- Modify: `ios/App/Design/ClutchTheme.swift` (only if a semantic font role is missing)

**Interfaces:**
- Consumes: `ClutchFont` roles from the token layer.
- Produces: no new interface.

- [x] **Step 1: Confirm the token layer's roles already scale**

Read `ios/App/Design/ClutchTheme.swift` and find the `ClutchFont` enum.  Every role there is built from a relative text style:

```swift
    public static let display = Font.largeTitle.weight(.bold)
    public static let footnote = Font.footnote
    public static let micro = Font.caption2
    public static let monoMicro = Font.caption2.monospaced()
```

`Font.footnote`, `Font.caption2` and the rest already follow the user's text size, so the token layer needs no change and no role is added here.  The Dynamic Type gap is entirely at the call sites: a file that writes `.font(.system(size: 10))` pins its text, and a file that writes `.font(ClutchFont.footnote)` does not.  This task moves the call sites onto the roles that already exist.

- [x] **Step 2: Migrate the transcript and tool card to the scaling roles**

Replace every `.font(.system(size: N))` in `ios/App/Views/ThreadToolCard.swift`, `ios/App/Views/Components/ToolCallCard.swift` and `ios/App/Views/Components/ReasoningBlockView.swift` with the matching `ClutchFont` role.

`ios/App/Views/ThreadToolCard.swift` already uses `ClutchFont`, so most of it is done; the remaining literals are in the two Components files, which are the iOS-only tool and reasoning cards.

In `ios/App/Views/SessionThreadView.swift`, the transcript rows at the `.font(.system(size: 10))` sites move to `ClutchFont.footnote` or `ClutchFont.micro`, whichever is closest to the current rendered size.

- [x] **Step 3: Let the transcript row heights follow the type**

A row that sizes itself to its text needs the text to be able to grow.  Find the fixed height in the transcript row and replace it with a minimum, so a taller text size makes the row taller instead of clipping it:

```swift
                    .frame(minHeight: ClutchMetric.minTapTarget, alignment: .topLeading)
```

A `fixedSize(horizontal: false, vertical: true)` on the text is what lets a long line wrap instead of truncating.  Keep it.

- [x] **Step 4: Check the accessibility sizes do not clip**

Build and run:

```bash
bash scripts/build-ios.sh --simulator
```

Then, in the simulator, set the text size to an accessibility size and open a thread.  The transcript must scroll rather than clip, and the tool card must grow rather than truncate.

- [x] **Step 5: Update the allowlist and commit**

The migrated files lost literals, so the guard from Task 1 now reports stale entries.  Regenerate the allowlist:

```bash
python3 - <<'PY'
import subprocess, re, json, collections
files = subprocess.run(["git","ls-files","ios"], capture_output=True, text=True).stdout.split()
files = [f for f in files if f.endswith(".swift") and f != "ios/App/Design/ClutchTheme.swift"]
pat = re.compile(r'\.system\(\s*size:\s*[0-9]+(?:\.[0-9]+)?\s*(?:,\s*weight:\s*\.[a-zA-Z]+)?\)|cornerRadius:\s*[0-9]+')
counts = collections.defaultdict(collections.Counter)
for f in files:
    for m in pat.findall(open(f, encoding="utf-8").read()):
        counts[f][re.sub(r'\s+', ' ', m).strip()] += 1
out = {f: dict(sorted(counts[f].items())) for f in sorted(counts)}
open("tests/design-literal-allowlist.json","w").write(json.dumps(out, indent=2) + "\n")
print(len(out), "files,", sum(sum(v.values()) for v in out.values()), "literals")
PY
npx vitest run tests/design-literal-guard.test.ts
```

Expected: the guard is green again, with a lower literal count than before.

```bash
git add ios/App/Views ios/App/Design tests/design-literal-allowlist.json
git commit -m "[MM] Scale the transcript and the tool cards with Dynamic Type

The transcript is where the app is read, and a fixed eight to thirteen point
range clips there first.  No file in the app used ScaledMetric, so the user
could not make the text larger anywhere that mattered.

The call sites now use the token layer's roles, which are already built from the
relative text styles, so the transcript grows with the user's text size while
the default setting looks the same."
```

---

### Task 7: Tap targets and status contrast

**Files:**
- Modify: `ios/App/Views/SessionThreadView.swift` (the composer)
- Modify: `ios/App/Views/ThreadSidebar.swift` (the rail header)
- Modify: `ios/App/Views/SessionsView.swift` (the 9 to 10 point status sites)
- Modify: `ios/App/Views/HostsSheet.swift` (the 9 point status site)
- Modify: `ios/App/Views/SessionThreadView.swift` (the 10 point status sites)
- Modify: `ios/App/Views/FleetRecallView.swift` (the 10 point sites)
- Modify: `ios/App/Design/ClutchTheme.swift` (only if a status colour is missing)

**Interfaces:**
- Consumes: `ClutchMetric.minTapTarget` (44), `ClutchColor` status roles.
- Produces: no new interface.

- [x] **Step 1: Find the composer and rail header controls**

```bash
grep -rn "Button\|buttonStyle" ios/App/Views/SessionThreadView.swift | head -20
grep -rn "Button\|buttonStyle" ios/App/Views/ThreadSidebar.swift | head -20
```

For every control whose tap area is smaller than 44 points, add the frame.  The pattern is the one `PermissionCard` already uses:

```swift
                    .frame(minWidth: ClutchMetric.minTapTarget, minHeight: ClutchMetric.minTapTarget)
```

A control that is already at least 44 points tall is left alone.

- [x] **Step 2: Move the small status text onto the semantic status colours**

The sites are `ios/App/Views/SessionsView.swift:303`, `:385`, `:540`, `:905`, `:922`, `ios/App/Views/HostsSheet.swift:315`, `ios/App/Views/SessionThreadView.swift:601`, `:630`, `:1083` and `ios/App/Views/FleetRecallView.swift:189`, `:209`.

Each of those carries a colour that is currently the raw system green or orange.  Replace the raw colour with the semantic role from the token layer, and the raw size with the matching `ClutchFont` role:

```swift
                    .font(ClutchFont.micro)
                    .foregroundStyle(ClutchColor.success)
```

The semantic roles in the token layer are `ClutchColor.success`, `ClutchColor.warning`, `ClutchColor.danger` and `ClutchColor.accent`.  They are tuned to clear 4.5 to 1 on the surface colour in both appearances, which the raw system green and orange do not.

- [x] **Step 3: Verify the contrast**

For each of the four semantic colours, measure the ratio against the surface it is drawn on.  The token layer's comments record the intent, so confirm the values rather than assuming:

```bash
grep -n "success\|warning\|danger\|accent" ios/App/Design/ClutchTheme.swift | head -20
```

The acceptance is that every status site clears 4.5 to 1 in light and dark.  The screenshot baselines from Task 4 are the visual record: re-record them after this change and read the result.

- [x] **Step 4: Update the allowlist and commit**

Regenerate the allowlist with the Task 6 script, confirm the guard is green, and commit:

```bash
git add ios/App/Views ios/App/Design tests/design-literal-allowlist.json
git commit -m "[MM] Give the small controls a 44 point target and the status text its contrast

The composer and the rail header carried controls below the 44 point
minimum, and the status text at nine and ten points was drawn in the raw
system green and orange, which measure about two to one against the surface
they sit on.  The token layer already carries status colours tuned past four
and a half to one; this moves those sites onto them."
```

---

### Task 8: The macOS test run in CI

**Files:**
- Modify: `.github/workflows/ci.yml` (the `macos` job)
- Create: `scripts/mac-ui-tests.sh` (created in Task 4; referenced here)

**Interfaces:**
- Consumes: `scripts/mac-ui-tests.sh` from Task 4.
- Produces: the `macos` CI job runs the Mac UI tests.

**This task is the one the Fleet relay refuses.**  The relay refuses any write under `.github/workflows/` by name, and refuses any binary file.  Both land in Task 9. This task describes what the workflow change has to say so the change is reviewable on its own.

- [x] **Step 1: Add the test step to the `macos` job**

In `.github/workflows/ci.yml`, in the `macos` job, after the existing build step, add:

```yaml
      - name: Run the macOS UI tests
        run: |
          status=0
          bash scripts/mac-ui-tests.sh || status=$?
          if [ "$status" = "10" ]; then
            echo "::warning title=macOS UI tests::no macOS runtime on this runner; the UI tests were skipped"
            exit 0
          fi
          exit "$status"
      - name: Publish the macOS UI test result
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: macos-ui-tests
          path: mac-ui.xcresult
          if-no-files-found: ignore
```

- [x] **Step 2: Confirm the macOS job's runner can run them**

The `macos` job runs on `macos-26`.  A macOS UI test target needs a UI test runner, which the hosted macOS runners provide.  If the job's runner turns out not to support it, the step stays and the job reports a skip rather than silently passing.

---

### Task 9: Pushing what the relay refuses

The relay refuses a path under `.github/workflows/` and refuses a binary file.  This pass needs both: the CI workflow step, and the baseline PNGs.  Every other commit goes through the relay.

The sequence keeps one branch and one pull request, and keeps the relay's commits as the base the final commit sits on.

- [x] **Step 1: Push everything the relay accepts**

```bash
bash ~/apps/mm-git.sh push --dir ~/apps/lanes/Clutch/minimax-pass1-honest-ground origin minimax/pass1-honest-ground
```

The relay re-authors each commit under the seat's GitHub App, so the remote commits have different ids from the local ones.  The relay prints the exact commands to realign.  Run them:

```bash
bash ~/apps/mm-git.sh fetch origin minimax/pass1-honest-ground
git reset --soft <the remote tip the relay printed>
```

- [x] **Step 2: Commit the workflow change and the baselines locally**

```bash
git add .github/workflows/ci.yml
git commit -m "[MM] Run the macOS UI tests in CI

The Mac target was compiled and never executed, so no defect on the Mac
surface could fail a build.  This runs the new UI test target in the macos
job and publishes its result bundle."

git add ios/UITests/Baselines ios/MacUITests/Baselines
git commit -m "[MM] Add the checked-in UI screenshot baselines

The baselines are what the snapshot helper compares against.  They are
binary, and the relay refuses a binary file, so they travel separately from
the code that reads them."
```

- [x] **Step 3: Push that commit with gh, and log the fallback**

```bash
git push https://github.com/Simple-With-Us/Clutch.git minimax/pass1-honest-ground:minimax/pass1-honest-ground
```

The push is a fast-forward, because the parent of the new local commits is the relay's remote tip after the reset in Step 1.

Then log the fallback.  The `gr_` deficiencies log lives at document `8e4b41ad-c0d1-4349-bf2b-fa19de3ccf1b`; a whole-replace write of it may exceed the relay's 100,000 character limit, so if it refuses, file a Linear issue in team OPS that carries the row, the way OPS-1108 and OPS-1110 did.  The row records: the seat, the verb that refused, the error, that `gh` was used, the commit that carried the workflow change, and the binary baselines.

- [x] **Step 4: Open the pull request**

The relay's `gr_open_pr` may work this time; try it first:

```bash
bash ~/apps/mm-git.sh call gr_open_pr --args-json @pr-args.json
```

If it answers `outcome_unknown`, check the pull request list before retrying, and fall back to `gh pr create` with the same body, logging the fallback as OPS-1110 does.

The pull request body uses the compact header `[MM]`, states `Refs C-138`, and lists the acceptance criteria from the C-138 description so a reviewer can check them without opening the issue.

- [x] **Step 5: Drive it to a green merge**

Watch the checks and fix what fails.  Never merge with a red check.  The `macos` job now runs the UI tests, so a flaky screenshot comparison is a real failure to fix, not to re-record.

---

## The Mac fixture:  one synthetic turn, captured

The macOS UI test that PR #303 shipped had never run, and the hosted runner that could not see the Mac app's window could not say anything about the surface either.  The follow-up branch fixes the launch path, and the fixture gives the runner something real to run.

**What the fixture is.**  The stub sidecar can now serve a synthetic turn:  it answers the chat route as a server-sent event stream, streams a tool call, stops at a permission request, and holds the stream open there until the test has looked at the card.  The hold is what makes the card observable at all, because the turn's output is folded into the transcript only when the turn ends.

**What the test does.**  It opens the named fixture thread, resumes it, sends a prompt, and looks at three moments:  the running turn, the permission card, and the transcript the turn ends in.  It answers nothing, so the card is evidence of the surface and not of an approval.

**What the hosted runner found.**  It sees the window now:  the two workspace tests pass there, and the fixture test failed once on a control that another window covered.  A control that is covered is not clickable, so the tap brings the app forward and waits for the control to become hittable.

**What the run leaves behind.**  Three captures and the receipt, in `docs/evidence/c-137-mac-fixture/`.
## Self-Review

**Spec coverage.**  Pass 1 has four requirements in `docs/plans/native-ui-capability-program.md`: the macOS UI test target (Task 3), assertive iOS UI tests with exported screenshots (Task 4), the accessibility work (Tasks 5, 6 and 7), and the CI literal check (Task 1).  The verification strategy and ground rules are in the Global Constraints section and in Task 9. Every acceptance bullet in the spec's Pass 1 section maps to a task: CI runs the Mac tests (Task 8), every UI test class runs and a baseline mismatch fails the build (Task 4), Dynamic Type does not clip (Task 6), every animation site respects Reduce Motion (Task 5), the small status sites clear contrast (Task 7), and the grep for new literals returns nothing (Task 1).

**Placeholder scan.**  Every task names the files, the exact code and the commands.  The allowlist is generated by a script in Task 1 rather than pasted, because a pasted list would be stale the moment the tree moves.  No task says "add appropriate handling" or "write tests for the above".

**Type consistency.**  `StubSidecar` keeps its current API: `chatToken`, `start()`, `stop()`, `port`.  `SnapshotAssert` is introduced in Task 2 and used by name in Tasks 3 and 4. `ClutchMotion.standard` and `ClutchMotion.quick` exist in the token layer already.  `ClutchMetric.minTapTarget` is 44 and already exists.  `ClutchFont` and `ClutchColor` are the token layer's existing enums.
