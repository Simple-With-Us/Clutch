import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { fileURLToPath } from "node:url";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");

test("ios-observe-ship marks skip lines as not uploaded", () => {
  const dir = mkdtempSync(join(tmpdir(), "observe-ship-"));
  const fakeShip = join(dir, "fake-ship.sh");
  const outFile = join(dir, "github-output.txt");
  writeFileSync(
    fakeShip,
    '#!/bin/sh\necho "ship-gate: exiting 0 before any version is resolved (nothing consumed)"\nexit 0\n',
    { mode: 0o755 },
  );
  try {
    const r = spawnSync(
      "node",
      ["scripts/ios-observe-ship.mjs", "sh", fakeShip],
      {
        cwd: ROOT,
        env: { ...process.env, GITHUB_OUTPUT: outFile },
      },
    );
    assert.equal(r.status, 0);
    const out = readFileSync(outFile, "utf8");
    assert.match(out, /uploaded=false/);
    assert.match(out, /ship_observed=skipped/);
  } finally {
    unlinkSync(fakeShip);
    unlinkSync(outFile);
  }
});

test("ios-observe-ship marks upload log lines as uploaded", () => {
  const dir = mkdtempSync(join(tmpdir(), "observe-ship-"));
  const fakeShip = join(dir, "fake-ship.sh");
  const outFile = join(dir, "github-output.txt");
  writeFileSync(
    fakeShip,
    '#!/bin/sh\necho "upload submitted; watch TestFlight processing for codes.clutch.ios build 202611091430"\nexit 0\n',
    { mode: 0o755 },
  );
  try {
    const r = spawnSync(
      "node",
      ["scripts/ios-observe-ship.mjs", "sh", fakeShip],
      {
        cwd: ROOT,
        env: { ...process.env, GITHUB_OUTPUT: outFile },
      },
    );
    assert.equal(r.status, 0);
    const out = readFileSync(outFile, "utf8");
    assert.match(out, /uploaded=true/);
    assert.match(out, /ship_observed=uploaded/);
  } finally {
    unlinkSync(fakeShip);
    unlinkSync(outFile);
  }
});
