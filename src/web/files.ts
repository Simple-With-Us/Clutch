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

import { readdir, readFile, stat } from "node:fs/promises";
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
  if (!target.startsWith(base + sep)) return null;
  return target;
}

/** The path of a folder relative to the root, with no leading separator. */
function relativePath(root: string, absolute: string): string {
  const base = resolve(root);
  if (absolute === base) return "";
  return absolute.slice(base.length + 1);
}

/**
 * List one folder.
 *
 * Folders come first and then the files, each by name, because that is the
 * order a person reads a folder in.
 */
export async function listDirectory(root: string, relative: string): Promise<DirectoryListing> {
  const target = resolveInside(root, relative);
  if (!target) throw new FileAccessError("that path is outside the folder the thread works in");
  const names = await readdir(target);
  const entries: FileEntry[] = [];
  for (const name of names) {
    if (entries.length >= LISTING_MAX_ENTRIES) break;
    if (name.startsWith(".") && name !== ".env.example") continue;
    const absolute = join(target, name);
    let isDirectory = false;
    let size: number | undefined;
    try {
      const info = await stat(absolute);
      isDirectory = info.isDirectory();
      if (!isDirectory) size = info.size;
    } catch {
      // A file that vanished between the listing and the stat is simply not
      // in the listing.
      continue;
    }
    if (isDirectory && SKIPPED_FOLDERS.has(name)) continue;
    entries.push({
      name,
      path: relativePath(root, absolute),
      kind: isDirectory ? "directory" : "file",
      ...(size === undefined ? {} : { size }),
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
  const target = resolveInside(root, relative);
  if (!target) throw new FileAccessError("that path is outside the folder the thread works in");
  const info = await stat(target);
  if (info.isDirectory()) throw new FileAccessError("that is a folder, not a file");
  const bytes = info.size;
  const handle = await readFile(target);
  const truncated = handle.byteLength > PREVIEW_MAX_BYTES;
  const slice = handle.subarray(0, PREVIEW_MAX_BYTES);
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
