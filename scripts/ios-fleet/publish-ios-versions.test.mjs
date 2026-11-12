import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SCRIPT = join(ROOT, "scripts/ios-fleet/publish-ios-versions.sh");

const FLEET = {
  schemaVersion: 1,
  updatedAt: "2026-08-24T07:44:52Z",
  apps: {
    "codes.clutch.ios": {
      displayName: "Clutch",
      marketingVersion: "1.0.13",
      appleId: 6817951255,
    },
    "trade.congress.ios": {
      displayName: "Congress.Trade",
      marketingVersion: "1.0.80",
      appleId: 6798076688,
    },
    "services.jays.usage.client.monitor": {
      displayName: "Usage Client Monitor",
      marketingVersion: "1.0.11",
      appleId: 6799230435,
      build: "202608231801",
    },
    "services.jays.usage.local.monitor": {
      displayName: "Usage Local Monitor",
      marketingVersion: "1.0.9",
      appleId: 6799230729,
      build: "202608231806",
    },
    "online.dealdex": {
      displayName: "DealDex",
      marketingVersion: "1.0.1",
      appleId: 6802474288,
    },
    "codes.autorotate": {
      displayName: "Autorotate",
      marketingVersion: "1.0.4",
      build: "202608240741",
    },
    "net.dealdex": {
      marketingVersion: "1.0.2",
      build: "202608230250",
      appleId: 6802474288,
      displayName: "DealDex",
    },
  },
};

function run(args) {
  return spawnSync("bash", [SCRIPT, ...args], { encoding: "utf8" });
}

test("merge onto a multi-app remote keeps every sibling", () => {
  const dir = mkdtempSync(join(tmpdir(), "st-ios-versions-"));
  const base = join(dir, "remote.json");
  const out = join(dir, "out.json");
  writeFileSync(base, JSON.stringify(FLEET, null, 2) + "\n");
  const res = run([
    "--bundle-id",
    "codes.clutch.ios",
    "--version",
    "1.0.14",
    "--build",
    "190",
    "--apple-id",
    "6817951255",
    "--display-name",
    "Clutch",
    "--base-json",
    base,
    "--out-json",
    out,
    "--skip-push",
    "--skip-local-write",
  ]);
  assert.equal(res.status, 0, res.stderr || res.stdout);
  const merged = JSON.parse(readFileSync(out, "utf8"));
  assert.deepEqual(Object.keys(merged.apps).sort(), Object.keys(FLEET.apps).sort());
  assert.equal(merged.apps["codes.clutch.ios"].marketingVersion, "1.0.14");
  assert.equal(merged.apps["codes.clutch.ios"].build, "190");
  assert.equal(merged.apps["net.dealdex"].marketingVersion, "1.0.2");
  assert.equal(merged.apps["services.jays.usage.client.monitor"].marketingVersion, "1.0.11");
  assert.equal(merged.apps["services.jays.usage.local.monitor"].marketingVersion, "1.0.9");
  assert.equal(merged.apps["codes.autorotate"].marketingVersion, "1.0.4");
  rmSync(dir, { recursive: true, force: true });
});

test("empty base is refused so a missing local file cannot wipe the fleet", () => {
  const dir = mkdtempSync(join(tmpdir(), "st-ios-versions-empty-"));
  const base = join(dir, "empty.json");
  const out = join(dir, "out.json");
  writeFileSync(base, JSON.stringify({ schemaVersion: 1, apps: {} }, null, 2) + "\n");
  const res = run([
    "--bundle-id",
    "codes.clutch.ios",
    "--version",
    "1.0.14",
    "--base-json",
    base,
    "--out-json",
    out,
    "--skip-push",
    "--skip-local-write",
  ]);
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /no apps|refusing/i);
  rmSync(dir, { recursive: true, force: true });
});

// The 2026-08-21 vendored snapshot (before #3102 added net.dealdex).  Do not
// read the live ios-app-versions.json -- later ships refresh that file, and
// GitHub's pull_request merge commit then fails a pin on yesterday's keys.
const STALE_SNAPSHOT = {
  schemaVersion: 1,
  updatedAt: "2026-08-21T19:00:00Z",
  apps: {
    "codes.clutch.ios": {
      displayName: "Clutch",
      marketingVersion: "1.0.13",
      appleId: 6817951255,
    },
    "trade.congress.ios": {
      displayName: "Congress.Trade",
      marketingVersion: "1.0.80",
      appleId: 6798076688,
    },
    "services.jays.usage.client.monitor": {
      displayName: "Usage Client Monitor",
      marketingVersion: "1.0.8",
      appleId: 6799230435,
    },
    "services.jays.usage.local.monitor": {
      displayName: "Usage Local Monitor",
      marketingVersion: "1.0.7",
      appleId: 6799230729,
    },
    "online.dealdex": {
      displayName: "DealDex",
      marketingVersion: "1.0.1",
      appleId: 6802474288,
    },
    "codes.autorotate": {
      displayName: "Autorotate",
      marketingVersion: "1.0.1",
    },
  },
};

test("publishing from a stale snapshot omits later fleet apps", () => {
  const dir = mkdtempSync(join(tmpdir(), "st-ios-versions-stale-"));
  const base = join(dir, "stale.json");
  const out = join(dir, "out.json");
  writeFileSync(base, JSON.stringify(STALE_SNAPSHOT, null, 2) + "\n");
  const res = run([
    "--bundle-id",
    "codes.clutch.ios",
    "--version",
    "1.0.14",
    "--base-json",
    base,
    "--out-json",
    out,
    "--skip-push",
    "--skip-local-write",
  ]);
  assert.equal(res.status, 0, res.stderr || res.stdout);
  const merged = JSON.parse(readFileSync(out, "utf8"));
  assert.ok(!merged.apps["net.dealdex"], "stale base must not invent later fleet keys");
  assert.equal(merged.apps["services.jays.usage.client.monitor"].marketingVersion, "1.0.8");
  assert.equal(merged.apps["services.jays.usage.local.monitor"].marketingVersion, "1.0.7");
  assert.equal(merged.apps["codes.autorotate"].marketingVersion, "1.0.1");
  assert.equal(merged.apps["codes.clutch.ios"].marketingVersion, "1.0.14");
  rmSync(dir, { recursive: true, force: true });
});

test("publish script fetches remote and refuses an empty apps map", () => {
  const src = readFileSync(SCRIPT, "utf8");
  assert.match(src, /fetch_remote_json/);
  assert.match(src, /refusing to publish an empty apps map/);
  assert.match(src, /--skip-push/);
  assert.doesNotMatch(src, /data = \{"schemaVersion": 1, "apps": \{\}\}/);
});

test("a value option with no value is a usage error, not an unbound variable", () => {
  const r = run(["--bundle-id"]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /--bundle-id needs a value/);
  assert.doesNotMatch(r.stderr, /unbound variable/);
});

test("a push never falls back to the stale local cache", () => {
  const src = readFileSync(SCRIPT, "utf8");
  assert.match(src, /elif \[\[ "\$SKIP_PUSH" -eq 1 && -f "\$LOCAL_JSON" \]\]/);
  assert.match(src, /refusing to push from the stale local cache/);
});

test("ship-testflight never lets the publisher dirty the worktree", () => {
  const ship = readFileSync(join(ROOT, "scripts/ios-fleet/ship-testflight.sh"), "utf8");
  assert.match(ship, /--version "\$MARKETING" --skip-local-write\)/);
});
