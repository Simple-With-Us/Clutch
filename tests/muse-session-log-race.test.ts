import { mkdirSync, mkdtempSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

const fsMockState = vi.hoisted(() => ({
  beforeOpen: null as null | ((path: string) => void),
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    open: vi.fn(async (...args: Parameters<typeof actual.open>) => {
      fsMockState.beforeOpen?.(String(args[0]));
      return actual.open(...args);
    }),
  };
});

import { readMuseSessionLog } from "../src/web/muse-session-log.ts";

const SESSION_ID = "8ec48d4a-e48d-4a49-ae87-f710d028e20c";

function event(payload_type: string, payload: Record<string, unknown>, sequence: number): string {
  return JSON.stringify({ record_type: "event", payload_type, payload, sequence });
}

afterEach(() => {
  fsMockState.beforeOpen = null;
  vi.clearAllMocks();
});

describe("Muse session log path replacement", () => {
  it("rejects a checked file when its date directory becomes a symlink before open", async () => {
    const root = mkdtempSync(join(tmpdir(), "clutch-muse-race-root-"));
    const outsideRoot = mkdtempSync(join(tmpdir(), "clutch-muse-race-outside-"));
    const dayDir = join(root, "2026", "10", "21");
    const savedDayDir = `${dayDir}.checked`;
    const outsideDayDir = join(outsideRoot, "2026", "10", "21");
    const file = join(dayDir, SESSION_ID, "session.jsonl");
    const outsideFile = join(outsideDayDir, SESSION_ID, "session.jsonl");
    mkdirSync(join(dayDir, SESSION_ID), { recursive: true });
    mkdirSync(join(outsideDayDir, SESSION_ID), { recursive: true });
    writeFileSync(file, [
      event("runtime.session.metadata", { record: { workspace_root: "/inside/synthetic" } }, 1),
      event("runtime.session", { event: { kind: "user_prompt_display", prompt: "inside synthetic row" } }, 2),
    ].join("\n"));
    writeFileSync(outsideFile, [
      event("runtime.session.metadata", { record: { workspace_root: "/outside/fixture" } }, 1),
      event("runtime.session", { event: { kind: "user_prompt_display", prompt: "outside synthetic row" } }, 2),
    ].join("\n"));

    let swapped = false;
    fsMockState.beforeOpen = (path) => {
      if (path !== file || swapped) return;
      renameSync(dayDir, savedDayDir);
      symlinkSync(outsideDayDir, dayDir, "dir");
      swapped = true;
    };

    try {
      const result = await readMuseSessionLog(SESSION_ID, { sessionsRoot: root });
      expect(swapped).toBe(true);
      expect(result).toBeNull();
      expect(result?.workspaceRoot).not.toBe("/outside/fixture");
      expect(result?.transcript.map((row) => row.text) ?? []).not.toContain("outside synthetic row");
    } finally {
      fsMockState.beforeOpen = null;
      rmSync(dayDir, { recursive: true, force: true });
      renameSync(savedDayDir, dayDir);
      rmSync(root, { recursive: true, force: true });
      rmSync(outsideRoot, { recursive: true, force: true });
    }
  });
});
