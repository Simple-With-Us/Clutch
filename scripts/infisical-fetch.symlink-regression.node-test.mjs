// The regression test for the entry-module check in scripts/infisical-fetch.mjs.
//
// The canonical test file cannot express this, because it derives the path of
// the script it spawns from its own import.meta.url, which Node has already
// realpathed.  The spawned loader therefore always sees an entry module whose
// real path matches process.argv[1], and the old text comparison still
// returns true.  This file creates the symlink at run time, before the loader
// is spawned, so a reverted entry-module check fails here instead of passing
// silently.
//
// The assertion is on the loader's observable behavior and not on its
// internals, so it survives a rewrite of the entry check:  a loader that did
// not treat the symlinked path as the entry module does nothing, prints
// nothing, and leaves the environment file alone.
//
// This file is deliberately separate from the canonical test, which is copied
// byte for byte across the fleet:  editing the canonical copy would mean
// editing it in every repository that carries it.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const ABSENT_NAME = "AFC475_SYMLINK_ABSENT";

/** A temporary directory with a symlink to the repository root inside it, and
 * a path for the environment file the loader writes. */
function symlinkedRepo() {
  const dir = mkdtempSync(join(tmpdir(), "afc475-symlink-"));
  const linkDir = join(dir, "linked");
  mkdirSync(linkDir);
  const link = join(linkDir, "repo");
  symlinkSync(ROOT, link, "dir");
  return { dir, link, path: join(dir, "github_env") };
}

test("the loader treats a symlinked path as the entry module", () => {
  const { dir, link, path } = symlinkedRepo();
  try {
    // The name is best-effort and absent, so the loader warns and exits zero.
    // With the entry-module check reverted the same spawn prints nothing at
    // all, and this assertion is what fails.
    const result = spawnSync(
      process.execPath,
      [join(link, "scripts", "infisical-fetch.mjs")],
      {
        encoding: "utf8",
        env: {
          PATH: process.env.PATH,
          INFISICAL_NAMES: ABSENT_NAME,
          GITHUB_ENV: path,
        },
      },
    );
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, new RegExp(`::warning::${ABSENT_NAME} is empty`));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
