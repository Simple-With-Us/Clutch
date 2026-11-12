import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * scripts/lib/clutch-build-lock.sh serializes builds that share one DerivedData
 * directory (build-mac-app.sh).  macOS has no flock(1), so it is a mkdir lock
 * with a pid file;  these tests run the real functions in a real bash.
 */

const LIB = join(__dirname, "..", "scripts", "lib", "clutch-build-lock.sh");

let dir: string;
let lock: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "clutch-build-lock-"));
  lock = join(dir, ".build.lock");
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function bash(script: string): { code: number; stdout: string; stderr: string } {
  try {
    const stdout = execFileSync("bash", ["-c", `. "${LIB}"\nexport CLUTCH_BUILD_LOCK_POLL_SECONDS=1\n${script}`], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { code: 0, stdout, stderr: "" };
  } catch (error) {
    const e = error as { status?: number; stdout?: string; stderr?: string };
    return { code: e.status ?? 1, stdout: e.stdout ?? "", stderr: e.stderr ?? "" };
  }
}

describe("clutch-build-lock.sh", () => {
  it("records the holder's pid and releases it", () => {
    const r = bash(`clutch_build_lock_acquire "${lock}"; cat "${lock}/pid"; clutch_build_lock_release; [ ! -e "${lock}" ] && echo released`);
    expect(r.code, r.stderr).toBe(0);
    expect(r.stdout).toMatch(/^\d+\nreleased\n$/);
  });

  it("does not release a lock another process holds", () => {
    mkdirSync(lock);
    writeFileSync(join(lock, "pid"), "1\n");
    const r = bash(`CLUTCH_BUILD_LOCK_DIR="${lock}"; clutch_build_lock_release; [ -e "${lock}" ] && echo kept`);
    expect(r.code, r.stderr).toBe(0);
    expect(r.stdout).toBe("kept\n");
  });

  it("makes a second build wait until the first releases", () => {
    const r = bash(
      [
        `( clutch_build_lock_acquire "${lock}"; sleep 3; clutch_build_lock_release ) &`,
        `until [ -e "${lock}/pid" ]; do sleep 0.1; done`,
        `start=$(date +%s)`,
        `clutch_build_lock_acquire "${lock}" 30`,
        `echo "waited=$(( $(date +%s) - start ))"`,
        `clutch_build_lock_release`,
        `wait`,
      ].join("\n"),
    );
    expect(r.code, r.stderr).toBe(0);
    const waited = Number(r.stdout.match(/waited=(\d+)/)?.[1]);
    expect(waited).toBeGreaterThanOrEqual(2);
  }, 30_000);

  it("gives up with a message when a live process keeps holding it", () => {
    const r = bash(
      [
        `sleep 30 & holder=$!`,
        `mkdir "${lock}"; echo "$holder" > "${lock}/pid"`,
        `clutch_build_lock_acquire "${lock}" 2; rc=$?`,
        `kill "$holder"`,
        `exit $rc`,
      ].join("\n"),
    );
    expect(r.code).toBe(1);
    expect(r.stderr).toMatch(/still holds/);
  }, 30_000);

  it.each(["0.5", "0", "abc", ""])(
    "still times out when the poll interval is %j (fractional, zero or not a number)",
    (poll) => {
      // A fractional value broke the elapsed-time arithmetic and 0 never advanced
      // it, so the wait loop spun forever instead of reaching its timeout.
      const r = bash(
        [
          `sleep 30 & holder=$!`,
          `mkdir "${lock}"; echo "$holder" > "${lock}/pid"`,
          `export CLUTCH_BUILD_LOCK_POLL_SECONDS="${poll}"`,
          `clutch_build_lock_acquire "${lock}" 2; rc=$?`,
          `kill "$holder"`,
          `exit $rc`,
        ].join("\n"),
      );
      expect(r.code).toBe(1);
      expect(r.stderr).toMatch(/still holds/);
      expect(r.stderr).not.toMatch(/syntax error|invalid arithmetic|value too great/);
    },
    30_000,
  );

  it("reads a leading-zero poll interval as decimal, not octal", () => {
    const r = bash(
      [
        `sleep 30 & holder=$!`,
        `mkdir "${lock}"; echo "$holder" > "${lock}/pid"`,
        `export CLUTCH_BUILD_LOCK_POLL_SECONDS=09`,
        `clutch_build_lock_acquire "${lock}" 1; rc=$?`,
        `kill "$holder"`,
        `exit $rc`,
      ].join("\n"),
    );
    expect(r.code).toBe(1);
    expect(r.stderr).toMatch(/still holds/);
    expect(r.stderr).not.toMatch(/value too great|invalid number/);
  }, 30_000);

  it("takes the lock over from a holder that died without releasing", () => {
    const dead = execFileSync("bash", ["-c", "echo $$"], { encoding: "utf8" }).trim();
    mkdirSync(lock);
    writeFileSync(join(lock, "pid"), `${dead}\n`);
    const r = bash(`clutch_build_lock_acquire "${lock}" 10; cat "${lock}/pid"; clutch_build_lock_release`);
    expect(r.code, r.stderr).toBe(0);
    expect(r.stdout.trim()).not.toBe(dead);
    expect(existsSync(lock)).toBe(false);
  });

  it("takes over a lock directory that never got a pid file", () => {
    mkdirSync(lock);
    execFileSync("touch", ["-t", "200001010000", lock]);
    const r = bash(`clutch_build_lock_acquire "${lock}" 10; [ -s "${lock}/pid" ] && echo held; clutch_build_lock_release`);
    expect(r.code, r.stderr).toBe(0);
    expect(r.stdout).toBe("held\n");
  });

  it("waits on a brand-new lock directory whose pid is not written yet", () => {
    mkdirSync(lock);
    const r = bash(`clutch_build_lock_acquire "${lock}" 2`);
    expect(r.code).toBe(1);
    expect(readFileSync(LIB, "utf8")).toContain("-mmin +2");
  }, 30_000);
});
