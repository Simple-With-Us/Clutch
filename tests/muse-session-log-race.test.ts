import { appendFileSync, mkdirSync, mkdtempSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

const fsMockState = vi.hoisted(() => ({
  beforeOpen: null as null | ((path: string) => void),
  readdirCalls: 0,
  readdirFailuresRemaining: 0,
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    readdir: vi.fn(async (...args: Parameters<typeof actual.readdir>) => {
      fsMockState.readdirCalls += 1;
      if (fsMockState.readdirFailuresRemaining > 0) {
        fsMockState.readdirFailuresRemaining -= 1;
        throw new Error("synthetic directory scan failure");
      }
      return actual.readdir(...args);
    }),
    open: vi.fn(async (...args: Parameters<typeof actual.open>) => {
      fsMockState.beforeOpen?.(String(args[0]));
      return actual.open(...args);
    }),
  };
});

import { findMuseSessionLog, readMuseSessionLog } from "../src/web/muse-session-log.ts";

const SESSION_ID = "8ec48d4a-e48d-4a49-ae87-f710d028e20c";

function event(payload_type: string, payload: Record<string, unknown>, sequence: number): string {
  return JSON.stringify({ record_type: "event", payload_type, payload, sequence });
}

afterEach(() => {
  fsMockState.beforeOpen = null;
  fsMockState.readdirCalls = 0;
  fsMockState.readdirFailuresRemaining = 0;
  vi.restoreAllMocks();
  vi.clearAllMocks();
});

function syntheticSessionId(index: number): string {
  const value = index.toString(16);
  return `${value.padStart(8, "0")}-0000-4000-8000-${value.padStart(12, "0")}`;
}

describe("Muse session location index", () => {
  it("shares concurrent misses and refreshes new sessions after its short negative cache expires", async () => {
    const root = mkdtempSync(join(tmpdir(), "clutch-muse-location-cache-"));
    const day = join(root, "2026", "11", "03");
    const foundSession = join(day, SESSION_ID);
    const newlyCreatedId = "a1111111-a111-4111-8111-a11111111111";
    const missingId = "b2222222-b222-4222-8222-b22222222222";
    const secondMissingId = "c3333333-c333-4333-8333-c33333333333";
    mkdirSync(foundSession, { recursive: true });
    writeFileSync(join(foundSession, "session.jsonl"), "{}\n");
    let clock = 1_000_000;
    vi.spyOn(Date, "now").mockImplementation(() => clock);
    fsMockState.readdirCalls = 0;

    try {
      const results = await Promise.all([
        findMuseSessionLog(SESSION_ID, root),
        findMuseSessionLog(missingId, root),
        findMuseSessionLog(secondMissingId, root),
      ]);
      expect(results).toEqual([join(foundSession, "session.jsonl"), null, null]);
      expect(fsMockState.readdirCalls).toBe(4);

      await expect(findMuseSessionLog(missingId, root)).resolves.toBeNull();
      expect(fsMockState.readdirCalls).toBe(4);

      clock += 501;
      await expect(findMuseSessionLog(SESSION_ID, root)).resolves.toBe(join(foundSession, "session.jsonl"));
      expect(fsMockState.readdirCalls).toBe(4);

      const newSession = join(day, newlyCreatedId);
      mkdirSync(newSession);
      writeFileSync(join(newSession, "session.jsonl"), "{}\n");
      await expect(findMuseSessionLog(newlyCreatedId, root)).resolves.toBe(join(newSession, "session.jsonl"));
      expect(fsMockState.readdirCalls).toBe(8);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("keeps validated paths when an expired index refresh fails, then discovers new sessions on retry", async () => {
    const root = mkdtempSync(join(tmpdir(), "clutch-muse-location-refresh-failure-"));
    const day = join(root, "2026", "11", "03");
    const knownDirectory = join(day, SESSION_ID);
    const newId = "d4444444-d444-4444-8444-d44444444444";
    const newDirectory = join(day, newId);
    mkdirSync(knownDirectory, { recursive: true });
    writeFileSync(join(knownDirectory, "session.jsonl"), "{}\n");
    let clock = 2_000_000;
    vi.spyOn(Date, "now").mockImplementation(() => clock);
    fsMockState.readdirCalls = 0;

    try {
      await expect(findMuseSessionLog(SESSION_ID, root)).resolves.toBe(join(knownDirectory, "session.jsonl"));
      expect(fsMockState.readdirCalls).toBe(4);

      clock += 501;
      mkdirSync(newDirectory);
      writeFileSync(join(newDirectory, "session.jsonl"), "{}\n");
      fsMockState.readdirFailuresRemaining = 1;

      await expect(findMuseSessionLog(newId, root)).resolves.toBeNull();
      expect(fsMockState.readdirCalls).toBe(5);

      await expect(findMuseSessionLog(SESSION_ID, root)).resolves.toBe(join(knownDirectory, "session.jsonl"));
      expect(fsMockState.readdirCalls).toBe(5);

      clock += 501;
      await expect(findMuseSessionLog(newId, root)).resolves.toBe(join(newDirectory, "session.jsonl"));
      expect(fsMockState.readdirCalls).toBe(9);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("visits recent date directories first when the location scan reaches its entry cap", async () => {
    const root = mkdtempSync(join(tmpdir(), "clutch-muse-location-cap-"));
    const olderDay = join(root, "2026", "01", "01");
    const newerDay = join(root, "2026", "01", "02");
    const recentId = "ffffffff-ffff-4fff-8fff-ffffffffffff";
    const recentDirectory = join(newerDay, recentId);
    mkdirSync(olderDay, { recursive: true });
    mkdirSync(newerDay, { recursive: true });
    mkdirSync(recentDirectory);
    writeFileSync(join(recentDirectory, "session.jsonl"), "{}\n");
    for (let index = 1; index <= 20_000; index += 1) {
      mkdirSync(join(olderDay, syntheticSessionId(index)));
    }

    try {
      await expect(findMuseSessionLog(recentId, root)).resolves.toBe(join(recentDirectory, "session.jsonl"));
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

describe("Muse session log path replacement", () => {
  it("does not cache a false empty transcript when the log grows before open", async () => {
    const root = mkdtempSync(join(tmpdir(), "clutch-muse-growth-"));
    const dir = join(root, "2026", "11", "03", SESSION_ID);
    const file = join(dir, "session.jsonl");
    mkdirSync(dir, { recursive: true });
    writeFileSync(file, event("runtime.session.metadata", { record: { provider_id: "echo" } }, 1) + "\n");
    fsMockState.beforeOpen = (path) => {
      if (path !== file) return;
      appendFileSync(file, event("runtime.session", { event: { kind: "user_prompt_display", prompt: "new synthetic row" } }, 2) + "\n");
      fsMockState.beforeOpen = null;
    };
    try {
      expect(await readMuseSessionLog(SESSION_ID, { sessionsRoot: root })).toBeNull();
      const next = await readMuseSessionLog(SESSION_ID, { sessionsRoot: root });
      expect(next?.transcript.map((row) => row.text)).toContain("new synthetic row");
      expect(next?.usage.totalsComplete).toBe(true);
    } finally {
      fsMockState.beforeOpen = null;
      rmSync(root, { recursive: true, force: true });
    }
  });

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
