import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * The auto-updater is the only thing allowed to move the live checkout, so its
 * decision branches are tested against a fixture origin/clone pair rather than
 * reasoned about: no-op, fast-forward, docs-only, dirty skip, pause, and the
 * rollback that keeps a broken main from bricking the Mac.
 */

const SCRIPT = join(__dirname, "..", "scripts", "auto-update-mac.sh");
const GIT_ENV = {
  ...process.env,
  GIT_AUTHOR_NAME: "Test",
  GIT_AUTHOR_EMAIL: "test@example.invalid",
  GIT_COMMITTER_NAME: "Test",
  GIT_COMMITTER_EMAIL: "test@example.invalid",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_CONFIG_SYSTEM: "/dev/null",
};

let root: string;
let origin: string;
let runtime: string;
let state: string;
let markers: string;
let log: string;
let selfStable: string;

/**
 * The fixture builds a real origin/clone pair with a dozen git subprocesses, and
 * every branch of the script runs more of them.  Those calls are fast on an idle
 * machine and slow on a loaded one -- a Mac with its swap exhausted takes tens
 * of seconds for a `git init` and a push -- so the default 5s test and 10s hook
 * timeouts fail the suite for reasons that have nothing to do with the script.
 * The script's own per-call cap is 60s (GIT_TIMEOUT), so the budget here is set
 * above that: a timeout should mean "the script hung", never "the Mac was busy".
 */
const FIXTURE_TIMEOUT_MS = 180_000;

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { env: GIT_ENV, encoding: "utf8" });
}

function commit(file: string, body: string, message: string): string {
  const target = join(runtime, file);
  mkdirSync(join(target, ".."), { recursive: true });
  writeFileSync(target, body);
  git(runtime, "add", "-A");
  git(runtime, "commit", "-q", "-m", message);
  git(runtime, "push", "-q", "origin", "main");
  // Leave the clone one commit behind, the state a real update starts from.
  git(runtime, "reset", "-q", "--hard", "HEAD~1");
  return git(runtime, "rev-parse", "origin/main").trim();
}

function run(overrides: Record<string, string> = {}): { status: number } {
  const env = {
    ...process.env,
    CLUTCH_RUNTIME_ROOT: runtime,
    CLUTCH_HOME: state,
    CLUTCH_AUTO_UPDATE_LOG: log,
    CLUTCH_AUTO_UPDATE_SELF: selfStable,
    // Point the installed-app guard at a fixture path: on the Mac the real
    // ~/Applications/Clutch.app exists and would otherwise leak into the suite.
    CLUTCH_MAC_APP: join(root, "Applications", "Clutch.app"),
    CLUTCH_AUTO_UPDATE_HEALTH: "0",
    CLUTCH_AUTO_UPDATE_INSTALL_CMD: `touch ${markers}/install`,
    CLUTCH_AUTO_UPDATE_SYNC_CMD: `touch ${markers}/sync`,
    CLUTCH_AUTO_UPDATE_SMOKE_CMD: `touch ${markers}/smoke`,
    CLUTCH_AUTO_UPDATE_DOCK_CMD: `touch ${markers}/dock`,
    CLUTCH_AUTO_UPDATE_RESTART_CMD: `touch ${markers}/restart`,
    ...overrides,
  };
  try {
    execFileSync("bash", [SCRIPT], { env, encoding: "utf8", stdio: "pipe" });
    return { status: 0 };
  } catch (error) {
    return { status: (error as { status?: number }).status ?? 1 };
  }
}

function logText(): string {
  return existsSync(log) ? readFileSync(log, "utf8") : "";
}

/**
 * A curl stand-in for the health probe.  The real engine answers 401 once it
 * is up; this one refuses the first `failures` calls and answers 401 after
 * that, which is what a slow cold boot looks like from the updater's side.
 */
function fakeCurl(failures: number): string {
  const path = join(markers, "fake-curl");
  const count = join(markers, "fake-curl-count");
  writeFileSync(
    path,
    [
      "#!/usr/bin/env bash",
      `count="${count}"`,
      "n=0",
      '[ -f "$count" ] && n="$(cat "$count")"',
      'n=$((n + 1))',
      'echo "$n" > "$count"',
      `if [ "$n" -le ${failures} ]; then exit 7; fi`,
      "printf 401",
      "",
    ].join("\n"),
  );
  chmodSync(path, 0o755);
  return path;
}

function head(): string {
  return git(runtime, "rev-parse", "HEAD").trim();
}

/**
 * C-78: plant a fake installed app for the native-vs-shell guard.  `xcode`
 * marks an Xcode-built bundle (DT* build keys in the plist); the hand-rolled
 * shell plist never has them, and both binaries link WebKit, so the DT keys
 * are the whole of the test.
 */
function installApp(bundleId: string, xcode: boolean): string {
  const app = join(root, "Applications", "Clutch.app");
  mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
  writeFileSync(
    join(app, "Contents", "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>` +
      `<key>CFBundleIdentifier</key><string>${bundleId}</string>` +
      (xcode
        ? `<key>DTXcodeBuild</key><string>27A9275</string>` +
          `<key>DTSDKName</key><string>macosx27.0</string>`
        : ``) +
      `</dict></plist>\n`,
  );
  writeFileSync(join(app, "Contents", "MacOS", "Clutch"), "fake-macho-binary\n");
  return app;
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "clutch-autoupdate-"));
  origin = join(root, "origin.git");
  runtime = join(root, "runtime");
  state = join(root, "state");
  markers = join(root, "markers");
  log = join(root, "auto-update.log");
  selfStable = join(root, "clutch-auto-update.sh");
  mkdirSync(markers, { recursive: true });
  mkdirSync(state, { recursive: true });

  execFileSync("git", ["init", "-q", "--bare", "--initial-branch=main", origin], { env: GIT_ENV });
  mkdirSync(runtime, { recursive: true });
  execFileSync("git", ["init", "-q", "--initial-branch=main", runtime], { env: GIT_ENV });
  writeFileSync(join(runtime, "package.json"), '{"name":"fixture"}\n');
  writeFileSync(join(runtime, "src-index.ts"), "export const n = 1;\n");
  mkdirSync(join(runtime, "scripts"), { recursive: true });
  writeFileSync(join(runtime, "scripts", "auto-update-mac.sh"), readFileSync(SCRIPT, "utf8"));
  mkdirSync(join(runtime, "node_modules", ".bin"), { recursive: true });
  for (const bin of ["tsx", "dsh"]) {
    const p = join(runtime, "node_modules", ".bin", bin);
    writeFileSync(p, "#!/bin/sh\nexit 0\n");
    chmodSync(p, 0o755);
  }
  git(runtime, "add", "-A");
  git(runtime, "commit", "-q", "-m", "initial");
  git(runtime, "remote", "add", "origin", origin);
  git(runtime, "push", "-q", "-u", "origin", "main");
  // The stable live copy is where refresh_self writes; keep it inside the fixture.
  writeFileSync(selfStable, "#!/usr/bin/env bash\nexit 0\n");
}, FIXTURE_TIMEOUT_MS);

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
}, FIXTURE_TIMEOUT_MS);

describe("auto-update-mac.sh", () => {
  it("does nothing, silently, when the clone already matches origin/main", () => {
    const before = head();
    const { status } = run();
    expect(status).toBe(0);
    expect(head()).toBe(before);
    expect(logText()).toBe("");
    expect(existsSync(join(markers, "restart"))).toBe(false);
  }, FIXTURE_TIMEOUT_MS);

  it("fast-forwards code changes, syncs, smoke-tests and restarts the web", () => {
    const target = commit("src-index.ts", "export const n = 2;\n", "feat: real code");
    const { status } = run();
    expect(status).toBe(0);
    expect(head()).toBe(target);
    const text = logText();
    expect(text).toMatch(/UPDATED/);
    expect(text).toMatch(/RESTARTED {2}clutch-web/);
    expect(existsSync(join(markers, "sync"))).toBe(true);
    expect(existsSync(join(markers, "smoke"))).toBe(true);
    expect(existsSync(join(markers, "restart"))).toBe(true);
    // The stable live copy is refreshed from the tracked one.
    expect(readFileSync(selfStable, "utf8")).toBe(readFileSync(SCRIPT, "utf8"));
  }, FIXTURE_TIMEOUT_MS);

  it("advances the clone but skips the restart for a docs-only change", () => {
    const target = commit("docs/notes.md", "hello\n", "docs: notes");
    const { status } = run();
    expect(status).toBe(0);
    expect(head()).toBe(target);
    expect(logText()).toMatch(/NO-RESTART/);
    expect(existsSync(join(markers, "restart"))).toBe(false);
  }, FIXTURE_TIMEOUT_MS);

  it("skips a checkout with tracked changes instead of resetting it", () => {
    const before = head();
    commit("src-index.ts", "export const n = 3;\n", "feat: code");
    writeFileSync(join(runtime, "src-index.ts"), "// a human was here\n");
    const { status } = run();
    expect(status).toBe(0);
    expect(head()).toBe(before);
    expect(logText()).toMatch(/SKIP-DIRTY/);
    expect(existsSync(join(markers, "restart"))).toBe(false);
    expect(readFileSync(join(runtime, "src-index.ts"), "utf8")).toBe("// a human was here\n");
  }, FIXTURE_TIMEOUT_MS);

  it("rolls back and remembers a bad commit when the engine smoke test fails", () => {
    const before = head();
    const bad = commit("src-index.ts", "export const n = 4;\n", "feat: broken");
    const { status } = run({ CLUTCH_AUTO_UPDATE_SMOKE_CMD: "exit 1" });
    expect(status).toBe(1);
    expect(head()).toBe(before);
    expect(logText()).toMatch(/ROLLBACK/);
    expect(readFileSync(join(state, "auto-update.bad-sha"), "utf8").trim()).toBe(bad);
    expect(existsSync(join(markers, "restart"))).toBe(false);

    // The next run must not retry the commit it already rolled back.
    const again = run({ CLUTCH_AUTO_UPDATE_SMOKE_CMD: "exit 1" });
    expect(again.status).toBe(0);
    expect(head()).toBe(before);
    expect(logText().match(/UPDATED/g)?.length ?? 0).toBe(0);
  }, FIXTURE_TIMEOUT_MS);

  it("keeps waiting for an engine that is still booting instead of rolling back", () => {
    const target = commit("src-index.ts", "export const n = 7;\n", "feat: code");
    const { status } = run({
      CLUTCH_AUTO_UPDATE_HEALTH: "1",
      CLUTCH_AUTO_UPDATE_CURL: fakeCurl(2),
      CLUTCH_AUTO_UPDATE_HEALTH_WAIT_SECONDS: "30",
      CLUTCH_AUTO_UPDATE_HEALTH_POLL_SECONDS: "0",
    });
    expect(status).toBe(0);
    expect(head()).toBe(target);
    expect(logText()).toMatch(/RESTARTED {2}clutch-web/);
    // The engine answered on the third probe, so the update stands.  A short
    // window used to roll this back and freeze the checkout for hours.
    expect(logText()).not.toMatch(/ROLLBACK/);
  }, FIXTURE_TIMEOUT_MS);

  it("rolls back when the engine never answers inside the wait window", () => {
    const before = head();
    commit("src-index.ts", "export const n = 8;\n", "feat: code");
    const { status } = run({
      CLUTCH_AUTO_UPDATE_HEALTH: "1",
      CLUTCH_AUTO_UPDATE_CURL: fakeCurl(9999),
      CLUTCH_AUTO_UPDATE_HEALTH_WAIT_SECONDS: "1",
      CLUTCH_AUTO_UPDATE_HEALTH_POLL_SECONDS: "0",
    });
    expect(status).toBe(1);
    expect(head()).toBe(before);
    expect(logText()).toMatch(/ROLLBACK/);
  }, FIXTURE_TIMEOUT_MS);

  it("normalizes file-mode-only drift instead of skipping the update", () => {
    const target = commit("src-index.ts", "export const n = 6;\n", "feat: code");
    execFileSync("chmod", ["+x", join(runtime, "scripts", "auto-update-mac.sh")]);
    const { status } = run();
    expect(status).toBe(0);
    expect(head()).toBe(target);
    expect(logText()).toMatch(/MODE-NORMALIZE|UPDATED/);
    expect(existsSync(join(markers, "restart"))).toBe(true);
  }, FIXTURE_TIMEOUT_MS);

  it("prefers a CI Mac fetch when the fetch command succeeds", () => {
    const target = commit("ios/Mac/WebViewMac.swift", "// dock\n", "feat: dock");
    const { status } = run({
      CLUTCH_AUTO_UPDATE_FETCH_MAC_CMD: `touch ${markers}/fetch`,
      CLUTCH_AUTO_UPDATE_DOCK_CMD: `touch ${markers}/dock`,
    });
    expect(status).toBe(0);
    expect(head()).toBe(target);
    expect(existsSync(join(markers, "fetch"))).toBe(true);
    expect(existsSync(join(markers, "dock"))).toBe(false);
  }, FIXTURE_TIMEOUT_MS);

  it("C-86: refreshes an installed native app instead of skipping it", () => {
    // C-78 logged DOCK-SKIPPED here, because this path could only build the
    // deprecated shell and refreshing would have paved the native app with it.
    // C-86 makes this path build the native `Clutch macOS` target, so a native
    // install is now exactly what should be refreshed.  PR #180 replaced the
    // WebKit-content discriminator with an Xcode DT* build key check because
    // the native target itself compiles Mac/WebViewMac.swift; the fixture
    // installs a real DT-keyed native bundle, and we deliberately do NOT
    // overwrite the binary with WebKit content here, since the old guard
    // would have misread it as a shell.
    const app = installApp("codes.clutch.macos", true);
    writeFileSync(join(app, "Contents", "MacOS", "Clutch"), "fake-macho-binary WKWebView linked\n");
    const target = commit("ios/Mac/WebViewMac.swift", "// dock\n", "feat: dock");
    const { status } = run({
      CLUTCH_AUTO_UPDATE_FETCH_MAC_CMD: `touch ${markers}/fetch`,
      CLUTCH_AUTO_UPDATE_DOCK_CMD: `touch ${markers}/dock`,
    });
    expect(status).toBe(0);
    expect(head()).toBe(target);
    expect(logText()).toMatch(/DOCK-REBUILT/);
    expect(logText()).toMatch(/native Clutch\.app refreshed/);
    expect(logText()).not.toMatch(/DOCK-SKIPPED/);
    // try_fetch_mac_app runs the fetch seam first and returns its status, so a
    // successful fetch is what proves the native app was replaced.
    expect(existsSync(join(markers, "fetch"))).toBe(true);
    expect(existsSync(join(markers, "dock"))).toBe(false);
  }, FIXTURE_TIMEOUT_MS);

  it("C-86: the local rebuild fallback may replace an installed native app", () => {
    // The updater usually runs minutes after a merge, before CI has published
    // the release, so the CI fetch fails and the local rebuild is what runs.
    // install-dock-app.sh refuses to pave a native install unless told to, so
    // the fallback has to say so or it refuses the app it exists to refresh and
    // the commit is never retried.
    installApp("codes.clutch.macos", true);
    const target = commit("ios/Mac/WebViewMac.swift", "// dock\n", "feat: dock");
    const { status } = run({
      CLUTCH_AUTO_UPDATE_FETCH_MAC_CMD: "exit 1",
      CLUTCH_AUTO_UPDATE_DOCK_CMD: `printf %s "$CLUTCH_DOCK_OVERWRITE_NATIVE" > ${markers}/dock-override`,
    });
    expect(status).toBe(0);
    expect(head()).toBe(target);
    expect(readFileSync(join(markers, "dock-override"), "utf8")).toBe("1");
    expect(logText()).toMatch(/DOCK-REBUILT {2}native Clutch\.app refreshed/);
    expect(logText()).not.toMatch(/DOCK-FAILED/);
  }, FIXTURE_TIMEOUT_MS);

  it("C-86: keeps the run lock fresh while the local rebuild runs", () => {
    // The local rebuild is a full xcodebuild, and a lock older than 30 minutes is
    // taken for a dead run.  Backdate the lock from inside the rebuild and see
    // whether the heartbeat has refreshed it by the time the rebuild ends.
    const lock = join(state, "auto-update.lock");
    const target = commit("ios/Mac/WebViewMac.swift", "// dock\n", "feat: dock");
    const { status } = run({
      CLUTCH_AUTO_UPDATE_FETCH_MAC_CMD: "exit 1",
      CLUTCH_AUTO_UPDATE_LOCK_BEAT_SECONDS: "1",
      CLUTCH_AUTO_UPDATE_DOCK_CMD:
        `touch -t 200001010000 "${lock}"; sleep 3; ` +
        `if [ -n "$(find "${lock}" -maxdepth 0 -mmin -1)" ]; then touch ${markers}/lock-fresh; fi`,
    });
    expect(status).toBe(0);
    expect(head()).toBe(target);
    expect(existsSync(join(markers, "lock-fresh"))).toBe(true);
    // The heartbeat must not leave a plain file or a stray lock behind.
    expect(existsSync(lock)).toBe(false);
  }, FIXTURE_TIMEOUT_MS);

  it("C-78: still serves a pre-fix shell that reports the native id", () => {
    // A shell built before the .dock rename claims codes.clutch.macos but its
    // hand-rolled plist has no Xcode DT keys, so the guard must not mistake
    // it for the native app.
    installApp("codes.clutch.macos", false);
    const target = commit("ios/Mac/WebViewMac.swift", "// dock\n", "feat: dock");
    const { status } = run({
      CLUTCH_AUTO_UPDATE_FETCH_MAC_CMD: `touch ${markers}/fetch`,
      CLUTCH_AUTO_UPDATE_DOCK_CMD: `touch ${markers}/dock`,
    });
    expect(status).toBe(0);
    expect(head()).toBe(target);
    expect(logText()).not.toMatch(/DOCK-SKIPPED/);
    expect(existsSync(join(markers, "fetch"))).toBe(true);
  }, FIXTURE_TIMEOUT_MS);

  it("C-78: still serves a renamed .dock shell install", () => {
    installApp("codes.clutch.macos.dock", false);
    const target = commit("ios/Mac/WebViewMac.swift", "// dock\n", "feat: dock");
    const { status } = run({
      CLUTCH_AUTO_UPDATE_FETCH_MAC_CMD: `touch ${markers}/fetch`,
      CLUTCH_AUTO_UPDATE_DOCK_CMD: `touch ${markers}/dock`,
    });
    expect(status).toBe(0);
    expect(head()).toBe(target);
    expect(logText()).not.toMatch(/DOCK-SKIPPED/);
    expect(existsSync(join(markers, "fetch"))).toBe(true);
  }, FIXTURE_TIMEOUT_MS);

  it("stays out of the way while the pause file exists", () => {
    const before = head();
    commit("src-index.ts", "export const n = 5;\n", "feat: code");
    writeFileSync(join(state, "auto-update.pause"), "");
    const { status } = run();
    expect(status).toBe(0);
    expect(head()).toBe(before);
    expect(logText()).toBe("");
    expect(existsSync(join(markers, "restart"))).toBe(false);
  }, FIXTURE_TIMEOUT_MS);
});
