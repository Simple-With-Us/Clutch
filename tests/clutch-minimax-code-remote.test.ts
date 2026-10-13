import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(join(ROOT, "src/web/dock-app/ClutchWindow.swift"), "utf8");

describe("macOS MiniMax Code Remote menu", () => {
  it("opens the authenticated direct-ACP sidecar instead of the retired companion port", () => {
    expect(source).toContain('withTitle: "MiniMax Code Remote"');
    expect(source).toContain('parts.path = "/minimax-code/"');
    expect(source).toContain('appendingPathComponent("chat-token")');
    expect(source).toContain("await ensureMiniMaxRemote()");
    expect(source).toContain('apps/clutch-runtime/scripts/chat-bridge.sh');
    expect(source).not.toContain("7842");
  });

  it("keeps local and custom Clutch hosts separate from MiniMax Code mode", () => {
    expect(source).toContain('miniMaxRemoteModeKey = "codes.clutch.minimax_code_remote"');
    expect(source).toMatch(/connectLocalClutch[\s\S]*removeObject\(forKey: miniMaxRemoteModeKey\)/);
    expect(source).toMatch(/connectCustomHost[\s\S]*removeObject\(forKey: miniMaxRemoteModeKey\)/);
  });
});
