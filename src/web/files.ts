/**
 * Reading the folder the engines work in.
 *
 * The web canvas shows the files of the folder a thread works in, and the
 * native apps answer the same question.  The sidecar is the one that can
 * answer it: the native apps speak the sidecar's contract, never the host's.
 *
 * The files are read from the folder itself rather than through the host,
 * because the engines do not all live in the host.  A code engine's thread
 * has no host session to ask, and the answer has to be the same for every
 * engine, so the folder is read once, the same way, for all of them.
 */

import { lstat, open, readdir, realpath, stat } from "node:fs/promises";
import { basename, join, resolve, sep } from "node:path";

/** One entry in a folder listing. */
export interface FileEntry {
  /** The name on its own, without the folders above it. */
  readonly name: string;
  /** The path relative to the folder the listing is rooted at. */
  readonly path: string;
  /** Whether the entry is a file or a folder. */
  readonly kind: "file" | "directory";
  /** The size in bytes, for a file. */
  readonly size?: number;
}

/** One folder, and what is in it. */
export interface DirectoryListing {
  /** The path of the folder, relative to the root. */
  readonly path: string;
  /** The folder above it, or null at the root. */
  readonly parent: string | null;
  /** What is in it, folders first and then by name. */
  readonly entries: readonly FileEntry[];
}

/** One file, and enough of it to show. */
export interface FilePreview {
  /** The path of the file, relative to the root. */
  readonly path: string;
  /** The name on its own. */
  readonly name: string;
  /** Whether the file holds text that can be shown. */
  readonly kind: "text" | "binary";
  /** The size of the file in bytes. */
  readonly bytes: number;
  /** Whether the file was longer than the preview asked for. */
  readonly truncated: boolean;
  /** The text of the file, for a text file. */
  readonly content: string;
}

/** How many bytes a preview carries. */
export const PREVIEW_MAX_BYTES = 256 * 1024;

/** How many entries a listing carries. */
export const LISTING_MAX_ENTRIES = 2_000;

/** The folders that never show up in a listing. */
const SKIPPED_FOLDERS = new Set([".git", "node_modules", ".build", "DerivedData"]);

/**
 * The path of one entry, relative to the root.
 *
 * A path that leaves the root is refused: the listing is rooted at the
 * folder the thread works in, and a client that asks for more than that
 * would be reading the whole disk.
 */
export function resolveInside(root: string, relative: string): string | null {
  const base = resolve(root);
  const target = resolve(base, relative);
  if (target === base) return base;
  // The base already ends in a separator at the filesystem root, so only
  // add one when it is missing.
  const prefix = base.endsWith(sep) ? base : base + sep;
  if (!target.startsWith(prefix)) return null;
  return target;
}

/**
 * Resolve one path, then confirm the real location still sits under the root.
 *
 * The lexical check alone follows no symlinks.  `stat`/`readFile` do, so a
 * symlink under the thread folder could otherwise escape to the rest of the
 * disk.  Re-checking `realpath` closes that door.
 */
export async function resolveInsideReal(root: string, relative: string): Promise<string | null> {
  const target = resolveInside(root, relative);
  if (target === null) return null;
  let baseReal: string;
  let targetReal: string;
  try {
    baseReal = await realpath(root);
    // lstat first so a dangling symlink is refused instead of throwing ENOENT
    // from realpath in a way that looks like "outside".
    await lstat(target);
    targetReal = await realpath(target);
  } catch {
    return null;
  }
  if (targetReal === baseReal) return targetReal;
  const prefix = baseReal.endsWith(sep) ? baseReal : baseReal + sep;
  if (!targetReal.startsWith(prefix)) return null;
  return targetReal;
}

/** The path of a folder relative to the root, with no leading separator. */
function relativePath(root: string, absolute: string): string {
  const base = resolve(root);
  if (absolute === base) return "";
  const start = base.endsWith(sep) ? base.length : base.length + 1;
  return absolute.slice(start);
}

/**
 * List one folder.
 *
 * Folders come first and then the files, each by name, because that is the
 * order a person reads a folder in.
 */
export async function listDirectory(root: string, relative: string): Promise<DirectoryListing> {
  const target = await resolveInsideReal(root, relative);
  if (!target) throw new FileAccessError("that path is outside the folder the thread works in");
  const names = await readdir(target);
  // Sort before truncating so the entries that fall off the cap are the last
  // by name rather than wherever the filesystem happened to list them.
  names.sort((left, right) => left.localeCompare(right));
  const candidates = names
    .filter((name) => !(name.startsWith(".") && name !== ".env.example"))
    .slice(0, LISTING_MAX_ENTRIES);
  // Stat with bounded concurrency so a large folder does not wait on one
  // entry at a time across thousands of round-trips.
  const CONCURRENCY = 32;
  type Raw = { name: string; absolute: string; isDirectory: boolean; size?: number } | null;
  const raw: Raw[] = new Array(candidates.length).fill(null);
  let next = 0;
  async function worker(): Promise<void> {
    while (next < candidates.length) {
      const index = next;
      next += 1;
      const name = candidates[index]!;
      const absolute = join(target, name);
      try {
        const info = await stat(absolute);
        const isDirectory = info.isDirectory();
        if (isDirectory && SKIPPED_FOLDERS.has(name)) {
          raw[index] = null;
          continue;
        }
        raw[index] = {
          name,
          absolute,
          isDirectory,
          ...(isDirectory ? {} : { size: info.size }),
        };
      } catch {
        raw[index] = null;
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, candidates.length) }, () => worker()));
  const entries: FileEntry[] = [];
  for (const item of raw) {
    if (!item) continue;
    entries.push({
      name: item.name,
      path: relativePath(root, item.absolute),
      kind: item.isDirectory ? "directory" : "file",
      ...(item.size === undefined ? {} : { size: item.size }),
    });
  }
  entries.sort((left, right) => {
    if (left.kind !== right.kind) return left.kind === "directory" ? -1 : 1;
    return left.name.localeCompare(right.name);
  });
  const path = relativePath(root, target);
  const parent = path === "" ? null : path.split(sep).slice(0, -1).join(sep);
  return { path, parent, entries };
}

/**
 * Read one file, far enough to show it.
 *
 * A file that is not text is reported as such rather than shown as a wall
 * of replacement characters, and a file longer than the preview carries a
 * note that it was cut short.
 */
export async function readPreview(root: string, relative: string): Promise<FilePreview> {
  const target = await resolveInsideReal(root, relative);
  if (!target) throw new FileAccessError("that path is outside the folder the thread works in");
  const info = await stat(target);
  if (info.isDirectory()) throw new FileAccessError("that is a folder, not a file");
  const bytes = info.size;
  // Read only as far as the preview reaches: the whole file never lands in
  // the sidecar's memory, no matter how large it is on disk.
  const handle = await open(target, "r");
  let read = 0;
  let slice: Buffer;
  try {
    const probe = Buffer.alloc(PREVIEW_MAX_BYTES + 1);
    while (read < probe.length) {
      const { bytesRead } = await handle.read(probe, read, probe.length - read, null);
      if (bytesRead === 0) break;
      read += bytesRead;
    }
    slice = probe.subarray(0, Math.min(read, PREVIEW_MAX_BYTES));
  } finally {
    await handle.close();
  }
  const truncated = read > PREVIEW_MAX_BYTES;
  const isBinary = slice.includes(0);
  if (isBinary) {
    return {
      path: relativePath(root, target),
      name: basename(target),
      kind: "binary",
      bytes,
      truncated,
      content: "",
    };
  }
  return {
    path: relativePath(root, target),
    name: basename(target),
    kind: "text",
    bytes,
    truncated,
    content: slice.toString("utf8"),
  };
}

/** A file that cannot be read, said in the words a client can show. */
export class FileAccessError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "FileAccessError";
  }
}
