import { afterEach, describe, expect, it } from "vitest";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { generateKeyPairSync } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * C-135: the iOS ship tooling consumes complete Infisical-synced environment
 * tuples, never the retired reader or home-directory secrets folder.
 *
 * AFC-459: a path on disk is not an approved credential source at all, so a
 * named ASC_KEY_PATH is ignored wherever it appears.  These run the real
 * credential block of scripts/ios-fleet/ship-testflight.sh.  The retired reader
 * is only a failure marker, with no credential material.  Keys are generated
 * here; HOME and TMPDIR point at disposable fixture directories.
 */

const ROOT = join(__dirname, "..");
const SHIP = join(ROOT, "scripts/ios-fleet/ship-testflight.sh");
const OLD_DIR = "." + "secrets";

//  A real key pair, generated here at test time:  the shell layer parses the
//  PEM before it accepts it, so a fake envelope is not a key.  Nothing is
//  committed and no key is ever printed.
const PEM = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
  .privateKey.export({ type: "pkcs8", format: "pem" }) as string;
const OTHER_PEM = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
  .privateKey.export({ type: "pkcs8", format: "pem" }) as string;

const STUB = `#!/bin/sh
printf '%s\\n' unexpected-reader >> "$STUB_CALLS"
exit 97
`;

//  The comparison answers through the exit code only, so a credential is never
//  expanded into the shell where a trace would show it:  the staged file is
//  compared with the expected key and only a label is printed.
const REPORT = `
status=0
load_secrets || status=$?
echo "status=$status"
echo "mode=$AUTH_MODE"
echo "tmpdir=\${ASC_TMP_DIR:-}"
if [ "$AUTH_MODE" = api_key ]; then
  echo "keyid=$ASC_KEY_ID"
  echo "issuer=$ASC_ISSUER_ID"
  echo "path=$ASC_KEY_PATH"
  echo "keysdir=\${API_PRIVATE_KEYS_DIR:-}"
  echo "keyperm=$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$ASC_KEY_PATH")"
  echo "dirperm=$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$(dirname "$ASC_KEY_PATH")")"
  echo "pem=$(grep -c 'BEGIN PRIVATE KEY' "$ASC_KEY_PATH")"
  if VALUE_TO_COMPARE="\${EXPECTED_PEM}" node -e 'const fs=require("fs");const v=process.env.VALUE_TO_COMPARE||"";const f=fs.readFileSync(process.argv[1],"utf8").trim();process.exit(v.trim()===f?0:1)' "$ASC_KEY_PATH"; then
    echo "staged=expected"
  else
    echo "staged=other"
  fi
fi
exit "$status"
`;

const dirs: string[] = [];
afterEach(() => {
  while (dirs.length) rmSync(dirs.pop() as string, { recursive: true, force: true });
});

function scratch() {
  const dir = mkdtempSync(join(tmpdir(), "asc-cred-test-"));
  dirs.push(dir);
  const stub = join(dir, "fleet-secrets");
  writeFileSync(stub, STUB);
  chmodSync(stub, 0o755);
  return { dir, stub, calls: join(dir, "calls.log") };
}

function runBlock(env: Record<string, string>, tail: string) {
  const script = `
set -euo pipefail
log() { echo "log: $*" >&2; }
eval "$(sed -n '/^# --- ASC credentials begin/,/^# --- ASC credentials end/p' "$SHIP")"
${tail}
`;
  return spawnSync("bash", ["-c", script], {
    env: {
      PATH: `${env.HOME}:${process.env.PATH ?? ""}`,
      SHIP,
      FLEET_DIR: join(ROOT, "scripts/ios-fleet"),
      ...env,
    },
    encoding: "utf8",
  });
}

const parse = (out: string): Record<string, string> =>
  Object.fromEntries(out.trim().split("\n").map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));

function expectNoReaderOrStaging(dir: string, calls: string, reported: Record<string, string> = {}) {
  expect(existsSync(calls)).toBe(false);
  for (const path of [reported.tmpdir, reported.keysdir]) {
    if (path) expect(existsSync(path), "reported ASC staging directory survived exit").toBe(false);
  }
  const pending = [dir];
  while (pending.length) {
    const parent = pending.pop() as string;
    for (const entry of readdirSync(parent, { withFileTypes: true })) {
      expect(entry.name).not.toMatch(/^asc-key\./);
      expect(entry.name).not.toMatch(/^AuthKey_[A-Za-z0-9]+\.p8$/);
      expect(entry.name).not.toBe(OLD_DIR);
      if (entry.isDirectory()) pending.push(join(parent, entry.name));
    }
  }
}

describe("ASC credentials in ship-testflight.sh", () => {
  it("stages the complete direct export at mode 0600 in a 0700 dir and removes it on exit", () => {
    const s = scratch();
    const r = runBlock(
      {
        HOME: s.dir, TMPDIR: s.dir, FLEET_SECRETS_BIN: s.stub, STUB_CALLS: s.calls,
        ASC_KEY_ID: "TESTKEY123", ASC_ISSUER_ID: "direct-issuer", ASC_KEY_P8: PEM, EXPECTED_PEM: PEM,
      },
      REPORT,
    );
    expect(r.status, r.stderr).toBe(0);
    const out = parse(r.stdout);
    expect(out.mode).toBe("api_key");
    expect(out.status).toBe("0");
    expect(out.keyid).toBe("TESTKEY123");
    expect(out.issuer).toBe("direct-issuer");
    expect(out.path).toMatch(/\/AuthKey_TESTKEY123\.p8$/);
    expect(out.keysdir).toBe(out.path.replace(/\/[^/]+$/, ""));
    expect(out.tmpdir).toBe(out.keysdir);
    expect(out.keyperm).toBe("600");
    expect(out.dirperm).toBe("700");
    expect(out.pem).toBe("1");
    expect(out.staged).toBe("expected");
    expect(existsSync(out.path)).toBe(false);
    expect(r.stdout + r.stderr).not.toContain(PEM.trim());
    expectNoReaderOrStaging(s.dir, s.calls, out);
  });

  it("selects the complete APPLE_API_* export ahead of another complete direct tuple", () => {
    const s = scratch();
    const r = runBlock(
      {
        HOME: s.dir, TMPDIR: s.dir, FLEET_SECRETS_BIN: s.stub, STUB_CALLS: s.calls,
        ASC_KEY_ID: "DIRECTKEY", ASC_ISSUER_ID: "direct-issuer", ASC_KEY_P8: PEM,
        APPLE_API_KEY_ID: "CIKEY", APPLE_API_ISSUER_ID: "ci-issuer",
        APPLE_API_KEY_P8_BASE64: Buffer.from(OTHER_PEM).toString("base64"), EXPECTED_PEM: OTHER_PEM,
      },
      REPORT,
    );
    expect(r.status, r.stderr).toBe(0);
    const out = parse(r.stdout);
    expect(out.mode).toBe("api_key");
    expect(out.keyid).toBe("CIKEY");
    expect(out.issuer).toBe("ci-issuer");
    expect(out.path).toMatch(/\/AuthKey_CIKEY\.p8$/);
    expect(out.staged).toBe("expected");
    expect(r.stdout + r.stderr).not.toContain(OTHER_PEM.trim());
    expectNoReaderOrStaging(s.dir, s.calls, out);
  });

  it("takes the key from the environment and never from a named ASC_KEY_PATH", () => {
    //  The environment wins:  a stale or foreign path in an operator's shell
    //  must never decide which key signs the upload (AFC-459, Kody rule 42).
    const s = scratch();
    const named = join(s.dir, "named.p8");
    writeFileSync(named, OTHER_PEM, { mode: 0o600 });
    const r = runBlock(
      {
        HOME: s.dir, TMPDIR: s.dir, FLEET_SECRETS_BIN: s.stub, STUB_CALLS: s.calls,
        ASC_KEY_ID: "ENVKEY", ASC_ISSUER_ID: "iss", ASC_KEY_P8: PEM, ASC_KEY_PATH: named,
        EXPECTED_PEM: PEM,
      },
      REPORT,
    );
    expect(r.status, r.stderr).toBe(0);
    const out = parse(r.stdout);
    expect(out.mode).toBe("api_key");
    //  The staged key is the one from the environment, never the named file.
    expect(out.staged).toBe("expected");
    expect(out.path).not.toBe(named);
    expect(r.stderr).toMatch(/ASC_KEY_PATH is not a credential source/);
    expect(readFileSync(named, "utf8")).toBe(OTHER_PEM);
    expectNoReaderOrStaging(s.dir, s.calls, out);
  });

  it("refuses a path-only binding without staging or calling the retired reader", () => {
    const s = scratch();
    const named = join(s.dir, "named.p8");
    writeFileSync(named, OTHER_PEM, { mode: 0o600 });
    const r = runBlock(
      {
        HOME: s.dir, TMPDIR: s.dir, FLEET_SECRETS_BIN: s.stub, STUB_CALLS: s.calls,
        ASC_KEY_ID: "TESTKEY123", ASC_ISSUER_ID: "00000000-test-issuer", ASC_KEY_PATH: named,
      },
      REPORT,
    );
    expect(r.status, r.stderr).toBe(1);
    const out = parse(r.stdout);
    expect(out.mode).toBe("none");
    expect(out.tmpdir).toBe("");
    for (const name of ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID", "APPLE_API_KEY_P8_BASE64"]) {
      expect(r.stderr).toContain(name);
    }
    expect(r.stdout + r.stderr).not.toContain(OTHER_PEM.trim());
    expect(readFileSync(named, "utf8")).toBe(OTHER_PEM);
    expectNoReaderOrStaging(s.dir, s.calls, out);
  });

  it("decodes the complete hosted APPLE_API_* export without calling a reader", () => {
    const s = scratch();
    const r = runBlock(
      {
        HOME: s.dir, TMPDIR: s.dir, FLEET_SECRETS_BIN: s.stub, STUB_CALLS: s.calls,
        APPLE_API_KEY_ID: "CIKEY", APPLE_API_ISSUER_ID: "ciiss",
        APPLE_API_KEY_P8_BASE64: Buffer.from(PEM).toString("base64"),
        EXPECTED_PEM: PEM,
      },
      REPORT,
    );
    expect(r.status, r.stderr).toBe(0);
    const out = parse(r.stdout);
    expect(out.mode).toBe("api_key");
    expect(out.path).toMatch(/\/AuthKey_CIKEY\.p8$/);
    expect(out.pem).toBe("1");
    expect(out.staged).toBe("expected");
    expectNoReaderOrStaging(s.dir, s.calls, out);
  });

  it("refuses missing, partial, mixed and malformed preferred exports without reader fallback", () => {
    const cases: Record<string, string>[] = [
      {},
      { ASC_KEY_ID: "DIRECTKEY" },
      { ASC_KEY_ID: "DIRECTKEY", ASC_ISSUER_ID: "direct-issuer" },
      { ASC_KEY_P8: PEM },
      { APPLE_API_KEY_ID: "CIKEY", APPLE_API_ISSUER_ID: "ci-issuer" },
      { APPLE_API_KEY_P8_BASE64: Buffer.from(PEM).toString("base64") },
      { ASC_KEY_ID: "DIRECTKEY", APPLE_API_ISSUER_ID: "ci-issuer", ASC_KEY_P8: PEM },
      {
        ASC_KEY_ID: "DIRECTKEY", ASC_ISSUER_ID: "direct-issuer", ASC_KEY_P8: PEM,
        APPLE_API_KEY_ID: "CIKEY", APPLE_API_ISSUER_ID: "ci-issuer", APPLE_API_KEY_P8_BASE64: "not-a-key",
      },
    ];
    for (const tuple of cases) {
      const s = scratch();
      const r = runBlock({ HOME: s.dir, TMPDIR: s.dir, FLEET_SECRETS_BIN: s.stub, STUB_CALLS: s.calls, ...tuple }, REPORT);
      expect(r.status, r.stderr).toBe(1);
      const out = parse(r.stdout);
      expect(out.mode).toBe("none");
      expect(out.tmpdir).toBe("");
      expect(out.path).toBeUndefined();
      expect(r.stderr).toContain("ASC_KEY_P8");
      expect(r.stderr).toContain("APPLE_API_KEY_P8_BASE64");
      if (!tuple.APPLE_API_KEY_P8_BASE64 || !tuple.ASC_KEY_ID) {
        expect(r.stderr).toContain("ASC_KEY_ID");
        expect(r.stderr).toContain("ASC_ISSUER_ID");
        expect(r.stderr).toContain("APPLE_API_KEY_ID");
        expect(r.stderr).toContain("APPLE_API_ISSUER_ID");
      }
      expect(r.stdout + r.stderr).not.toContain(PEM.trim());
      expectNoReaderOrStaging(s.dir, s.calls, out);
    }
  });

  it("detects nested staging and an empty reported directory under another prefix", () => {
    const s = scratch();
    const orphan = join(s.dir, "nested", "asc-key.orphan");
    mkdirSync(orphan, { recursive: true, mode: 0o700 });
    writeFileSync(join(orphan, "AuthKey_ORPHAN.p8"), "fixture", { mode: 0o600 });
    expect(() => expectNoReaderOrStaging(s.dir, s.calls)).toThrow();
    rmSync(orphan, { recursive: true });
    const reported = join(s.dir, "nested", "different-prefix");
    mkdirSync(reported, { mode: 0o700 });
    expect(() => expectNoReaderOrStaging(s.dir, s.calls, { tmpdir: reported, keysdir: reported })).toThrow();
    rmSync(reported, { recursive: true });
    expectNoReaderOrStaging(s.dir, s.calls);
  });

  it("no ship script reads the old secrets folder", () => {
    for (const file of [
      "scripts/ios-fleet/ship-testflight.sh",
      "scripts/ios-fleet/asc-api.mjs",
      "scripts/ios-appstore-gm-prepare.sh",
    ]) {
      expect(readFileSync(join(ROOT, file), "utf8").includes(OLD_DIR), `${file} mentions ${OLD_DIR}`).toBe(false);
    }
  });
});
