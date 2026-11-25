import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  ZCODE_ACP_SERVER,
  ZCODE_STRIPPED_ENV,
  defaultZcodeAcpServer,
  resolveZcodeCli,
  zcodeAcpMode,
  zcodeAcpServerCandidates,
  zcodeCredentialPaths,
  zcodeSignedIn,
  zcodeSpawnEnv,
} from "../src/web/zcode-acp.ts";

const temps: string[] = [];

function tempDir(): string {
  // realpath, so a macOS /var -> /private/var symlink cannot make the
  // resolved CLI path differ from the one the test wrote.
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "clutch-zcode-acp-")));
  temps.push(dir);
  return dir;
}

function executable(path: string): string {
  writeFileSync(path, "#!/bin/sh\nexit 0\n");
  chmodSync(path, 0o755);
  return path;
}

function writeJson(path: string, value: unknown): void {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, typeof value === "string" ? value : JSON.stringify(value));
}

afterEach(() => {
  while (temps.length > 0) rmSync(temps.pop()!, { recursive: true, force: true });
});

describe("the zcode-acp-server launcher", () => {
  it("looks next to the sidecar's own node first", () => {
    const home = tempDir();
    const candidates = zcodeAcpServerCandidates({ HOME: home }, "/opt/node/bin");
    expect(candidates[0]).toBe(join("/opt/node/bin", ZCODE_ACP_SERVER));
    expect(candidates).toContain(join(home, ".npm-global", "bin", ZCODE_ACP_SERVER));
  });

  it("picks the first installed bridge, else the bare name for PATH", () => {
    const home = tempDir();
    const nodeBin = tempDir();
    expect(defaultZcodeAcpServer({ HOME: home }, nodeBin)).toBe(ZCODE_ACP_SERVER);

    const installed = executable(join(nodeBin, ZCODE_ACP_SERVER));
    expect(defaultZcodeAcpServer({ HOME: home }, nodeBin)).toBe(installed);
  });

  it("lets CLUTCH_ZCODE_ACP_CLI name the bridge", () => {
    const home = tempDir();
    expect(defaultZcodeAcpServer({ HOME: home, CLUTCH_ZCODE_ACP_CLI: " /srv/bridge " }, home)).toBe("/srv/bridge");
  });
});

describe("resolveZcodeCli", () => {
  it("follows a zcode symlink to the real zcode.cjs", () => {
    const root = tempDir();
    const bundle = join(root, "ZCode.app", "Contents", "Resources", "glm");
    mkdirSync(bundle, { recursive: true });
    const real = executable(join(bundle, "zcode.cjs"));
    const bin = join(root, "bin");
    mkdirSync(bin);
    symlinkSync(real, join(bin, "zcode"));

    // The bridge only hands the app-server its provider table when it sees
    // the real .cjs path, so the symlink on PATH must resolve.
    expect(resolveZcodeCli({ HOME: join(root, "home"), PATH: bin })).toBe(real);
  });

  it("prefers the explicit ZCODE_BIN and never replaces a missing one with a guess", () => {
    const root = tempDir();
    const bin = join(root, "bin");
    mkdirSync(bin);
    executable(join(bin, "zcode"));
    const explicit = executable(join(root, "chosen.cjs"));

    expect(resolveZcodeCli({ HOME: root, PATH: bin, ZCODE_BIN: explicit })).toBe(explicit);
    expect(resolveZcodeCli({ HOME: root, PATH: bin, CLUTCH_ZCODE_CLI: explicit })).toBe(explicit);
    expect(resolveZcodeCli({ HOME: root, PATH: bin, ZCODE_BIN: join(root, "missing") })).toBeNull();
  });

  it("looks an explicit bare name up on PATH, the way the bridge spawns it", () => {
    const root = tempDir();
    const bin = join(root, "bin");
    mkdirSync(bin);
    const onPath = executable(join(bin, "zcode"));

    expect(resolveZcodeCli({ HOME: root, PATH: bin, CLUTCH_ZCODE_CLI: "zcode" })).toBe(onPath);
    expect(resolveZcodeCli({ HOME: root, PATH: bin, ZCODE_BIN: "zcode-missing" })).toBeNull();
  });

  it.skipIf(process.platform === "win32")("treats a backslash as part of a bare name on POSIX, not as a path", () => {
    const root = tempDir();
    const bin = join(root, "bin");
    mkdirSync(bin);
    const onPath = executable(join(bin, "z\\code"));

    expect(resolveZcodeCli({ HOME: root, PATH: bin, ZCODE_BIN: "z\\code" })).toBe(onPath);
  });

  it("requires a non-JavaScript entry to be executable, but not a zcode.cjs the bridge runs with Node", () => {
    const root = tempDir();
    const plain = join(root, "zcode");
    writeFileSync(plain, "#!/bin/sh\nexit 0\n");
    chmodSync(plain, 0o644);
    const script = join(root, "zcode.cjs");
    writeFileSync(script, "module.exports = {};\n");
    chmodSync(script, 0o644);

    expect(resolveZcodeCli({ HOME: root, PATH: "", ZCODE_BIN: plain })).toBeNull();
    expect(resolveZcodeCli({ HOME: root, PATH: "", ZCODE_BIN: script })).toBe(script);
  });

  it("ignores a directory named zcode", () => {
    const root = tempDir();
    const bin = join(root, "bin");
    mkdirSync(join(bin, "zcode"), { recursive: true });
    expect(resolveZcodeCli({ HOME: join(root, "home"), PATH: bin, ZCODE_BIN: join(bin, "zcode") })).toBeNull();
  });
});

describe("zcodeSignedIn", () => {
  it("reads the data root from ZCODE_HOME", () => {
    const root = tempDir();
    expect(zcodeCredentialPaths({ HOME: root }).accounts).toBe(join(root, ".zcode", "v2", "acp-accounts.json"));
    expect(zcodeCredentialPaths({ HOME: root, ZCODE_HOME: "/data/zc" }).desktop).toBe(join("/data/zc", "v2", "config.json"));
  });

  it("is false with no files, empty files or files that are not JSON", () => {
    const home = tempDir();
    expect(zcodeSignedIn({ HOME: home })).toBe(false);
    const { accounts, desktop } = zcodeCredentialPaths({ HOME: home });
    writeJson(accounts, "");
    writeJson(desktop, "{not json");
    expect(zcodeSignedIn({ HOME: home })).toBe(false);
    writeJson(accounts, {});
    writeJson(desktop, { provider: "nope" });
    expect(zcodeSignedIn({ HOME: home })).toBe(false);
  });

  it("counts a saved zcode-acp setup account", () => {
    const home = tempDir();
    writeJson(zcodeCredentialPaths({ HOME: home }).accounts, { zai: { provider: "zai" } });
    expect(zcodeSignedIn({ HOME: home })).toBe(true);
  });

  it("counts a desktop provider key, and a built-in one only while it is enabled", () => {
    const home = tempDir();
    const { desktop } = zcodeCredentialPaths({ HOME: home });

    writeJson(desktop, { provider: { "builtin:zai-coding-plan": { options: { apiKey: "present" } } } });
    expect(zcodeSignedIn({ HOME: home })).toBe(false);

    writeJson(desktop, { provider: { "builtin:zai-coding-plan": { enabled: true, options: { apiKey: "present" } } } });
    expect(zcodeSignedIn({ HOME: home })).toBe(true);

    writeJson(desktop, { provider: { custom: { options: { apiKey: "present" } } } });
    expect(zcodeSignedIn({ HOME: home })).toBe(true);

    writeJson(desktop, { provider: { custom: { options: { apiKey: "  " } } } });
    expect(zcodeSignedIn({ HOME: home })).toBe(false);
  });
});

describe("zcodeAcpMode", () => {
  it("maps the sidecar's posture onto the bridge's modes", () => {
    expect(zcodeAcpMode(undefined)).toBe("yolo");
    expect(zcodeAcpMode("danger-full-access")).toBe("yolo");
    expect(zcodeAcpMode("workspace-write")).toBe("build");
  });
});

describe("zcodeSpawnEnv", () => {
  it("strips foreign keys and passes the CLI's real path and the mode", () => {
    const root = tempDir();
    const real = executable(join(root, "zcode.cjs"));
    const bin = join(root, "bin");
    mkdirSync(bin);
    symlinkSync(real, join(bin, "zcode"));
    const env: NodeJS.ProcessEnv = { HOME: join(root, "home"), PATH: bin, KEEP: "1" };
    for (const name of ZCODE_STRIPPED_ENV) env[name] = "secret";

    const out = zcodeSpawnEnv(env);
    for (const name of ZCODE_STRIPPED_ENV) expect(out[name]).toBeUndefined();
    expect(out.KEEP).toBe("1");
    expect(out.ZCODE_BIN).toBe(real);
    expect(out.ZCODE_ACP_MODE).toBe("yolo");
    // The caller's own environment is not changed.
    expect(env.ANTHROPIC_API_KEY).toBe("secret");
  });

  it("keeps a ZCODE_BIN or ZCODE_ACP_MODE the operator set", () => {
    const out = zcodeSpawnEnv({ HOME: "/nowhere", PATH: "", ZCODE_BIN: "/custom/zcode", ZCODE_ACP_MODE: "plan" });
    expect(out.ZCODE_BIN).toBe("/custom/zcode");
    expect(out.ZCODE_ACP_MODE).toBe("plan");
  });

  it("asks the engine to request permission when the sidecar does not run unrestricted", () => {
    const out = zcodeSpawnEnv({ HOME: "/nowhere", PATH: "", DSH_PERMISSION_MODE: "workspace-write" });
    expect(out.ZCODE_ACP_MODE).toBe("build");
  });
});
