import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const BUILD = "202611091430000";

test("ios-recheck-tf-ready does not use mapfile (macOS /bin/bash 3.2)", () => {
  const sh = readFileSync(join(ROOT, "scripts/ios-recheck-tf-ready.sh"), "utf8");
  assert.doesNotMatch(sh, /^\s*mapfile\b/m);
});

function stubFleet(dir, appsJson) {
  const fleet = join(dir, "ios-fleet");
  mkdirSync(fleet);
  writeFileSync(join(fleet, "apps.json"), JSON.stringify(appsJson));
  cpSync(join(ROOT, "scripts/ios-fleet/tf-ready-rc.sh"), join(fleet, "tf-ready-rc.sh"));
  return fleet;
}

function runRecheck(appKey, fleet) {
  return spawnSync("bash", [join(ROOT, "scripts/ios-recheck-tf-ready.sh"), appKey, BUILD], {
    cwd: ROOT,
    env: { ...process.env, IOS_RECHECK_FLEET_DIR: fleet },
    encoding: "utf8",
  });
}

test("ios-recheck-tf-ready fails fast when apps.json is missing appleId", () => {
  const dir = mkdtempSync(join(tmpdir(), "recheck-tf-"));
  const fleet = stubFleet(dir, {
    apps: {
      clutch: {
        bundleId: "codes.clutch.ios",
        fixedMarketingVersion: "0.1.0",
      },
    },
  });
  try {
    const r = runRecheck("clutch", fleet);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /::error::recheck-tf-ready:.*appleId is missing/);
    assert.doesNotMatch(r.stderr, /metadata was incomplete after validation/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("ios-recheck-tf-ready rejects whitespace-only appleId", () => {
  const dir = mkdtempSync(join(tmpdir(), "recheck-tf-"));
  const fleet = stubFleet(dir, {
    apps: {
      clutch: {
        bundleId: "codes.clutch.ios",
        appleId: "   ",
        fixedMarketingVersion: "0.1.0",
      },
    },
  });
  try {
    const r = runRecheck("clutch", fleet);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /::error::recheck-tf-ready:.*appleId is missing/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("ios-recheck-tf-ready preserves python stderr when app key is unknown", () => {
  const dir = mkdtempSync(join(tmpdir(), "recheck-tf-"));
  const fleet = stubFleet(dir, {
    apps: {
      clutch: {
        bundleId: "codes.clutch.ios",
        appleId: 6817951255,
        fixedMarketingVersion: "0.1.0",
      },
    },
  });
  try {
    const r = runRecheck("not-an-app", fleet);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /unknown app key 'not-an-app'/);
    assert.doesNotMatch(r.stderr, /metadata was incomplete after validation/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
