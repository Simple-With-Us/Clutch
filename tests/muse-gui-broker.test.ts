import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

const ROOT = process.cwd();
const BROKER = join(ROOT, "bridges", "muse", "gui-acp.py");
const FIXTURE = join(ROOT, "tests", "fixtures", "muse-gui-broker-fixture.py");
const scratchDirs: string[] = [];

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), "clutch-muse-gui-test-"));
  scratchDirs.push(dir);
  return dir;
}

afterEach(() => {
  while (scratchDirs.length > 0) rmSync(scratchDirs.pop()!, { recursive: true, force: true });
});

interface FixtureProcess {
  child: ChildProcessWithoutNullStreams;
  result: Promise<{ code: number | null; stdout: Buffer; stderr: string }>;
  write(payload: Buffer): Promise<void>;
  end(): void;
}

function startFixture(directory: string, name: string, scenario = "echo"): FixtureProcess {
  const recordPath = join(directory, `${name}.json`);
  const child = spawn("python3", ["-S", FIXTURE, "--driver", BROKER, recordPath, scenario], { stdio: ["pipe", "pipe", "pipe"] });
  const output: Buffer[] = [];
  let stderr = "";
  child.stdout.on("data", (chunk: Buffer) => output.push(Buffer.from(chunk)));
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk: string) => { stderr += chunk; });
  const result = new Promise<{ code: number | null; stdout: Buffer; stderr: string }>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code) => resolve({ code, stdout: Buffer.concat(output), stderr }));
  });
  return {
    child,
    result,
    async write(payload) {
      if (!child.stdin.write(payload)) await once(child.stdin, "drain");
    },
    end() { child.stdin.end(); },
  };
}

async function feedFragmented(process: FixtureProcess, payload: Buffer): Promise<void> {
  const sizes = [1, 7, 16_381, 65_536, 113];
  let offset = 0;
  let index = 0;
  while (offset < payload.length) {
    const end = Math.min(payload.length, offset + sizes[index % sizes.length]!);
    await process.write(payload.subarray(offset, end));
    offset = end;
    index += 1;
  }
  process.end();
}

function pattern(length: number, seed: number): Buffer {
  const value = Buffer.allocUnsafe(length);
  for (let index = 0; index < length; index += 1) value[index] = (index * 31 + seed) % 256;
  return value;
}

describe("Muse GUI ACP broker", () => {
  it("relays fragmented and large raw byte streams with private per-launch sockets", async () => {
    const directory = scratch();
    const firstPayload = pattern(740_123, 9);
    const secondPayload = pattern(220_017, 71);
    const first = startFixture(directory, "first");
    const second = startFixture(directory, "second");

    await Promise.all([feedFragmented(first, firstPayload), feedFragmented(second, secondPayload)]);
    const [firstResult, secondResult] = await Promise.all([first.result, second.result]);
    expect(firstResult).toMatchObject({ code: 0, stderr: "" });
    expect(secondResult).toMatchObject({ code: 0, stderr: "" });
    expect(firstResult.stdout).toEqual(firstPayload);
    expect(secondResult.stdout).toEqual(secondPayload);

    const firstMetadata = JSON.parse(readFileSync(join(directory, "first.json"), "utf8")) as Record<string, unknown>;
    const secondMetadata = JSON.parse(readFileSync(join(directory, "second.json"), "utf8")) as Record<string, unknown>;
    expect(firstMetadata.directoryMode).toBe(0o700);
    expect(firstMetadata.socketMode).toBe(0o600);
    expect(secondMetadata.directoryMode).toBe(0o700);
    expect(secondMetadata.socketMode).toBe(0o600);
    expect(firstMetadata.brokerDirectory).not.toBe(secondMetadata.brokerDirectory);
    expect(firstMetadata.brokerDirectoryRemoved).toBe(true);
    expect(secondMetadata.brokerDirectoryRemoved).toBe(true);
    expect(firstMetadata.helperTerminatedBySignal).toBe(false);
    expect(secondMetadata.helperTerminatedBySignal).toBe(false);
    const firstConfig = firstMetadata.config as Record<string, unknown>;
    expect(Object.keys(firstConfig).sort()).toEqual(["arguments", "cwd", "executable", "path", "version"]);
    expect(firstConfig).toMatchObject({ version: 1, arguments: ["--fixture-argument"] });
    expect(isAbsolute(String(firstConfig.executable))).toBe(true);
    expect(firstConfig.cwd).toBe(firstMetadata.brokerDirectory);
  }, 30_000);

  it("runs the CLI with no extra ACP arguments and relays through the real socket", async () => {
    const directory = scratch();
    const payload = pattern(180_321, 43);
    const fixture = startFixture(directory, "cli-no-args", "cli-no-args");
    await feedFragmented(fixture, payload);
    const result = await fixture.result;

    expect(result).toMatchObject({ code: 0, stderr: "" });
    expect(result.stdout).toEqual(payload);
    const metadata = JSON.parse(readFileSync(join(directory, "cli-no-args.json"), "utf8")) as Record<string, unknown>;
    const config = metadata.config as Record<string, unknown>;
    expect(config.arguments).toEqual([]);
    expect(metadata.brokerDirectoryRemoved).toBe(true);
    expect(metadata.fakeMuseStarted).toBe(true);
    expect(metadata.helperTerminatedBySignal).toBe(false);
  }, 30_000);

  it("cleans the invocation socket after a bounded helper startup failure", async () => {
    const directory = scratch();
    const fixture = startFixture(directory, "failure", "startup-failure");
    fixture.end();
    const result = await fixture.result;

    expect(result).toMatchObject({ code: 1, stdout: Buffer.alloc(0), stderr: "muse-gui-acp: spawn\n" });
    const metadata = JSON.parse(readFileSync(join(directory, "failure.json"), "utf8")) as Record<string, unknown>;
    expect(metadata.directoryMode).toBe(0o700);
    expect(metadata.socketMode).toBe(0o600);
    expect(metadata.brokerDirectoryRemoved).toBe(true);
  });

  it("rejects an ACK that names the helper instead of its Muse child", async () => {
    const directory = scratch();
    const fixture = startFixture(directory, "bad-ack", "bad-ack");
    fixture.end();
    const result = await fixture.result;

    expect(result).toMatchObject({ code: 1, stdout: Buffer.alloc(0), stderr: "muse-gui-acp: invalid-ack\n" });
    const metadata = JSON.parse(readFileSync(join(directory, "bad-ack.json"), "utf8")) as Record<string, unknown>;
    expect(metadata.brokerDirectoryRemoved).toBe(true);
    expect(metadata.fallbackSignalObserved).toBe(false);
  });

  it("terminates only the verified Muse group after helper loss", async () => {
    const directory = scratch();
    const fixture = startFixture(directory, "helper-loss", "helper-loss");
    fixture.end();
    const result = await fixture.result;

    expect(result).toMatchObject({ code: 0, stderr: "" });
    const metadata = JSON.parse(readFileSync(join(directory, "helper-loss.json"), "utf8")) as Record<string, unknown>;
    expect(metadata.musePid).toBeTypeOf("number");
    expect(metadata.musePgid).toBe(metadata.musePid);
    expect(metadata.fakeMuseStarted).toBe(true);
    expect(metadata.fallbackSignalObserved).toBe(true);
    expect(metadata.brokerDirectoryRemoved).toBe(true);
    expect(metadata.helperTerminatedBySignal).toBe(false);
  }, 30_000);

  it("reaps a normally exiting helper without sending it a signal", async () => {
    const directory = scratch();
    const fixture = startFixture(directory, "normal-helper", "normal-helper");
    await feedFragmented(fixture, pattern(12_345, 61));
    const result = await fixture.result;

    expect(result).toMatchObject({ code: 0, stderr: "" });
    const metadata = JSON.parse(readFileSync(join(directory, "normal-helper.json"), "utf8")) as Record<string, unknown>;
    expect(metadata.helperTerminatedBySignal).toBe(false);
    expect(metadata.helperIdentity).toMatchObject({ pid: metadata.helperPid });
  }, 30_000);

  it("signals only the verified helper process when it hangs after disconnect", async () => {
    const directory = scratch();
    const fixture = startFixture(directory, "hung-helper", "helper-hung");
    fixture.end();
    const result = await fixture.result;

    expect(result).toMatchObject({ code: 0, stderr: "" });
    const metadata = JSON.parse(readFileSync(join(directory, "hung-helper.json"), "utf8")) as Record<string, unknown>;
    const identity = metadata.helperIdentity as Record<string, unknown>;
    expect(identity).toMatchObject({ pid: metadata.helperPid });
    expect(identity.uid).toBeTypeOf("number");
    expect(identity.birth).toBeTypeOf("string");
    expect(metadata.helperTerminatedBySignal).toBe(true);
    expect(metadata.fallbackSignalObserved).toBe(true);
    expect(metadata.brokerDirectoryRemoved).toBe(true);
  }, 30_000);

  it.each([
    ["bundle-valid", true, 1],
    ["bundle-renamed", true, 1],
    ["bundle-bad-id", false, 0],
    ["bundle-bad-executable", false, 0],
    ["bundle-wrong-owner", false, 0],
    ["bundle-writable", false, 0],
    ["bundle-bad-signature", false, 1],
  ])("validates helper bundle integrity for %s", async (scenario, valid, integrityChecks) => {
    const directory = scratch();
    const fixture = startFixture(directory, String(scenario), String(scenario));
    fixture.end();
    const result = await fixture.result;
    expect(result).toMatchObject({ code: 0, stderr: "" });
    const metadata = JSON.parse(readFileSync(join(directory, `${scenario}.json`), "utf8")) as Record<string, unknown>;
    expect(metadata.valid).toBe(valid);
    expect(metadata.integrityChecks).toBe(integrityChecks);
    if (valid) expect(metadata.integrityOuterApp).toBe(true);
    else expect(metadata.stage).toBe("launch-failed");
  });

  it("passes only the explicit benign environment allowlist to LaunchServices", async () => {
    const directory = scratch();
    const fixture = startFixture(directory, "open-environment", "open-environment");
    fixture.end();
    const result = await fixture.result;
    expect(result).toMatchObject({ code: 0, stderr: "" });
    const metadata = JSON.parse(readFileSync(join(directory, "open-environment.json"), "utf8")) as Record<string, unknown>;
    expect(metadata.keys).toEqual(["HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH", "TMPDIR", "USER"]);
    expect(metadata.containsForbidden).toBe(false);
  });

  it("runs the fixed bounded codesign integrity check without exposing output", async () => {
    const directory = scratch();
    const fixture = startFixture(directory, "codesign-command", "codesign-command");
    fixture.end();
    const result = await fixture.result;
    expect(result).toMatchObject({ code: 0, stderr: "" });
    const metadata = JSON.parse(readFileSync(join(directory, "codesign-command.json"), "utf8")) as Record<string, unknown>;
    expect(metadata).toMatchObject({
      verified: true,
      fixedCommand: true,
      bounded: true,
      captured: { stdout: true, stderr: true },
    });
  });
});
