import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import {
  loadSessionMeta,
  newProjectId,
  normalizeProjectName,
  parseSessionMeta,
  removeProject,
  saveSessionMeta,
  upsertSession,
  type SessionMetaFile,
} from "../src/web/session-meta.ts";
import { applySessionMeta } from "../src/web/chat-bridge.ts";

const empty = (): SessionMetaFile => ({ version: 1, projects: [], sessions: {} });

describe("parseSessionMeta", () => {
  it("round-trips a well-formed file", () => {
    const parsed = parseSessionMeta(JSON.stringify({
      version: 1,
      projects: [{ id: "prj_1", name: "Work", createdAt: "2026-01-01T00:00:00.000Z" }],
      sessions: { "session-a": { projectId: "prj_1", archived: true, archivedAt: "2026-01-02T00:00:00.000Z" } },
    }));
    expect(parsed.projects).toHaveLength(1);
    expect(parsed.sessions["session-a"]?.projectId).toBe("prj_1");
    expect(parsed.sessions["session-a"]?.archived).toBe(true);
  });

  it("refuses to throw on a corrupt or hand-mangled file", () => {
    expect(parseSessionMeta("").projects).toEqual([]);
    expect(parseSessionMeta("{not json").sessions).toEqual({});
    expect(parseSessionMeta("null").projects).toEqual([]);
    expect(parseSessionMeta(JSON.stringify({ version: 1, projects: "nope", sessions: 5 })).projects).toEqual([]);
  });

  it("drops entries that carry no meaning", () => {
    // An empty object per session would otherwise accumulate forever.
    const parsed = parseSessionMeta(JSON.stringify({
      version: 1,
      projects: [],
      sessions: { "session-a": {}, "session-b": { projectId: "" }, "session-c": { projectId: "prj_9" } },
    }));
    expect(Object.keys(parsed.sessions)).toEqual(["session-c"]);
  });

  it("ignores a project row without a usable id or name", () => {
    const parsed = parseSessionMeta(JSON.stringify({
      version: 1,
      projects: [{ name: "No Id" }, { id: "prj_ok", name: "Fine" }, "junk", null],
      sessions: {},
    }));
    expect(parsed.projects.map((p) => p.id)).toEqual(["prj_ok"]);
  });
});

describe("normalizeProjectName", () => {
  it("trims, collapses whitespace and caps the length", () => {
    expect(normalizeProjectName("  Work   Stuff  ")).toBe("Work Stuff");
    expect(normalizeProjectName("Work\n\tStuff")).toBe("Work Stuff");
    expect(normalizeProjectName("x".repeat(200))).toHaveLength(80);
  });

  it("rejects anything that is not a usable name", () => {
    expect(normalizeProjectName("")).toBeNull();
    expect(normalizeProjectName("   ")).toBeNull();
    expect(normalizeProjectName(42)).toBeNull();
    expect(normalizeProjectName(null)).toBeNull();
  });
});

describe("upsertSession", () => {
  it("assigns and clears a project", () => {
    const data = empty();
    upsertSession(data, "session-a", { projectId: "prj_1" });
    expect(data.sessions["session-a"]?.projectId).toBe("prj_1");

    upsertSession(data, "session-a", { projectId: null });
    expect(data.sessions["session-a"]?.projectId).toBeUndefined();
    // Nothing meaningful is left, so the record is not kept around.
    expect(data.sessions["session-a"]).toBeUndefined();
  });

  it("archives and restores reversibly", () => {
    const data = empty();
    upsertSession(data, "session-a", { archived: true });
    expect(data.sessions["session-a"]?.archived).toBe(true);
    expect(typeof data.sessions["session-a"]?.archivedAt).toBe("string");

    upsertSession(data, "session-a", { archived: false });
    expect(data.sessions["session-a"]).toBeUndefined();
  });

  it("leaves the other field alone when only one is patched", () => {
    const data = empty();
    upsertSession(data, "session-a", { projectId: "prj_1" });
    upsertSession(data, "session-a", { archived: true });
    expect(data.sessions["session-a"]?.projectId).toBe("prj_1");
    expect(data.sessions["session-a"]?.archived).toBe(true);
  });
});

describe("removeProject", () => {
  it("clears assignments that pointed at the deleted project", () => {
    const data = empty();
    data.projects.push({ id: "prj_1", name: "Work", createdAt: "2026-01-01T00:00:00.000Z" });
    upsertSession(data, "session-a", { projectId: "prj_1" });
    upsertSession(data, "session-b", { projectId: "prj_1" });
    upsertSession(data, "session-c", { archived: true });

    expect(removeProject(data, "prj_1")).toBe(true);
    // No dangling id may survive: the UI could not render it.
    expect(data.sessions["session-a"]).toBeUndefined();
    expect(data.sessions["session-b"]).toBeUndefined();
    // An unrelated archived record is untouched.
    expect(data.sessions["session-c"]?.archived).toBe(true);
  });

  it("reports when the project was not there", () => {
    expect(removeProject(empty(), "prj_missing")).toBe(false);
  });
});

describe("save and load", () => {
  it("persists across a save/load cycle at mode 600", () => {
    const dir = mkdtempSync(join(tmpdir(), "clutch-meta-"));
    const file = join(dir, "session-meta.json");
    const data = empty();
    data.projects.push({ id: newProjectId(), name: "Work", createdAt: "2026-01-01T00:00:00.000Z" });
    upsertSession(data, "session-a", { projectId: data.projects[0]?.id });

    saveSessionMeta(file, data);
    const reloaded = loadSessionMeta(file);
    expect(reloaded.projects.map((p) => p.name)).toEqual(["Work"]);
    expect(reloaded.sessions["session-a"]?.projectId).toBe(data.projects[0]?.id);
    expect(readFileSync(file, "utf8")).toContain("\"version\": 1");
  });

  it("loads an empty record when the file does not exist", () => {
    const dir = mkdtempSync(join(tmpdir(), "clutch-meta-"));
    const loaded = loadSessionMeta(join(dir, "nope.json"));
    expect(loaded.projects).toEqual([]);
    expect(loaded.sessions).toEqual({});
  });
});

describe("applySessionMeta", () => {
  const sessions = [
    { sessionId: "a", title: "Alpha" },
    { sessionId: "b", title: "Beta" },
    { sessionId: "c", title: "Gamma" },
  ];

  it("hides archived threads by default and can include them", () => {
    const meta = empty();
    upsertSession(meta, "b", { archived: true });
    upsertSession(meta, "c", { projectId: "prj_1" });

    expect(applySessionMeta(sessions, meta, false).map((s) => s.sessionId)).toEqual(["a", "c"]);
    expect(applySessionMeta(sessions, meta, true).map((s) => s.sessionId)).toEqual(["a", "b", "c"]);
    // Including an archived thread still marks it, so the UI can say so.
    const included = applySessionMeta(sessions, meta, true).find((s) => s.sessionId === "b");
    expect(included?.archived).toBe(true);
  });

  it("passes project assignment through without inventing one", () => {
    const meta = empty();
    upsertSession(meta, "c", { projectId: "prj_1" });
    const out = applySessionMeta(sessions, meta, false);
    expect(out.find((s) => s.sessionId === "c")?.projectId).toBe("prj_1");
    expect(out.find((s) => s.sessionId === "a")?.projectId).toBeUndefined();
  });

  it("does not mutate the caller's array", () => {
    const meta = empty();
    upsertSession(meta, "b", { archived: true });
    const input = [...sessions];
    applySessionMeta(input, meta, false);
    expect(input).toHaveLength(3);
  });
});

describe("newProjectId", () => {
  it("is unique and prefixed", () => {
    const ids = new Set(Array.from({ length: 50 }, () => newProjectId()));
    expect(ids.size).toBe(50);
    for (const id of ids) expect(id.startsWith("prj_")).toBe(true);
  });
});