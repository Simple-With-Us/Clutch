// The App Store Connect private key:  how it is validated, and how it is
// staged for the Apple tools that need a key on disk.
//
// AFC-459, revision 2 (Kody rule 42):  a path on disk is not an approved
// credential source at all, so this module never reads a file.  The approved
// sources are complete Infisical-synced environment tuples.  The module validates a key,
// writes a mode-600 staging copy for altool and Xcode, and builds the
// allowlisted environment a child process runs with.
//
// Everything here is synthetic:  the keys are generated at test time and are
// never committed, and HTTP fixtures use literal loopback destinations only.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createVerify, generateKeyPairSync } from "node:crypto";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test, { after } from "node:test";

import { normalizePrivateKey, writePrivateKeyFile, CLIENT_ENV_ALLOWLIST, clientEnvironment } from "./asc-key.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const helper = join(here, "asc-key.mjs");
const client = join(here, "asc-api.mjs");
const root = mkdtempSync(join(tmpdir(), "asc-key-test-"));
after(() => rmSync(root, { recursive: true, force: true }));
//  A PATH with node and nothing else:  the fleet reader lives in the operator's
//  own bin directory, and a test must never reach it or Infisical.
const safePath = [dirname(process.execPath), "/usr/bin", "/bin"].join(":");
//  Two key pairs:  the first one signs the requests, the second one only ever
//  appears in a named key file, so a test can tell which key was used.
const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const keyPem = pair.privateKey.export({ type: "pkcs8", format: "pem" });
const otherPair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const otherPem = otherPair.privateKey.export({ type: "pkcs8", format: "pem" });

function staged(name, content = keyPem, mode = 0o600) {
  const path = join(root, name);
  writeFileSync(path, content);
  chmodSync(path, mode);
  return path;
}

function run(args, stdin = "", env = undefined) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [helper, ...args], {
      ...(env ? { env } : {}),
      stdio: ["pipe", "pipe", "pipe"], timeout: 15_000, killSignal: "SIGKILL"
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    child.stdin.on("error", reject);
    child.stdin.end(stdin);
  });
}

function spawnNode(args, env) {
  if (args[0] === client && args[1] === "GET") {
    assert.match(args[2], /^http:\/\/127\.0\.0\.1:[0-9]+\//, "fixture GET must name literal loopback before spawning");
    const target = new URL(args[2]);
    assert.equal(target.protocol, "http:");
    assert.equal(target.hostname, "127.0.0.1", "fixture GET must target literal loopback before spawning");
  }
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, args, { env, stdio: ["ignore", "pipe", "pipe"], timeout: 15_000, killSignal: "SIGKILL" });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

function localServer() {
  const seen = [];
  const server = createServer((req, res) => {
    seen.push({ url: req.url, authorization: req.headers.authorization || "" });
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ data: [] }));
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve({
      base: `http://127.0.0.1:${server.address().port}`,
      seen,
      close: () => server.close()
    }));
  });
}

test("fixture GET guard refuses relative and non-loopback destinations before spawning", () => {
  for (const target of ["/v1/apps", "https://api.appstoreconnect.apple.com/v1/apps", "http://example.invalid/v1/apps", "http://2130706433:80/v1/apps"]) {
    assert.throws(() => spawnNode([client, "GET", target], {}));
  }
});

function jwtKeyId(authorization) {
  const token = String(authorization || "").replace(/^Bearer /, "");
  if (!token) return null;
  return JSON.parse(Buffer.from(token.split(".")[0], "base64url").toString()).kid;
}

//  True when the request was signed with the given key pair:  the client signs
//  with the JOSE (r||s) encoding, so the signature is verified the same way.
function jwtSignedBy(authorization, publicKey) {
  const token = String(authorization || "").replace(/^Bearer /, "");
  const parts = token.split(".");
  if (parts.length !== 3) return false;
  const verifier = createVerify("SHA256");
  verifier.update(`${parts[0]}.${parts[1]}`);
  verifier.end();
  return verifier.verify({ key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(parts[2], "base64url"));
}

test("a generated key is accepted and comes back with a trailing newline", () => {
  const normalized = normalizePrivateKey(keyPem);
  assert.ok(normalized, "a real key was refused");
  assert.ok(normalized.endsWith("\n"), "the key has to end with a newline");
  assert.equal(normalized.trim(), keyPem.trim());
});

test("a malformed PEM is refused, because the envelope is not a key", () => {
  //  A truncated key, an armored block and a mangled export all carry the
  //  envelope and still fail to parse.  Accepting them would hand the signer
  //  something it cannot use, and the failure would come back as a stack
  //  trace instead of a credential error.
  const envelope = keyPem.trim().split("\n");
  assert.equal(normalizePrivateKey([envelope[0], "not base64 at all", envelope.at(-1), ""].join("\n")), null);
  assert.equal(normalizePrivateKey([envelope[0], envelope.at(-1), ""].join("\n")), null);
  assert.equal(normalizePrivateKey(""), null);
  assert.equal(normalizePrivateKey(undefined), null);
  assert.equal(normalizePrivateKey("hunter2"), null);
});

test("the module exports exactly the four approved names", async () => {
  //  The module is small on purpose:  it validates a key, stages it and builds
  //  the child's environment.  A reader, an executor or any other way in
  //  would make a path on disk a credential source again.
  const mod = await import("./asc-key.mjs");
  assert.deepEqual(
    Object.keys(mod).sort(),
    ["CLIENT_ENV_ALLOWLIST", "clientEnvironment", "normalizePrivateKey", "writePrivateKeyFile"]
  );
});

test("the module never reads a key file", () => {
  const source = readFileSync(helper, "utf8");
  assert.doesNotMatch(source, /readFileSync/, "the module reads a file");
  assert.doesNotMatch(source, /O_NOFOLLOW/, "the module opens a file with O_NOFOLLOW");
  assert.doesNotMatch(source, /readPrivateKeyFile/, "the module exposes a file reader");
  assert.doesNotMatch(source, /execWithKey/, "the module exposes a key executor");
});

test("the command line validates a key on stdin and never prints it", async () => {
  //  A key on stdout is a key in every log that captures it, so the module
  //  reports whether the key is usable and nothing else.
  const ok = await run(["validate"], keyPem);
  assert.equal(ok.code, 0, `the key was refused: ${ok.stderr}`);
  assert.match(ok.stdout, /is a PEM private key/, `the status was not reported:\n${ok.stdout}`);
  assert.doesNotMatch(ok.stdout, /PRIVATE KEY/, "the key reached stdout");
  assert.doesNotMatch(ok.stderr, /PRIVATE KEY/, "the key reached stderr");
});

test("the command line refuses a value that is not a key", async () => {
  const bad = await run(["validate"], "not a private key at all");
  assert.notEqual(bad.code, 0);
  assert.match(bad.stderr, /not a PEM private key/);
  assert.equal(bad.stdout, "", "a refused key must not put anything on stdout");
});

test("there is no read subcommand and no exec subcommand", async () => {
  //  Revision 2 removed both:  a path on disk is not an approved credential
  //  source, so there is nothing for them to do.
  const path = staged("no-such-command.p8");
  const read = await run(["read", path]);
  assert.notEqual(read.code, 0, "the module still has a read subcommand");
  assert.match(read.stderr, /usage: asc-key\.mjs validate \| write <path>/);

  const exec = await run(["exec", path, "--", process.execPath, "-e", "process.exit(0)"]);
  assert.notEqual(exec.code, 0, "the module still has an exec subcommand");
  assert.match(exec.stderr, /usage: asc-key\.mjs validate \| write <path>/);
});

test("the command line writes a key to a file only its owner can read", async () => {
  const path = join(root, "written.p8");
  const result = await run(["write", path], keyPem);
  assert.equal(result.code, 0, `the write failed: ${result.stderr}`);
  assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.equal(readFileSync(path, "utf8").trim(), keyPem.trim());
});

test("the command line refuses to write a value that is not a key", async () => {
  const path = join(root, "refused.p8");
  const result = await run(["write", path], "not a private key");
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /not a PEM private key/);
  assert.equal(existsSync(path), false, "a refused key must not leave a file behind");
});

test("writePrivateKeyFile normalizes the key and refuses anything else", () => {
  const path = join(root, "direct.p8");
  const written = writePrivateKeyFile(path, keyPem.replace(/\r\n/g, "\n"));
  assert.ok(written.pem, `the write failed: ${written.error}`);
  assert.equal(written.pem.endsWith("\n"), true);
  assert.equal(statSync(path).mode & 0o777, 0o600);
  const refused = writePrivateKeyFile(join(root, "direct-bad.p8"), "hunter2");
  assert.ok(refused.error, "a value that is not a key was written");
  assert.match(refused.error, /not a PEM private key/);
});

test("the child's environment is an allowlist, never a copy of the parent's", () => {
  //  A wholesale copy hands every credential on the operator's machine to the
  //  child, including the ones that have nothing to do with App Store Connect.
  const child = clientEnvironment({
    PATH: "/usr/bin:/bin",
    HOME: "/tmp/home",
    ASC_KEY_ID: "SYNTHETICKEYID1",
    ASC_ISSUER_ID: "synthetic-issuer",
    SECRET_TOKEN: "not-for-the-child",
    FLEET_SECRETS_BIN: "/untrusted/reader",
    FLEET_SECRETS: "untrusted-reader"
  });
  assert.equal(child.PATH, "/usr/bin:/bin");
  assert.equal(child.HOME, "/tmp/home");
  assert.equal(child.ASC_KEY_ID, "SYNTHETICKEYID1");
  assert.equal(child.SECRET_TOKEN, undefined, "a credential crossed over to the child");
  assert.equal(child.FLEET_SECRETS_BIN, undefined);
  assert.equal(child.FLEET_SECRETS, undefined);
  assert.ok(!Object.keys(child).includes("ASC_KEY_P8"), "the key belongs in no inherited variable");
  assert.ok(!CLIENT_ENV_ALLOWLIST.includes("ASC_KEY_P8"), "the key must not be an inherited variable");
  //  The key is added separately, by the caller that owns it.
  const withKey = clientEnvironment({ PATH: "/usr/bin:/bin" }, { ASC_KEY_P8: keyPem });
  assert.equal(withKey.ASC_KEY_P8, keyPem);
});

test("the client takes the key from the environment and ignores a named ASC_KEY_PATH", async () => {
  //  The environment wins over a named file:  a stale or foreign path in an
  //  operator's shell must never decide which key signs the request.
  const server = await localServer();
  try {
    const result = await spawnNode([client, "GET", `${server.base}/v1/apps`], {
      PATH: safePath,
      HOME: join(root, "home-client"),
      ASC_API_BASE: server.base,
      ASC_KEY_ID: "SYNTHETICKEYID1",
      ASC_ISSUER_ID: "synthetic-issuer",
      ASC_KEY_P8: keyPem,
      ASC_KEY_PATH: staged("named-client.p8", otherPem)
    });
    assert.equal(result.code, 0, `the client failed: ${result.stderr}`);
    assert.match(result.stderr, /asc-auth: using ASC_KEY_P8 environment/,
      `the client did not report the environment source:\n${result.stderr}`);
    assert.doesNotMatch(result.stderr, /ASC_KEY_PATH/, "the client talked about a named path");
    assert.ok(server.seen.length > 0, "the client never reached App Store Connect");
    assert.equal(jwtKeyId(server.seen[0].authorization), "SYNTHETICKEYID1");
    assert.ok(jwtSignedBy(server.seen[0].authorization, pair.publicKey),
      "the request was not signed with the key from the environment");
    assert.ok(!jwtSignedBy(server.seen[0].authorization, otherPair.publicKey),
      "the request was signed with the key from the named file");
    assert.doesNotMatch(result.stdout + result.stderr, /BEGIN PRIVATE KEY/,
      "the key reached the client's output");
  } finally {
    server.close();
  }
});

test("a named ASC_KEY_PATH is not a credential for the client either", async () => {
  //  With a named file and no key in the environment the client has no
  //  credential at all:  a path on disk is not an approved source, and the
  //  refusal says so.
  const result = await spawnNode([client, "GET", "http://127.0.0.1:1/v1/apps"], {
    PATH: safePath,
    HOME: join(root, "home-empty"),
    ASC_API_BASE: "http://127.0.0.1:1",
    ASC_KEY_ID: "SYNTHETICKEYID1",
    ASC_ISSUER_ID: "synthetic-issuer",
    ASC_KEY_PATH: staged("named-only.p8", otherPem)
  });
  assert.equal(result.code, 1, `expected the refusal exit, got ${result.code}: ${result.stderr}`);
  assert.match(result.stderr, /no App Store Connect credential found/);
  assert.match(result.stderr, /A path in ASC_KEY_PATH is not a credential source/);
});

test("the client source never reads a key path", () => {
  const source = readFileSync(client, "utf8");
  assert.doesNotMatch(source, /process\.env\.ASC_KEY_PATH/, "the client reads a named key path");
  assert.doesNotMatch(source, /fromFile/, "the client still has a file reader");
});

test("real client refuses every incomplete tuple before API access", async () => {
  const server = await localServer();
  try {
    const tuples = [
      { ASC_KEY_ID: "RAWKEY01", ASC_ISSUER_ID: "raw-issuer", ASC_KEY_P8: keyPem },
      { APPLE_API_KEY_ID: "CIKEY01", APPLE_API_ISSUER_ID: "ci-issuer", APPLE_API_KEY_P8_BASE64: Buffer.from(otherPem).toString("base64") }
    ];
    for (const tuple of tuples) {
      const entries = Object.entries(tuple);
      for (let mask = 0; mask < 7; mask += 1) {
        const partial = Object.fromEntries(entries.filter((_entry, i) => mask & (1 << i)));
        const result = await spawnNode([client, "GET", `${server.base}/v1/apps`], {
          PATH: safePath, HOME: join(root, "empty-client"), ASC_API_BASE: server.base,
          ASC_KEY_PATH: staged("unused.p8", otherPem), ...partial
        });
        assert.equal(result.code, 1, "an incomplete tuple was accepted");
        for (const name of Object.keys(tuple)) assert.ok(result.stderr.includes(name));
        assert.ok(!result.stdout.includes(keyPem.trim()) && !result.stderr.includes(otherPem.trim()));
      }
    }
    const mixed = await spawnNode([client, "GET", `${server.base}/v1/apps`], {
      PATH: safePath, HOME: join(root, "mixed-client"), ASC_API_BASE: server.base,
      ASC_KEY_ID: "RAWKEY01", APPLE_API_ISSUER_ID: "ci-issuer", ASC_KEY_P8: keyPem
    });
    assert.equal(mixed.code, 1);
    assert.equal(server.seen.length, 0);
  } finally { server.close(); }
});

test("real client chooses the producer tuple as a unit and cleans its staging copy", async () => {
  const server = await localServer();
  const temp = mkdtempSync(join(root, "client-temp-"));
  try {
    const result = await spawnNode([client, "GET", `${server.base}/v1/apps`], {
      PATH: safePath, HOME: join(root, "producer-client"), TMPDIR: temp, ASC_API_BASE: server.base,
      ASC_KEY_ID: "RAWKEY01", ASC_ISSUER_ID: "raw-issuer", ASC_KEY_P8: keyPem,
      APPLE_API_KEY_ID: "CIKEY01", APPLE_API_ISSUER_ID: "ci-issuer",
      APPLE_API_KEY_P8_BASE64: Buffer.from(otherPem).toString("base64")
    });
    assert.equal(result.code, 0, result.stderr);
    assert.equal(jwtKeyId(server.seen[0].authorization), "CIKEY01");
    const payload = JSON.parse(Buffer.from(server.seen[0].authorization.split(".")[1], "base64url"));
    assert.equal(payload.iss, "ci-issuer");
    assert.ok(jwtSignedBy(server.seen[0].authorization, otherPair.publicKey));
    assert.ok(!jwtSignedBy(server.seen[0].authorization, pair.publicKey));
    assert.deepEqual(readdirSync(temp), []);
    assert.ok(!result.stdout.includes(otherPem.trim()) && !result.stderr.includes(otherPem.trim()));
  } finally { server.close(); }
});

const prep = join(here, "..", "ios-appstore-gm-prepare.sh");
const prepBin = join(root, "prep-bin");
mkdirSync(prepBin);
for (const [name, body] of Object.entries({
  sw_vers: 'if [ "$1" = -productVersion ]; then echo 26.1; else echo 25F84; fi',
  openssl: 'printf "%s\\n" openssl >> "$FAKE_SIGNING_LOG"; printf "%s\\n" fixture-pass',
  security: 'printf "%s\\n" "$1" >> "$FAKE_SIGNING_LOG"; if [ "$1" = find-identity ]; then echo "Apple Distribution"; fi'
})) {
  writeFileSync(join(prepBin, name), `#!/bin/bash\n${body}\n`, { mode: 0o700 });
}

for (const name of ["xcodebuild", "xcrun", "asc-query"]) {
  writeFileSync(join(prepBin, name), '#!/bin/bash\nprintf "%s\\n" unexpected-tool >> "$FAKE_SIGNING_LOG"\nexit 99\n', { mode: 0o700 });
}

async function prepare(extra) {
  const temp = mkdtempSync(join(root, "prepare-"));
  const env = {
    PATH: `${prepBin}:${safePath}`, HOME: join(temp, "home"), TMPDIR: temp, RUNNER_TEMP: temp,
    GITHUB_ENV: join(temp, "github-env"), FAKE_SIGNING_LOG: join(temp, "tools.log"), ...extra
  };
  const result = await new Promise((resolve, reject) => {
    const child = spawn("/bin/bash", [prep], { env, stdio: ["ignore", "pipe", "pipe"], timeout: 15_000, killSignal: "SIGKILL" });
    let stdout = "", stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", code => resolve({ code, stdout, stderr }));
  });
  assert.ok(!result.stdout.includes(keyPem.trim()) && !result.stderr.includes(keyPem.trim()));
  assert.ok(!result.stdout.includes(otherPem.trim()) && !result.stderr.includes(otherPem.trim()));
  return { ...result, temp, env };
}

test("actual preparation preserves producer and direct tuples in private runner staging", async () => {
  for (const producer of [true, false]) {
    const result = await prepare({
      ASC_KEY_ID: "RAWKEY01", ASC_ISSUER_ID: "raw-issuer", ASC_KEY_P8: keyPem,
      ...(producer ? {
        APPLE_API_KEY_ID: "CIKEY01", APPLE_API_ISSUER_ID: "ci-issuer",
        APPLE_API_KEY_P8_BASE64: Buffer.from(otherPem).toString("base64"),
        IOS_CERT_P12_BASE64: Buffer.from("fixture-certificate").toString("base64"), IOS_CERT_PASSWORD: "fixture-pass"
      } : {
        IOS_DIST_P12_BASE64: Buffer.from("fixture-certificate").toString("base64"), IOS_DIST_P12_PASSWORD: "fixture-pass"
      })
    });
    assert.equal(result.code, 0, result.stderr);
    const keyPath = join(result.temp, "ios-signing", `AuthKey_${producer ? "CIKEY01" : "RAWKEY01"}.p8`);
    assert.ok(readFileSync(keyPath, "utf8").trim() === (producer ? otherPem : keyPem).trim(),
      "private staging differs from the selected synthetic fixture");
    assert.equal(statSync(keyPath).mode & 0o777, 0o600);
    assert.equal(statSync(dirname(keyPath)).mode & 0o777, 0o700);
    assert.equal(statSync(join(result.temp, "ios-signing", "ios-distribution.p12")).mode & 0o777, 0o600);
    const exported = readFileSync(result.env.GITHUB_ENV, "utf8");
    assert.ok(exported.includes(`ASC_KEY_ID=${producer ? "CIKEY01" : "RAWKEY01"}\n`));
    assert.ok(exported.includes(`ASC_ISSUER_ID=${producer ? "ci-issuer" : "raw-issuer"}\n`));
    assert.ok(!exported.includes(keyPem.trim()) && !exported.includes(otherPem.trim()));
    assert.ok(readFileSync(result.env.FAKE_SIGNING_LOG, "utf8").includes("find-identity"));
  }
});

test("actual preparation refuses partial, mixed and invalid inputs before signing stores", async () => {
  const raw = { ASC_KEY_ID: "RAWKEY01", ASC_ISSUER_ID: "raw-issuer", ASC_KEY_P8: keyPem };
  const cert = { IOS_CERT_P12_BASE64: Buffer.from("fixture-certificate").toString("base64"), IOS_CERT_PASSWORD: "fixture-pass" };
  const cases = [
    [{}, "ASC_KEY_P8"],
    [{ ASC_KEY_ID: "RAWKEY01", APPLE_API_ISSUER_ID: "ci-issuer", ASC_KEY_P8: keyPem, ...cert }, "ASC_ISSUER_ID"],
    [{ ASC_KEY_ID: "RAWKEY01", ASC_ISSUER_ID: "raw-issuer", ASC_KEY_PATH: staged("ignored-prep.p8"), ...cert }, "ASC_KEY_P8"],
    [{ ...raw, ...cert, ASC_KEY_P8: "not a private key" }, "ASC_KEY_P8"],
    [{ ...raw, ...cert, ASC_KEY_ID: "../wrong" }, "ASC_KEY_ID"],
    [{ ...raw, IOS_CERT_P12_BASE64: cert.IOS_CERT_P12_BASE64, IOS_DIST_P12_PASSWORD: "fixture-pass" }, "IOS_CERT_PASSWORD"],
    [{ ...raw, ...cert, APPLE_API_KEY_ID: "CIKEY01", APPLE_API_ISSUER_ID: "ci-issuer", APPLE_API_KEY_P8_BASE64: "invalid" }, "APPLE_API_KEY_P8_BASE64"]
  ];
  for (const [env, expected] of cases) {
    const result = await prepare(env);
    assert.notEqual(result.code, 0);
    assert.ok(result.stderr.includes(expected), "refusal must name the supported input");
    assert.equal(existsSync(result.env.FAKE_SIGNING_LOG), false);
    assert.equal(existsSync(result.env.GITHUB_ENV), false);
    assert.equal(existsSync(join(result.temp, "ios-signing")), false);
  }
});

test("actual ship entry uses producer outputs in dry-run and refuses missing inputs before query or upload", async () => {
  const ship = join(here, "ship-testflight.sh");
  for (const [present, planOnly] of [[true, false], [false, false], [false, true]]) {
    const temp = mkdtempSync(join(root, "ship-entry-"));
    const ipa = join(temp, "fixture.ipa");
    writeFileSync(ipa, "fixture");
    const env = {
      PATH: `${prepBin}:${safePath}`, HOME: join(temp, "home"), TMPDIR: temp,
      IOS_FLEET_STATE_DIR: join(temp, "state"), IOS_FLEET_NODE: join(prepBin, "asc-query"),
      FAKE_SIGNING_LOG: join(temp, "tools.log"),
      ...(present ? {
        APPLE_API_KEY_ID: "CIKEY01", APPLE_API_ISSUER_ID: "ci-issuer",
        APPLE_API_KEY_P8_BASE64: Buffer.from(otherPem).toString("base64")
      } : {})
    };
    const result = await new Promise((resolve, reject) => {
      const child = spawn("/bin/bash", [ship, "clutch", "--repo-root", join(here, "..", ".."),
        ...(planOnly ? ["--plan-build-only"] : ["--upload-only", ipa, "--dry-run", "--allow-dirty", "--force-ship"])],
      { env, stdio: ["ignore", "pipe", "pipe"], timeout: 15_000, killSignal: "SIGKILL" });
      let stdout = "", stderr = "";
      child.stdout.on("data", chunk => { stdout += chunk; });
      child.stderr.on("data", chunk => { stderr += chunk; });
      child.on("error", reject);
      child.on("close", code => resolve({ code, stdout, stderr }));
    });
    assert.equal(result.code, present ? 0 : 1, result.stderr);
    assert.ok((result.stdout + result.stderr).includes(present ? "auth=api_key" : "ASC_KEY_P8"));
    if (present) assert.ok(result.stdout.includes("dry-run: would archive + ship; exiting"));
    assert.equal(existsSync(env.FAKE_SIGNING_LOG), false, "no query, archive or upload tool may run");
    assert.equal(readdirSync(temp).some(name => name.startsWith("asc-key.")), false);
    assert.ok(!result.stdout.includes(otherPem.trim()) && !result.stderr.includes(otherPem.trim()));
  }
});

test("actual local ship plan permits only wholly absent credentials and never invokes provider or build tools", async () => {
  const ship = join(here, "ship-testflight.sh");
  for (const [extra, expected] of [
    [{}, 0],
    [{ ASC_KEY_ID: "PARTIAL" }, 1],
    [{ ASC_KEY_PATH: staged("path-only-plan.p8") }, 1],
    [{ ASC_KEY_ID: "RAWKEY01", ASC_ISSUER_ID: "raw-issuer", ASC_KEY_P8: "not a key" }, 1],
    [{ APPLE_API_KEY_ID: "CIKEY01", APPLE_API_ISSUER_ID: "ci-issuer", APPLE_API_KEY_P8_BASE64: "invalid" }, 1]
  ]) {
    const temp = mkdtempSync(join(root, "local-plan-"));
    const env = {
      PATH: `${prepBin}:${safePath}`, HOME: join(temp, "home"), TMPDIR: temp,
      IOS_FLEET_STATE_DIR: join(temp, "state"), IOS_FLEET_NODE: join(prepBin, "asc-query"),
      FAKE_SIGNING_LOG: join(temp, "tools.log"), ...extra
    };
    const result = await new Promise((resolve, reject) => {
      const child = spawn("/bin/bash", [ship, "clutch", "--repo-root", join(here, "..", ".."),
        "--dry-run", "--allow-dirty", "--force-ship", "--version", "9.9.8", "--build", "42"],
      { env, stdio: ["ignore", "pipe", "pipe"], timeout: 15_000, killSignal: "SIGKILL" });
      let stdout = "", stderr = "";
      child.stdout.on("data", chunk => { stdout += chunk; });
      child.stderr.on("data", chunk => { stderr += chunk; });
      child.on("error", reject);
      child.on("close", code => resolve({ code, stdout, stderr }));
    });
    assert.equal(result.code, expected, result.stderr);
    assert.ok((result.stdout + result.stderr).includes("ASC_KEY_P8"));
    if (expected === 0) {
      assert.ok(result.stdout.includes("marketing=9.9.8 build=42"));
      assert.ok(result.stdout.includes("auth=none"));
      assert.ok(result.stdout.includes("dry-run: would archive + ship; exiting"));
    }
    assert.equal(existsSync(env.FAKE_SIGNING_LOG), false, "no query, archive or upload tool may run");
    assert.equal(readdirSync(temp).some(name => name.startsWith("asc-key.")), false);
  }
});

test("actual credential chmod refusal cleans its directory before a fresh successful retry", async () => {
  const source = readFileSync(join(here, "ship-testflight.sh"), "utf8");
  const start = "# --- ASC credentials begin";
  const end = "# --- ASC credentials end";
  for (const needle of [start, end]) assert.equal(source.split(needle).length, 2);
  const credentials = source.slice(source.indexOf(start), source.indexOf(end));
  const temp = mkdtempSync(join(root, "chmod-retry-"));
  const env = {
    PATH: safePath, HOME: join(temp, "home"), TMPDIR: temp, FLEET_DIR: here, REAL_NODE: process.execPath,
    ASC_KEY_ID: "RAWKEY01", ASC_ISSUER_ID: "raw-issuer", ASC_KEY_P8: keyPem,
    FAILED_DIRECTORY_FILE: join(temp, "failed-directory"), SUCCESS_DIRECTORY_FILE: join(temp, "success-directory"),
    KEY_WRITE_CALLS: join(temp, "key-writes")
  };
  const script = 'set -euo pipefail\nlog() { printf "%s\\n" "$*"; }\n' + credentials + `
chmod() {
  [[ "$1" == 700 && "$#" == 2 ]] || return 98
  if [[ ! -e "$FAILED_DIRECTORY_FILE" ]]; then
    printf '%s' "$2" > "$FAILED_DIRECTORY_FILE"
    return 1
  fi
  command chmod "$@"
}
node() {
  if [[ "$2" == write ]]; then printf '%s\\n' write >> "$KEY_WRITE_CALLS"; fi
  command "$REAL_NODE" "$@"
}
first_status=0
load_secrets || first_status=$?
[[ "$first_status" -eq 1 && "$AUTH_MODE" == none && -z "$ASC_TMP_DIR" && ! -e "$KEY_WRITE_CALLS" ]]
failed="$(<"$FAILED_DIRECTORY_FILE")"
[[ -n "$failed" && ! -e "$failed" ]]
load_secrets
[[ "$AUTH_MODE" == api_key && "$ASC_TMP_DIR" != "$failed" && -d "$ASC_TMP_DIR" ]]
[[ -f "$ASC_KEY_PATH" ]]
[[ "$(stat -c %a "$ASC_KEY_PATH" 2>/dev/null || stat -f %Lp "$ASC_KEY_PATH")" == 600 ]]
[[ "$(stat -c %a "$ASC_TMP_DIR" 2>/dev/null || stat -f %Lp "$ASC_TMP_DIR")" == 700 ]]
command "$REAL_NODE" -e 'const fs=require("fs"); process.exit(fs.readFileSync(process.argv[1],"utf8").trim()===process.env.ASC_KEY_P8.trim()?0:1)' "$ASC_KEY_PATH"
printf '%s' "$ASC_TMP_DIR" > "$SUCCESS_DIRECTORY_FILE"
`;
  const result = await new Promise((resolve, reject) => {
    const child = spawn("/bin/bash", ["-c", script], { env, stdio: ["ignore", "pipe", "pipe"], timeout: 15_000, killSignal: "SIGKILL" });
    let stdout = "", stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", code => resolve({ code, stdout, stderr }));
  });
  assert.equal(result.code, 0, result.stderr);
  const failed = readFileSync(env.FAILED_DIRECTORY_FILE, "utf8");
  const succeeded = readFileSync(env.SUCCESS_DIRECTORY_FILE, "utf8");
  assert.notEqual(failed, succeeded);
  assert.equal(existsSync(failed), false);
  assert.equal(existsSync(succeeded), false);
  assert.deepEqual(readFileSync(env.KEY_WRITE_CALLS, "utf8").trim().split("\n"), ["write"]);
  assert.equal(readdirSync(temp).some(name => name.startsWith("asc-key.")), false);
  assert.ok(!result.stdout.includes(keyPem.trim()) && !result.stderr.includes(keyPem.trim()));
});

test("actual post-archive credential refusal reaches package-ready exit three before any upload", async () => {
  const source = readFileSync(join(here, "ship-testflight.sh"), "utf8");
  const credentialStart = "# --- ASC credentials begin";
  const credentialEnd = "# --- ASC credentials end";
  const handoffStart = "# Re-load secrets before altool:";
  const handoffEnd = 'link_private_key "${ASC_KEY_PATH}" "${ASC_KEY_ID}"';
  for (const needle of [credentialStart, credentialEnd, handoffStart, handoffEnd]) {
    assert.equal(source.split(needle).length, 2, "source fixture boundary must remain unique");
  }
  const credentials = source.slice(source.indexOf(credentialStart), source.indexOf(credentialEnd));
  const handoff = source.slice(source.indexOf(handoffStart), source.indexOf(handoffEnd, source.indexOf(handoffStart)));
  for (const [extra, loseAfterStaging] of [
    [{}, false],
    [{ ASC_KEY_ID: "PARTIAL" }, false],
    [{ ASC_KEY_ID: "RAWKEY01", ASC_ISSUER_ID: "raw-issuer", ASC_KEY_P8: "not a key" }, false],
    [{ ASC_KEY_ID: "RAWKEY01", ASC_ISSUER_ID: "raw-issuer", ASC_KEY_P8: keyPem }, true]
  ]) {
    const temp = mkdtempSync(join(root, "archive-handoff-"));
    const env = {
      PATH: `${prepBin}:${safePath}`, HOME: join(temp, "home"), TMPDIR: temp,
      FLEET_DIR: here, FAKE_SIGNING_LOG: join(temp, "tools.log"), ...extra
    };
    const result = await new Promise((resolve, reject) => {
      const script = 'set -euo pipefail\nlog() { printf "%s\\n" "$*"; }\n' + credentials +
        (loseAfterStaging ? '\nload_secrets\nunset ASC_KEY_P8\n' : '') +
        '\nPACKAGE=fixture.ipa\nAPP_KEY=clutch\nBUNDLE_ID=fixture.bundle\n' + handoff + '\nexit 99\n';
      const child = spawn("/bin/bash", ["-c", script], { env, stdio: ["ignore", "pipe", "pipe"], timeout: 15_000, killSignal: "SIGKILL" });
      let stdout = "", stderr = "";
      child.stdout.on("data", chunk => { stdout += chunk; });
      child.stderr.on("data", chunk => { stderr += chunk; });
      child.on("error", reject);
      child.on("close", code => resolve({ code, stdout, stderr }));
    });
    assert.equal(result.code, 3, result.stderr);
    assert.ok(result.stdout.includes("Package ready at: fixture.ipa"));
    for (const name of ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID", "APPLE_API_KEY_P8_BASE64"]) {
      assert.ok(result.stdout.includes(name));
    }
    assert.equal(existsSync(env.FAKE_SIGNING_LOG), false, "no provider or upload tool may run");
    assert.equal(readdirSync(temp).some(name => name.startsWith("asc-key.")), false);
    assert.ok(!result.stdout.includes(keyPem.trim()) && !result.stderr.includes(keyPem.trim()));
  }
});

test("actual export-only permits absence while normal ships and staging failures refuse before archive", async () => {
  const ship = join(here, "ship-testflight.sh");
  for (const [localExport, brokenStaging] of [[true, false], [false, false], [false, true], [true, true]]) {
    const temp = mkdtempSync(join(root, "export-entry-"));
    const repo = join(temp, "repo");
    mkdirSync(join(repo, "ios", "Clutch.xcodeproj"), { recursive: true });
    writeFileSync(join(repo, "ios", "project.yml"), "DEVELOPMENT_TEAM: FIXTURETEAM\n");
    const bin = join(temp, "bin");
    mkdirSync(bin);
    writeFileSync(join(bin, "xcodebuild"), '#!/bin/bash\n[ "$1" = archive ] || exit 98\nprintf "%s\\n" archive >> "$FAKE_ARCHIVE_LOG"\nexit 99\n', { mode: 0o700 });
    const blockedTemp = join(temp, "not-a-directory");
    if (brokenStaging) writeFileSync(blockedTemp, "fixture");
    const env = {
      PATH: `${bin}:${prepBin}:${safePath}`, HOME: join(temp, "home"), TMPDIR: brokenStaging ? blockedTemp : temp,
      IOS_FLEET_STATE_DIR: join(temp, "state"), IOS_FLEET_NODE: join(prepBin, "asc-query"), IOS_MANUAL_SIGN: "0",
      FAKE_SIGNING_LOG: join(temp, "tools.log"), FAKE_ARCHIVE_LOG: join(temp, "archive.log"),
      ...(brokenStaging ? { ASC_KEY_ID: "RAWKEY01", ASC_ISSUER_ID: "raw-issuer", ASC_KEY_P8: keyPem } : {})
    };
    const result = await new Promise((resolve, reject) => {
      const child = spawn("/bin/bash", [ship, "clutch", "--repo-root", repo, "--allow-dirty", "--force-ship",
        "--skip-xcodegen", "--version", "9.9.8", "--build", "42", ...(localExport ? ["--export-only"] : [])],
      { env, stdio: ["ignore", "pipe", "pipe"], timeout: 15_000, killSignal: "SIGKILL" });
      let stdout = "", stderr = "";
      child.stdout.on("data", chunk => { stdout += chunk; });
      child.stderr.on("data", chunk => { stderr += chunk; });
      child.on("error", reject);
      child.on("close", code => resolve({ code, stdout, stderr }));
    });
    assert.equal(result.code, 1, result.stderr);
    if (brokenStaging) {
      assert.ok(result.stdout.includes("could not create a temp dir for the ASC key"));
    } else {
      for (const name of ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID", "APPLE_API_KEY_P8_BASE64"]) {
        assert.ok((result.stdout + result.stderr).includes(name));
      }
    }
    assert.equal(existsSync(env.FAKE_SIGNING_LOG), false, "no provider or upload tool may run");
    assert.equal(existsSync(env.FAKE_ARCHIVE_LOG), localExport && !brokenStaging);
    if (localExport && !brokenStaging) {
      assert.ok(result.stdout.includes("auth=none export_only=1"));
      assert.ok(result.stderr.includes("archive failed (rc=99)"));
    }
    assert.equal(readdirSync(temp).some(name => name.startsWith("asc-key.")), false);
    assert.ok(!result.stdout.includes(keyPem.trim()) && !result.stderr.includes(keyPem.trim()));
  }
});

test("malformed preferred tuple never falls back to another complete key", async () => {
  const server = await localServer();
  try {
    for (const invalid of ["invalid", Buffer.from("not a private key").toString("base64")]) {
      const result = await spawnNode([client, "GET", `${server.base}/v1/apps`], {
        PATH: safePath, HOME: join(root, "invalid-client"), ASC_API_BASE: server.base,
        ASC_KEY_ID: "RAWKEY01", ASC_ISSUER_ID: "raw-issuer", ASC_KEY_P8: keyPem,
        APPLE_API_KEY_ID: "CIKEY01", APPLE_API_ISSUER_ID: "ci-issuer", APPLE_API_KEY_P8_BASE64: invalid
      });
      assert.equal(result.code, 1);
      assert.ok(result.stderr.includes("APPLE_API_KEY_P8_BASE64"));
    }
    assert.equal(server.seen.length, 0);
  } finally { server.close(); }
});
