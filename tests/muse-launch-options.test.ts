import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { Bridge } from "../src/web/chat-bridge.ts";
import { MuseSettingsError, museContributorModelId, museLaunchArguments } from "../src/web/muse-launch-options.ts";

function fixture(dir: string, modes = ["onRequest", "allowAll"]): string {
  const script = join(dir, "muse-acp-fixture.mjs");
  const starts = join(dir, "starts.jsonl");
  const methods = join(dir, "methods.jsonl");
  writeFileSync(script, `import readline from "node:readline";
import { appendFileSync } from "node:fs";
appendFileSync(${JSON.stringify(starts)}, JSON.stringify(process.argv.slice(2)) + "\\n");
appendFileSync(${JSON.stringify(join(dir, "environments.jsonl"))}, JSON.stringify({ requireNative: process.env.MUSE_CODE_ACP_REQUIRE_NATIVE ?? null }) + "\\n");
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const { id, method, params } = JSON.parse(line);
  appendFileSync(${JSON.stringify(methods)}, method + "\\n");
  if (method === "session/cancel") { process.exit(0); return; }
  if (method === "session/prompt" && params.sessionId === "hold") return;
  const result = method === "session/new"
    ? { sessionId: "fixture-session", modes: { currentModeId: "onRequest", availableModes: ${JSON.stringify(modes)}.map((id) => ({ id })) } }
    : method === "session/set_mode" ? {} : {};
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
});
`);
  return script;
}

function makeBridge(script: string, env: NodeJS.ProcessEnv = {}): Bridge {
  return new Bridge("muse", { ...process.env, ...env }, { command: process.execPath, args: [script] });
}

async function stopBridge(bridge: Bridge, sessionId = "fixture-session"): Promise<void> {
  const stopped = new Promise<void>((resolve) => bridge.setProcessFailureHandler(resolve));
  bridge.cancel(sessionId);
  await Promise.race([
    stopped,
    new Promise<never>((_, reject) => setTimeout(() => reject(new Error("fixture bridge did not stop")), 2_000)),
  ]);
}

describe("Muse launch options", () => {
  it("recognizes only exact contributor models in either supported ACP spelling", () => {
    for (const id of ["muse-spark-1.3-contributor", "muse-wonder-1.0-contributor", "muse-wonder-full-1.0-contributor"]) {
      expect(museContributorModelId(id)).toBe(id);
      expect(museContributorModelId(`muse-model:${JSON.stringify(["meta", "tbh", id])}`)).toBe(id);
      expect(museContributorModelId(`muse-model:${encodeURIComponent(JSON.stringify(["meta", "tbh", id]))}`)).toBe(id);
      expect(museContributorModelId(`muse-model:${JSON.stringify([null, null, id])}`)).toBe(id);
    }
    for (const value of ["muse-spark-1.3", "other-contributor", "muse-model:not-json", 'muse-model:["muse-spark-1.3-contributor"]']) {
      expect(museContributorModelId(value)).toBeNull();
    }
  });
  it("projects settings into launch flags", () => {
    expect(museLaunchArguments({ yolo: false, contributorMode: false })).toEqual(["--contributor-mode", "off"]);
    expect(museLaunchArguments({ yolo: false, contributorMode: true })).toEqual(["--contributor-mode", "on"]);
    expect(museLaunchArguments({ yolo: true, contributorMode: false })).toEqual([
      "--contributor-mode", "off", "--disable-sandbox", "--trust-workspace",
    ]);
  });

  it("uses only advertised accepted approval modes", async () => {
    const dir = mkdtempSync(join(tmpdir(), "clutch-muse-mode-"));
    const bridge = makeBridge(fixture(dir));
    try {
      await bridge.initialize();
      await bridge.newSession(dir);
      await expect(bridge.applyMuseApprovalMode("fixture-session", true)).resolves.toBeUndefined();
      await expect(bridge.applyMuseApprovalMode("fixture-session", false)).resolves.toBeUndefined();
    } finally {
      await stopBridge(bridge);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("fails closed for missing or unknown approval modes without prompting", async () => {
    const dir = mkdtempSync(join(tmpdir(), "clutch-muse-mode-"));
    const bridge = makeBridge(fixture(dir, ["onRequest", "futureMode"]));
    try {
      await expect(bridge.applyMuseApprovalMode("missing", true)).rejects.toBeInstanceOf(MuseSettingsError);
      await bridge.initialize();
      await bridge.newSession(dir);
      await expect(bridge.applyMuseApprovalMode("fixture-session", false)).resolves.toBeUndefined();
      await expect(bridge.applyMuseApprovalMode("fixture-session", true)).rejects.toBeInstanceOf(MuseSettingsError);
      expect(readFileSync(join(dir, "methods.jsonl"), "utf8")).not.toContain("session/prompt");
      const unavailable = makeBridge(join(dir, "missing-fixture.mjs"));
      await expect(unavailable.applyMuseApprovalMode("no-modes", false)).rejects.toBeInstanceOf(MuseSettingsError);
    } finally {
      await stopBridge(bridge);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("replaces an idle process before applying changed launch options", async () => {
    const dir = mkdtempSync(join(tmpdir(), "clutch-muse-restart-"));
    const starts = join(dir, "starts.jsonl");
    const bridge = makeBridge(fixture(dir));
    try {
      await bridge.initialize();
      await bridge.newSession(dir);
      await expect(bridge.configureMuseLaunch({ yolo: true, contributorMode: true })).resolves.toBe(true);
      await bridge.initialize();
      expect(readFileSync(starts, "utf8").trim().split("\n").map((line) => JSON.parse(line))).toEqual([
        [], ["--contributor-mode", "on", "--disable-sandbox", "--trust-workspace"],
      ]);
    } finally {
      await stopBridge(bridge);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("refuses reconfiguration while an RPC is pending", async () => {
    const dir = mkdtempSync(join(tmpdir(), "clutch-muse-busy-"));
    const bridge = makeBridge(fixture(dir));
    try {
      await bridge.initialize();
      const pending = bridge.prompt("hold", "wait", [], dir);
      await new Promise((resolve) => setTimeout(resolve, 30));
      await expect(bridge.configureMuseLaunch({ yolo: true, contributorMode: false })).rejects.toMatchObject({ message: expect.stringContaining("Finish other Muse turns") });
      bridge.cancel("hold");
      await expect(pending).rejects.toBeDefined();
    } finally {
      await stopBridge(bridge);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("restores the original launcher and environment for a later legacy turn", async () => {
    const dir = mkdtempSync(join(tmpdir(), "clutch-muse-reset-"));
    const env = { ...process.env };
    delete env.MUSE_CODE_ACP_REQUIRE_NATIVE;
    const bridge = new Bridge("muse", env, { command: process.execPath, args: [fixture(dir)] });
    try {
      await bridge.configureMuseLaunch({ yolo: true, contributorMode: true });
      await bridge.initialize();
      await bridge.newSession(dir);
      await bridge.configureMuseLaunch(null);
      await bridge.initialize();
      expect(bridge.matchesMuseLaunchOptions(null)).toBe(true);
      expect(readFileSync(join(dir, "starts.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line))).toEqual([
        ["--contributor-mode", "on", "--disable-sandbox", "--trust-workspace"], [],
      ]);
      expect(readFileSync(join(dir, "environments.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line))).toEqual([
        { requireNative: "1" }, { requireNative: null },
      ]);
      await bridge.newSession(dir);
      await bridge.applyMuseApprovalMode("fixture-session", false);
    } finally {
      await stopBridge(bridge);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rejects launch reconfiguration when the selected backend is an adapter", async () => {
    const dir = mkdtempSync(join(tmpdir(), "clutch-muse-native-"));
    const bridge = makeBridge(fixture(dir), { MUSE_CODE_ACP_BACKEND: "adapter" });
    try {
      await expect(bridge.configureMuseLaunch({ yolo: true, contributorMode: false })).rejects.toMatchObject({
        message: expect.stringContaining("require native Muse ACP"),
      });
      expect(existsSync(join(dir, "starts.jsonl"))).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
