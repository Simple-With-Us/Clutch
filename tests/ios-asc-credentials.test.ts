import { afterEach, describe, expect, it } from "vitest";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { generateKeyPairSync } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * AFC-359: the iOS ship tooling reads App Store Connect credentials from the
 * environment or Infisical (`fleet-secrets get`), never from the old
 * home-directory secrets folder.
 *
 * AFC-459: a path on disk is not an approved credential source at all, so a
 * named ASC_KEY_PATH is ignored wherever it appears.  These run the real
 * credential block of scripts/ios-fleet/ship-testflight.sh against a stub
 * fleet-secrets.  The keys are generated here at test time;  values are
 * dummies;  HOME and TMPDIR point at scratch dirs.
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
echo "$@" >> "$STUB_CALLS"
[ "$1" = "get" ] && [ "$3" = "--path" ] || exit 4
case "$2:$4" in
  ASC_KEY_ID:/asc) printf '%s' TESTKEY123 ;;
  ASC_ISSUER_ID:/asc) printf '%s' 00000000-test-issuer ;;
  ASC_KEY_P8:/asc) printf '%s' '${PEM}' ;;
  AUTHKEY_TESTKEY123:/authkey-testkey123-p8) printf '%s' '${OTHER_PEM}' ;;
  AUTHKEY_OTHERKEY:/authkey-otherkey-p8) printf '%s' '${OTHER_PEM}' ;;
  *) exit 3 ;;
esac
`;

//  The comparison answers through the exit code only, so a credential is never
//  expanded into the shell where a trace would show it:  the staged file is
//  compared with the expected key and only a label is printed.
const REPORT = `
load_secrets
echo "mode=$AUTH_MODE"
if [ "$AUTH_MODE" = api_key ]; then
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
      PATH: process.env.PATH ?? "",
      SHIP,
      FLEET_DIR: join(ROOT, "scripts/ios-fleet"),
      ...env,
    },
    encoding: "utf8",
  });
}

const parse = (out: string): Record<string, string> =>
  Object.fromEntries(out.trim().split("\n").map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));

describe("ASC credentials in ship-testflight.sh", () => {
  it("stages the Infisical key at mode 0600 in a 0700 dir and removes it on exit", () => {
    const s = scratch();
    const r = runBlock(
      { HOME: s.dir, TMPDIR: s.dir, FLEET_SECRETS_BIN: s.stub, STUB_CALLS: s.calls, EXPECTED_PEM: PEM },
      REPORT,
    );
    expect(r.status, r.stderr).toBe(0);
    const out = parse(r.stdout);
    expect(out.mode).toBe("api_key");
    expect(out.path).toMatch(/\/AuthKey_TESTKEY123\.p8$/);
    expect(out.keysdir).toBe(out.path.replace(/\/[^/]+$/, ""));
    expect(out.keyperm).toBe("600");
    expect(out.dirperm).toBe("700");
    expect(out.pem).toBe("1");
    expect(out.staged).toBe("expected");
    expect(existsSync(out.path)).toBe(false);
    const calls = readFileSync(s.calls, "utf8");
    expect(calls).toMatch(/get ASC_KEY_ID --path \/asc/);
    expect(calls).toMatch(/get ASC_KEY_P8 --path \/asc/);
    expect(calls).not.toMatch(/authkey-/);
    expect(existsSync(join(s.dir, OLD_DIR))).toBe(false);
  });

  it("falls back to the per-key copy when the key id differs from the /asc one", () => {
    const s = scratch();
    const r = runBlock(
      {
        HOME: s.dir, TMPDIR: s.dir, FLEET_SECRETS_BIN: s.stub, STUB_CALLS: s.calls,
        ASC_KEY_ID: "OTHERKEY", ASC_ISSUER_ID: "iss", EXPECTED_PEM: OTHER_PEM,
      },
      REPORT,
    );
    expect(r.status, r.stderr).toBe(0);
    const out = parse(r.stdout);
    expect(out.mode).toBe("api_key");
    expect(out.path).toMatch(/\/AuthKey_OTHERKEY\.p8$/);
    expect(out.staged).toBe("expected");
    const calls = readFileSync(s.calls, "utf8");
    expect(calls).toMatch(/get AUTHKEY_OTHERKEY --path \/authkey-otherkey-p8/);
    expect(calls).not.toMatch(/get ASC_KEY_P8/);
  });

  it("takes the key from the environment and never from a named ASC_KEY_PATH", () => {
    //  The environment wins:  a stale or foreign path in an operator's shell
    //  must never decide which key signs the upload (AFC-459, Kody rule 42).
    const s = scratch();
    const named = join(s.dir, "named.p8");
    writeFileSync(named, OTHER_PEM);
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
    expect(existsSync(s.calls)).toBe(false);
  });

  it("ignores a named ASC_KEY_PATH and says so", () => {
    //  A path on disk is not an approved credential source at all:  with no
    //  key in the environment the credential comes from Infisical, and the run
    //  says that it ignored the named path.
    const s = scratch();
    const named = join(s.dir, "named.p8");
    writeFileSync(named, OTHER_PEM);
    const r = runBlock(
      {
        HOME: s.dir, TMPDIR: s.dir, FLEET_SECRETS_BIN: s.stub, STUB_CALLS: s.calls,
        ASC_KEY_ID: "TESTKEY123", ASC_ISSUER_ID: "00000000-test-issuer", ASC_KEY_PATH: named,
        EXPECTED_PEM: PEM,
      },
      REPORT,
    );
    expect(r.status, r.stderr).toBe(0);
    const out = parse(r.stdout);
    expect(out.mode).toBe("api_key");
    expect(out.staged).toBe("expected");
    expect(out.path).not.toBe(named);
    expect(r.stderr).toMatch(/ASC_KEY_PATH is not a credential source/);
    const calls = readFileSync(s.calls, "utf8");
    expect(calls).toMatch(/get ASC_KEY_P8 --path \/asc/);
  });

  it("decodes the hosted APPLE_API_* base64 key without calling Infisical for the PEM", () => {
    const s = scratch();
    const r = runBlock(
      {
        HOME: s.dir, TMPDIR: s.dir, FLEET_SECRETS_BIN: join(s.dir, "absent"), STUB_CALLS: s.calls,
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
  });

  it("leaves AUTH_MODE=none and names the Infisical folder when nothing is available", () => {
    const s = scratch();
    const r = runBlock({ HOME: s.dir, TMPDIR: s.dir, FLEET_SECRETS_BIN: join(s.dir, "absent"), STUB_CALLS: s.calls }, REPORT);
    expect(r.status, r.stderr).toBe(0);
    expect(parse(r.stdout).mode).toBe("none");
    expect(r.stderr).toMatch(/Infisical \/asc/);
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
