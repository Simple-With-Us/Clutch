import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { afterEach, describe, expect, it } from "vitest";

/**
 * The launchers and the interpreter they pick.
 *
 * The catalog's availability check and the launcher have to choose the same
 * interpreter: a host that reports an engine as runnable while the launcher
 * execs a stale path answers every turn with "bridge exited", which is the
 * lie this check exists to stop.
 *
 * The test runs the shipped launchers for real.  A stub python3 stands in
 * for the interpreter and records how it was called, so the assertion is
 * about what the launcher execed and not about what the script contains.
 */

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Every launcher that resolves a python3 to run a bridge. */
const LAUNCHERS: ReadonlyArray<{ script: string; bridge: string }> = [
  { script: "scripts/dsh-acp.sh", bridge: "bridges/dsh/dsh-acp.py" },
  { script: "scripts/minimax-acp.sh", bridge: "bridges/minimax/minimax-acp.py" },
  { script: "scripts/deepseek-acp.sh", bridge: "bridges/deepseek/deepseek-acp.py" },
];

const temps: string[] = [];

afterEach(() => {
  while (temps.length > 0) rmSync(temps.pop()!, { recursive: true, force: true });
});

interface Fixture {
  /** The directory the launcher runs with as PATH. */
  bin: string;
  /** The file the stub interpreter records its arguments in. */
  log: string;
  /** A python3 on PATH that records how it was called. */
  python3: string;
  /** A named interpreter that is not on PATH. */
  named: string;
  home: string;
}

function fixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), "clutch-launcher-"));
  temps.push(root);
  const bin = join(root, "bin");
  const log = join(root, "python3.log");
  const home = join(root, "home");
  mkdirSync(bin, { recursive: true });
  mkdirSync(home, { recursive: true });
  const stub = (label: string): string => {
    const path = join(bin, label);
    writeFileSync(path, `#!/bin/sh\nprintf '%s\\n' "$*" >> ${JSON.stringify(log)}\nexit 0\n`);
    chmodSync(path, 0o755);
    return path;
  };
  const python3 = stub("python3");
  const named = stub("named-python");
  return { bin, log, python3, named, home };
}

/** Run a launcher with the fixture's environment. */
function run(script: string, fx: Fixture, env: Record<string, string>): { status: number | null } {
  // The stub interpreter comes first on PATH, and the rest of the system
  // PATH stays so the launcher can still find the ordinary tools it uses.
  const path = `${fx.bin}:${process.env.PATH ?? ""}`;
  const result = spawnSync("/bin/bash", [join(ROOT, script)], {
    env: {
      PATH: path,
      HOME: fx.home,
      CLUTCH_HOME: join(fx.home, ".clutch"),
      ...env,
    },
    encoding: "utf8",
    timeout: 30_000,
  });
  return { status: result.status };
}

/** The arguments the stub interpreter was last called with. */
function calls(fx: Fixture): string {
  return existsSync(fx.log) ? readFileSync(fx.log, "utf8") : "";
}

describe("the launchers pick their interpreter", () => {
  for (const { script, bridge } of LAUNCHERS) {
    it(`${script} falls back to the interpreter on PATH when PYTHON points at a stale path`, () => {
      const fx = fixture();

      const { status } = run(script, fx, { PYTHON: join(fx.bin, "python3-that-is-not-there") });

      expect(status).toBe(0);
      // The launcher execed the interpreter on PATH, and it ran the bridge.
      expect(calls(fx)).toContain(bridge);
    });

    it(`${script} uses PYTHON when it really is an executable`, () => {
      const fx = fixture();

      const { status } = run(script, fx, { PYTHON: fx.named });

      expect(status).toBe(0);
      // The named interpreter ran the bridge, not the one on PATH.
      expect(calls(fx)).toContain(bridge);
      expect(calls(fx).split("\n").filter(Boolean)).toHaveLength(1);
    });
  }
});
