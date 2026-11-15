import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * The committed Xcode project matches the tree.
 *
 * ios/Clutch.xcodeproj is generated from ios/project.yml by XcodeGen and is
 * committed, so the project opens in Xcode without running XcodeGen first.  A
 * copy that drifts is a trap: the committed project has named a Swift file
 * that no longer exists, and a build from it failed on the file it could not
 * find.  The Mac build regenerates the project from project.yml every time,
 * so this only guards the convenience copy.
 */

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const PROJECT = join(ROOT, "ios", "Clutch.xcodeproj", "project.pbxproj");
const IOS_DIR = join(ROOT, "ios");

/** Every Swift file the tree holds, by name. */
function treeSwiftFiles(): Set<string> {
  const entries = readdirSync(IOS_DIR, { recursive: true, encoding: "utf8" });
  return new Set(
    entries
      .filter((entry) => entry.endsWith(".swift"))
      .map((entry) => entry.split(/[\\/]/).pop() as string),
  );
}

/**
 * Every Swift file the committed project names, by name.
 *
 * The project records a file as `path = Name.swift;` in a PBXFileReference,
 * so the name is what a build resolves.
 */
function projectSwiftFiles(): Set<string> {
  const body = readFileSync(PROJECT, "utf8");
  return new Set(
    [...body.matchAll(/path = ([A-Za-z0-9_+.]+\.swift);/g)].map((match) => match[1] as string),
  );
}

describe("the committed Xcode project", () => {
  it("names every Swift file the tree holds", () => {
    const tree = treeSwiftFiles();
    const project = projectSwiftFiles();
    const missing = [...tree].filter((name) => !project.has(name)).sort();
    expect(missing, "Swift files the committed project does not name").toEqual([]);
  });

  it("names no Swift file the tree no longer holds", () => {
    const tree = treeSwiftFiles();
    const project = projectSwiftFiles();
    const gone = [...project].filter((name) => !tree.has(name)).sort();
    expect(gone, "Swift files the committed project names but the tree no longer holds").toEqual([]);
  });
});
