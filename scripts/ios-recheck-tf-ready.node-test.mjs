import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const BUILD = "202611091430000";

test("ios-recheck-tf-ready fails fast when apps.json is missing appleId", () => {
  const dir = mkdtempSync(join(tmpdir(), "recheck-tf-"));
  const fleet = join(dir, "ios-fleet");
  mkdirSync(fleet);
  writeFileSync(
    join(fleet, "apps.json"),
    JSON.stringify({
      apps: {
        clutch: {
          bundleId: "codes.clutch.ios",
          fixedMarketingVersion: "0.1.0",
        },
      },
    }),
  );
  cpSync(join(ROOT, "scripts/ios-fleet/tf-ready-rc.sh"), join(fleet, "tf-ready-rc.sh"));
  try {
    const r = spawnSync("bash", [join(ROOT, "scripts/ios-recheck-tf-ready.sh"), "clutch", BUILD], {
      cwd: ROOT,
      env: { ...process.env, IOS_RECHECK_FLEET_DIR: fleet },
      encoding: "utf8",
    });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /::error::recheck-tf-ready:.*appleId is missing/);
  } finally {
    unlinkSync(join(fleet, "apps.json"));
    unlinkSync(join(fleet, "tf-ready-rc.sh"));
  }
});
