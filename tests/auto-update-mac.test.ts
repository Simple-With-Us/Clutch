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

function head(): string {
  return git(runtime, "rev-parse", "HEAD").trim();
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
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

describe("auto-update-mac.sh", () => {
  it("does nothing, silently, when the clone already matches origin/main", () => {
    const before = head();
    const { status } = run();
    expect(status).toBe(0);
    expect(head()).toBe(before);
    expect(logText()).toBe("");
    expect(existsSync(join(markers, "restart"))).toBe(false);
  });

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
  });

  it("advances the clone but skips the restart for a docs-only change", () => {
    const target = commit("docs/notes.md", "hello\n", "docs: notes");
    const { status } = run();
    expect(status).toBe(0);
    expect(head()).toBe(target);
    expect(logText()).toMatch(/NO-RESTART/);
    expect(existsSync(join(markers, "restart"))).toBe(false);
  });

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
  });

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
  });

  it("stays out of the way while the pause file exists", () => {
    const before = head();
    commit("src-index.ts", "export const n = 5;\n", "feat: code");
    writeFileSync(join(state, "auto-update.pause"), "");
    const { status } = run();
    expect(status).toBe(0);
    expect(head()).toBe(before);
    expect(logText()).toBe("");
    expect(existsSync(join(markers, "restart"))).toBe(false);
  });
});
