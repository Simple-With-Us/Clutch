import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const rcSh = readFileSync(join(ROOT, "scripts/ios-fleet/tf-ready-rc.sh"), "utf8");
const shipSh = readFileSync(join(ROOT, "scripts/ios-fleet/ship-testflight.sh"), "utf8");

function branchAfter(rc) {
  const body = rcSh.slice(rcSh.indexOf("handle_ensure_tf_ready_rc"));
  const re = new RegExp(String.raw`\n    ${rc}\)[\s\S]*?(?=\n    (?:\d+|\*)\)|\nesac)`);
  const m = body.match(re);
  assert.ok(m, `missing case for rc=${rc} in handle_ensure_tf_ready_rc`);
  return m[0];
}

test("ensure-tf-ready rc codes map to distinct handler branches", () => {
  for (const rc of [0, 2, 3, 4, 5, 6]) {
    assert.ok(branchAfter(rc).length > 10, `rc=${rc} branch is empty`);
  }
  const bodies = [0, 2, 3, 4, 5, 6].map((rc) => branchAfter(rc));
  const uniq = new Set(bodies);
  assert.equal(uniq.size, bodies.length, "each rc branch must be distinct");
});

test("rc=5 and rc=6 use external installability wording", () => {
  const rc5 = branchAfter(5);
  const rc6 = branchAfter(6);
  assert.doesNotMatch(rc5, /export compliance/);
  assert.doesNotMatch(rc6, /export compliance/);
  assert.match(rc5, /no external TestFlight group with testers or a public link/);
  assert.match(rc5, /::warning title=TestFlight has no reachable external tester::/);
  assert.match(rc6, /external TestFlight installability could not be read/);
  assert.match(rc6, /::warning title=TestFlight installability unverified::/);
});

test("ship-testflight ensure_tf_ready delegates to handle_ensure_tf_ready_rc", () => {
  assert.match(shipSh, /source "\$\{FLEET_DIR\}\/tf-ready-rc\.sh"/);
  const fnStart = shipSh.indexOf("ensure_tf_ready()");
  const fnEnd = shipSh.indexOf("\nacquire_archive_lock", fnStart);
  const fn = shipSh.slice(fnStart, fnEnd);
  assert.match(fn, /handle_ensure_tf_ready_rc "\$rc"/);
  assert.match(fn, /TF_READY_CONFIRMED=1/);
});
