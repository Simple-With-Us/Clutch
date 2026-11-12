import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { Bridge } from "../src/web/chat-bridge.ts";

const POLICY = { autoCompact: true, thresholdPercent: 80 };

function fixture(dir: string): string {
  const script = join(dir, "context-acp-fixture.mjs");
  writeFileSync(script, `import readline from "node:readline";
import { basename } from "node:path";
const send = (value) => process.stdout.write(JSON.stringify(value) + "\\n");
const notify = (sessionId, update) => send({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update } });
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const { id, method, params } = JSON.parse(line);
  if (method === "session/cancel") { send({ jsonrpc: "2.0", id, result: {} }); process.exit(0); return; }
  if (method === "session/new") {
    send({ jsonrpc: "2.0", id, result: { sessionId: basename(params.cwd), configOptions: [{ id: "model", currentValue: "muse-spark-1.3" }] } });
    return;
  }
  if (method === "session/prompt") {
    const text = Array.isArray(params.prompt) ? params.prompt.find((part) => part.type === "text")?.text : params.prompt;
    const usage = (used, size = 100) => notify(params.sessionId, { sessionUpdate: "usage_update", used, size });
    if (text === "bad-usage") usage("90", 100);
    if (text === "usage-45") usage(45);
    if (text === "usage-79") usage(79);
    if (text === "usage-80") usage(80);
    if (text === "usage-81") usage(81);
    if (text === "usage-85") usage(85);
    if (text === "advertise-compact") notify(params.sessionId, { sessionUpdate: "available_commands_update", availableCommands: [{ name: "plan" }, { name: "compact" }] });
    if (text === "restart-child") process.exit(0);
    send({ jsonrpc: "2.0", id, result: { stopReason: "endTurn" } });
    return;
  }
  if (method === "session/set_config_option") {
    send({ jsonrpc: "2.0", id, result: { configOptions: [{ id: "model", currentValue: params.value }] } });
    return;
  }
  send({ jsonrpc: "2.0", id, result: {} });
});
`);
  return script;
}

function makeBridge(script: string): Bridge {
  return new Bridge("muse", { ...process.env }, { command: process.execPath, args: [script] });
}

async function fixtureBridge(): Promise<{ dir: string; bridge: Bridge }> {
  const dir = mkdtempSync(join(tmpdir(), "clutch-muse-context-"));
  return { dir, bridge: makeBridge(fixture(dir)) };
}

async function stopBridge(bridge: Bridge, sessionId = "a"): Promise<void> {
  const stopped = new Promise<void>((resolve) => bridge.setProcessFailureHandler(resolve));
  bridge.cancel(sessionId);
  await Promise.race([
    stopped,
    new Promise<never>((_, reject) => setTimeout(() => reject(new Error("fixture bridge did not stop")), 2_000)),
  ]);
}

async function prompt(bridge: Bridge, sessionId: string, text: string): Promise<void> {
  await bridge.prompt(sessionId, text, [], `/workspace/${sessionId}`);
}

describe("Muse Bridge context state", () => {
  it("binds validated usage and compact advertisements to the session that sent them", async () => {
    const { dir, bridge } = await fixtureBridge();
    try {
      await bridge.initialize();
      await bridge.newSession("/workspace/a");
      await bridge.newSession("/workspace/b");

      await prompt(bridge, "a", "bad-usage");
      expect(bridge.contextControls("a")).toEqual({ supportsCompaction: false });
      await prompt(bridge, "a", "usage-79");
      await prompt(bridge, "b", "usage-45");
      expect(bridge.contextControls("a")).toEqual({ supportsCompaction: false, contextUsedTokens: 79, contextWindow: 100 });
      expect(bridge.contextControls("b")).toEqual({ supportsCompaction: false, contextUsedTokens: 45, contextWindow: 100 });
      expect(bridge.takeEarlyCompaction("a", POLICY)).toBe(false);
      expect(bridge.takeEarlyCompaction("b", POLICY)).toBe(false);

      await prompt(bridge, "a", "advertise-compact");
      expect(bridge.contextControls("a").supportsCompaction).toBe(true);
      expect(bridge.contextControls("b").supportsCompaction).toBe(false);
      expect(bridge.takeEarlyCompaction("a", POLICY)).toBe(false);
      await prompt(bridge, "a", "usage-80");
      expect(bridge.takeEarlyCompaction("a", POLICY)).toBe(true);
    } finally {
      await stopBridge(bridge);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("latches once per revision, ignores identical updates, and rearms on changed usage", async () => {
    const { dir, bridge } = await fixtureBridge();
    try {
      await bridge.initialize();
      await bridge.newSession("/workspace/a");
      await prompt(bridge, "a", "usage-80");
      expect(bridge.takeEarlyCompaction("a", POLICY)).toBe(false);
      await prompt(bridge, "a", "advertise-compact");
      expect(bridge.takeEarlyCompaction("a", POLICY)).toBe(true);
      expect(bridge.takeEarlyCompaction("a", POLICY)).toBe(false);

      await prompt(bridge, "a", "usage-80");
      expect(bridge.takeEarlyCompaction("a", POLICY)).toBe(false);
      await prompt(bridge, "a", "usage-81");
      expect(bridge.takeEarlyCompaction("a", POLICY)).toBe(true);
    } finally {
      await stopBridge(bridge);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("invalidates occupancy on an acknowledged model change", async () => {
    const { dir, bridge } = await fixtureBridge();
    try {
      await bridge.initialize();
      await bridge.newSession("/workspace/a");
      await prompt(bridge, "a", "usage-85");
      await prompt(bridge, "a", "advertise-compact");
      expect(bridge.takeEarlyCompaction("a", POLICY)).toBe(true);

      await expect(bridge.setConfigOption("a", "model", "muse-wonder-1.0")).resolves.toBe(true);
      expect(bridge.contextControls("a")).toEqual({ supportsCompaction: true });
      await prompt(bridge, "a", "usage-85");
      expect(bridge.takeEarlyCompaction("a", POLICY)).toBe(true);
    } finally {
      await stopBridge(bridge);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("clears usage and compaction state when its child process restarts", async () => {
    const { dir, bridge } = await fixtureBridge();
    try {
      await bridge.initialize();
      await bridge.newSession("/workspace/a");
      await prompt(bridge, "a", "usage-85");
      await prompt(bridge, "a", "advertise-compact");
      expect(bridge.contextControls("a")).toMatchObject({ supportsCompaction: true, contextUsedTokens: 85 });

      const failed = new Promise<void>((resolve) => bridge.setProcessFailureHandler(resolve));
      await expect(prompt(bridge, "a", "restart-child")).rejects.toBeDefined();
      await Promise.race([
        failed,
        new Promise<never>((_, reject) => setTimeout(() => reject(new Error("fixture process did not reset")), 2_000)),
      ]);
      expect(bridge.contextControls("a")).toEqual({ supportsCompaction: false });
      expect(bridge.takeEarlyCompaction("a", POLICY)).toBe(false);
      await bridge.initialize();
      await bridge.newSession("/workspace/a");
      expect(bridge.contextControls("a")).toEqual({ supportsCompaction: false });
    } finally {
      await stopBridge(bridge);
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
