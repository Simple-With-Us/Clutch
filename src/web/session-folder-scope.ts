import { posix } from "node:path";

export function normalizeSessionFolder(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const folder = value.trim();
  if (!folder.startsWith("/") || folder.includes("\0")) return null;
  return posix.normalize(folder).replace(/\/$/, "") || "/";
}

/** Match whole path segments so /Code never matches /CodeCaps. */
export function sessionIsInFolder(cwd: unknown, folder: string, descendants = true): boolean {
  const candidate = normalizeSessionFolder(cwd);
  const selected = normalizeSessionFolder(folder);
  if (!candidate || !selected) return false;
  return candidate === selected || (descendants && (selected === "/" || candidate.startsWith(`${selected}/`)));
}
