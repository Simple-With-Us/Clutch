import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { listDirectory, readPreview, resolveInside, FileAccessError } from "../src/web/files.ts";

/**
 * files — reading the folder the engines work in.
 *
 * The web canvas shows the files of the folder a thread works in, and the
 * native apps ask the sidecar for the same thing.  The tests read a folder
 * that is made for the purpose, so the answers do not depend on what the
 * machine happens to have on it.
 */

let root = "";

beforeAll(() => {
  root = mkdtempSync(join(tmpdir(), "clutch-files-"));
  mkdirSync(join(root, "src"));
  mkdirSync(join(root, ".git"));
  mkdirSync(join(root, "node_modules"));
  writeFileSync(join(root, "README.md"), "# Clutch\n\nThe clutch app.\n");
  writeFileSync(join(root, "src", "main.ts"), "export const main = () => undefined;\n");
  writeFileSync(join(root, ".git", "config"), "[core]\n");
  writeFileSync(join(root, "node_modules", "left-pad.js"), "module.exports = 1;\n");
  writeFileSync(join(root, "picture.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00, 0x01]));
});

afterAll(() => {
  rmSync(root, { recursive: true, force: true });
});

describe("the folder a thread works in", () => {
  it("lists the files, folders first", async () => {
    const listing = await listDirectory(root, "");
    expect(listing.path).toBe("");
    expect(listing.parent).toBe(null);
    // Folders first, then the files by name, case folded: "picture.png"
    // before "README.md", the way a person reads a folder.
    expect(listing.entries.map((entry) => entry.name)).toEqual(["src", "picture.png", "README.md"]);
  });

  it("says what kind each entry is, and how big a file is", async () => {
    const listing = await listDirectory(root, "");
    const source = listing.entries.find((entry) => entry.name === "src");
    expect(source?.kind).toBe("directory");
    const readme = listing.entries.find((entry) => entry.name === "README.md");
    expect(readme?.kind).toBe("file");
    expect(readme?.size).toBeGreaterThan(0);
  });

  it("leaves out the folders that are never worth showing", async () => {
    const listing = await listDirectory(root, "");
    const names = listing.entries.map((entry) => entry.name);
    expect(names).not.toContain(".git");
    expect(names).not.toContain("node_modules");
  });

  it("lists a folder inside the root", async () => {
    const listing = await listDirectory(root, "src");
    expect(listing.path).toBe("src");
    expect(listing.parent).toBe("");
    expect(listing.entries.map((entry) => entry.name)).toEqual(["main.ts"]);
  });

  it("refuses a path that leaves the root", async () => {
    await expect(listDirectory(root, "../..")).rejects.toThrow(FileAccessError);
    await expect(listDirectory(root, "/etc")).rejects.toThrow(/outside the folder/);
  });
});

describe("one file", () => {
  it("reads the text of it", async () => {
    const preview = await readPreview(root, "README.md");
    expect(preview.name).toBe("README.md");
    expect(preview.path).toBe("README.md");
    expect(preview.kind).toBe("text");
    expect(preview.content).toContain("# Clutch");
    expect(preview.truncated).toBe(false);
  });

  it("says a file that is not text is not text", async () => {
    const preview = await readPreview(root, "picture.png");
    expect(preview.kind).toBe("binary");
    expect(preview.content).toBe("");
  });

  it("refuses a folder", async () => {
    await expect(readPreview(root, "src")).rejects.toThrow(/folder, not a file/);
  });

  it("refuses a path that leaves the root", async () => {
    await expect(readPreview(root, "../../etc/passwd")).rejects.toThrow(/outside the folder/);
  });
});

describe("the path a client asked for", () => {
  it("stays inside the root", () => {
    expect(resolveInside(root, "src")).toBe(join(root, "src"));
    expect(resolveInside(root, "")).toBe(root);
  });

  it("refuses to leave the root", () => {
    expect(resolveInside(root, "..")).toBe(null);
    expect(resolveInside(root, "../sibling")).toBe(null);
    expect(resolveInside(root, "/etc/passwd")).toBe(null);
  });

  it("refuses a folder that only shares a prefix with the root", () => {
    // "/work/app" must not answer for "/work/application".
    expect(resolveInside("/work/app", "../application")).toBe(null);
  });
  it("refuses a symlink that escapes the thread folder", async () => {
    const outside = await mkdtemp(join(tmpdir(), "clutch-files-out-"));
    await writeFile(join(outside, "secret.txt"), "nope", "utf8");
    await symlink(outside, join(root, "escape"));
    await expect(listDirectory(root, "escape")).rejects.toThrow(/outside the folder/);
    await expect(readPreview(root, "escape/secret.txt")).rejects.toThrow(/outside the folder/);
  });

});
