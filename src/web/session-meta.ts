/**
 * Durable, sidecar-owned metadata for engine sessions:  which Project a thread
 * belongs to, and whether it is archived.
 *
 * The engine knows nothing about either concept, so this is Clutch's own record
 * and it lives beside the sidecar's other state in `$CLUTCH_HOME`.  It is
 * keyed by the engine session id, so archiving a thread never moves or renames
 * anything the engine owns and unarchiving restores it exactly.
 *
 * Writes go through a temp file and a rename so a crash mid-write leaves the
 * previous good copy rather than a truncated one.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

export interface ClutchProject {
  id: string;
  name: string;
  createdAt: string;
}

export interface SessionMetaEntry {
  /** Project this session belongs to, or absent when unassigned. */
  projectId?: string;
  /** True when the user archived it.  Archiving is reversible. */
  archived?: boolean;
  archivedAt?: string;
}

export interface SessionMetaFile {
  version: 1;
  projects: ClutchProject[];
  sessions: Record<string, SessionMetaEntry>;
}

const EMPTY: SessionMetaFile = { version: 1, projects: [], sessions: {} };

export function sessionMetaPath(clutchHome: string): string {
  return join(clutchHome, "session-meta.json");
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((v) => typeof v === "string");
}

/** Parse defensively:  a hand-edited or truncated file must not take the
 *  sidecar down, so anything unusable falls back to an empty record. */
export function parseSessionMeta(raw: string): SessionMetaFile {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ...EMPTY, projects: [], sessions: {} };
  }
  if (typeof parsed !== "object" || parsed === null) return { ...EMPTY, projects: [], sessions: {} };
  const obj = parsed as Record<string, unknown>;

  const projects: ClutchProject[] = [];
  if (Array.isArray(obj.projects)) {
    for (const entry of obj.projects) {
      if (typeof entry !== "object" || entry === null) continue;
      const p = entry as Record<string, unknown>;
      if (typeof p.id !== "string" || !p.id) continue;
      if (typeof p.name !== "string") continue;
      projects.push({
        id: p.id,
        name: p.name,
        createdAt: typeof p.createdAt === "string" ? p.createdAt : new Date(0).toISOString(),
      });
    }
  }

  const sessions: Record<string, SessionMetaEntry> = {};
  if (typeof obj.sessions === "object" && obj.sessions !== null) {
    for (const [id, value] of Object.entries(obj.sessions as Record<string, unknown>)) {
      if (typeof value !== "object" || value === null) continue;
      const entry: SessionMetaEntry = {};
      const s = value as Record<string, unknown>;
      if (typeof s.projectId === "string" && s.projectId) entry.projectId = s.projectId;
      if (s.archived === true) entry.archived = true;
      if (typeof s.archivedAt === "string") entry.archivedAt = s.archivedAt;
      // Drop entries that carry no meaning so the file does not accumulate
      // empty objects for every session ever opened.
      if (Object.keys(entry).length > 0) sessions[id] = entry;
    }
  }

  return { version: 1, projects, sessions };
}

export function loadSessionMeta(file: string): SessionMetaFile {
  try {
    return parseSessionMeta(readFileSync(file, "utf8"));
  } catch {
    return { ...EMPTY, projects: [], sessions: {} };
  }
}

export function saveSessionMeta(file: string, data: SessionMetaFile): void {
  mkdirSync(dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${randomBytes(6).toString("hex")}`;
  writeFileSync(tmp, `${JSON.stringify({ ...data, version: 1 }, null, 2)}\n`, { mode: 0o600 });
  try {
    renameSync(tmp, file);
  } catch {
    try {
      unlinkSync(tmp);
    } catch {
      /* tmp may already be gone */
    }
    throw new Error("session metadata could not be saved");
  }
}

export function newProjectId(): string {
  return `prj_${randomBytes(8).toString("hex")}`;
}

/** Project names are user-facing, so trim, collapse runs of whitespace, and
 *  cap the length rather than storing whatever arrived. */
export function normalizeProjectName(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const name = raw.replace(/\s+/g, " ").trim();
  if (!name) return null;
  return name.slice(0, 80);
}

export function upsertSession(
  data: SessionMetaFile,
  sessionId: string,
  patch: { projectId?: string | null; archived?: boolean },
): SessionMetaEntry {
  const current = data.sessions[sessionId] ?? {};
  const next: SessionMetaEntry = { ...current };
  if (patch.projectId !== undefined) {
    if (patch.projectId) next.projectId = patch.projectId;
    else delete next.projectId;
  }
  if (patch.archived !== undefined) {
    if (patch.archived) {
      next.archived = true;
      next.archivedAt = new Date().toISOString();
    } else {
      delete next.archived;
      delete next.archivedAt;
    }
  }
  if (Object.keys(next).length > 0) data.sessions[sessionId] = next;
  else delete data.sessions[sessionId];
  return next;
}

export function removeProject(data: SessionMetaFile, projectId: string): boolean {
  const before = data.projects.length;
  data.projects = data.projects.filter((p) => p.id !== projectId);
  if (data.projects.length === before) return false;
  // A deleted project must not leave assignments pointing at nothing.
  for (const [id, entry] of Object.entries(data.sessions)) {
    if (entry.projectId === projectId) {
      const { projectId: _dropped, ...rest } = entry;
      if (Object.keys(rest).length > 0) data.sessions[id] = rest;
      else delete data.sessions[id];
    }
  }
  return true;
}

export function defaultSessionMetaFile(clutchHome = process.env.CLUTCH_HOME ?? join(homedir(), ".clutch")): string {
  return sessionMetaPath(clutchHome);
}

export function sessionMetaExists(file: string): boolean {
  return existsSync(file);
}