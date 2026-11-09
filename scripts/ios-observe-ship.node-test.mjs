import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");

function runObserve(args, env = {}, opts = {}) {
  const outFile = env.GITHUB_OUTPUT;
  const r = spawnSync("node", ["scripts/ios-observe-ship.mjs", ...args], {
    cwd: ROOT,
    env: { ...process.env, ...env, GITHUB_OUTPUT: outFile },
    encoding: "utf8",
    maxBuffer: opts.maxBuffer ?? 64 * 1024 * 1024,
  });
  const ghOut = outFile ? readFileSync(outFile, "utf8") : "";
  return { ...r, ghOut };
}

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
    const r = runObserve(["sh", fakeShip], { GITHUB_OUTPUT: outFile });
    assert.equal(r.status, 0);
    assert.match(r.ghOut, /uploaded=false/);
    assert.match(r.ghOut, /ship_observed=skipped/);
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
    const r = runObserve(["sh", fakeShip], { GITHUB_OUTPUT: outFile });
    assert.equal(r.status, 0);
    assert.match(r.ghOut, /uploaded=true/);
    assert.match(r.ghOut, /ship_observed=uploaded/);
  } finally {
    unlinkSync(fakeShip);
    unlinkSync(outFile);
  }
});

test("ios-observe-ship reports unknown when exit 0 has no upload markers", () => {
  const dir = mkdtempSync(join(tmpdir(), "observe-ship-"));
  const fakeShip = join(dir, "fake-ship.sh");
  const outFile = join(dir, "github-output.txt");
  writeFileSync(fakeShip, '#!/bin/sh\necho "noop"\nexit 0\n', { mode: 0o755 });
  try {
    const r = runObserve(["sh", fakeShip], { GITHUB_OUTPUT: outFile });
    assert.equal(r.status, 0);
    assert.match(r.ghOut, /uploaded=unknown/);
    assert.match(r.ghOut, /ship_observed=unknown_success/);
  } finally {
    unlinkSync(fakeShip);
    unlinkSync(outFile);
  }
});

test("ios-observe-ship settles once on spawn error", () => {
  const dir = mkdtempSync(join(tmpdir(), "observe-ship-"));
  const outFile = join(dir, "github-output.txt");
  writeFileSync(outFile, "");
  try {
    const r = runObserve(["/no/such/binary-observe-ship-wrap"], { GITHUB_OUTPUT: outFile });
    assert.notEqual(r.status, 0);
    assert.match(r.ghOut, /^uploaded=false\n/m);
    assert.match(r.ghOut, /ship_observed=spawn_error/);
    assert.equal((r.ghOut.match(/uploaded=/g) ?? []).length, 1);
  } finally {
    unlinkSync(outFile);
  }
});

test("ios-observe-ship finds upload after a large stream without buffering the whole log", () => {
  const dir = mkdtempSync(join(tmpdir(), "observe-ship-"));
  const fakeShip = join(dir, "fake-ship.sh");
  const outFile = join(dir, "github-output.txt");
  writeFileSync(
    fakeShip,
    `#!/bin/sh
i=0
while [ "$i" -lt 8000 ]; do
  echo "${"x".repeat(200)}"
  i=$((i + 1))
done
echo "upload submitted; watch TestFlight processing for codes.clutch.ios build 202611091430"
exit 0
`,
    { mode: 0o755 },
  );
  try {
    const r = runObserve(["sh", fakeShip], { GITHUB_OUTPUT: outFile });
    assert.equal(r.status, 0);
    assert.match(r.ghOut, /uploaded=true/);
    assert.match(r.ghOut, /ship_observed=uploaded/);
  } finally {
    if (existsSync(fakeShip)) unlinkSync(fakeShip);
    if (existsSync(outFile)) unlinkSync(outFile);
  }
});

test("ios-observe-ship does not match upload markers split across stdout and stderr", () => {
  const dir = mkdtempSync(join(tmpdir(), "observe-ship-"));
  const fakeShip = join(dir, "fake-ship.sh");
  const outFile = join(dir, "github-output.txt");
  writeFileSync(
    fakeShip,
    '#!/bin/sh\necho -n "build 202611091430" 1>&2\necho " submitted for codes.clutch.ios"\nexit 0\n',
    { mode: 0o755 },
  );
  try {
    const r = runObserve(["sh", fakeShip], { GITHUB_OUTPUT: outFile });
    assert.equal(r.status, 0);
    assert.match(r.ghOut, /uploaded=unknown/);
  } finally {
    if (existsSync(fakeShip)) unlinkSync(fakeShip);
    if (existsSync(outFile)) unlinkSync(outFile);
  }
});
