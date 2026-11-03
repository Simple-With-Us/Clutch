import { describe, expect, it } from "vitest";
import { normalizeSessionFolder, sessionIsInFolder } from "../src/web/session-folder-scope.ts";

describe("folder session scope", () => {
  it("includes the folder and descendants without matching sibling prefixes", () => {
    expect(sessionIsInFolder("/Users/jay/Code", "/Users/jay/Code/")).toBe(true);
    expect(sessionIsInFolder("/Users/jay/Code/Clutch", "/Users/jay/Code/")).toBe(true);
    expect(sessionIsInFolder("/Users/jay/CodeCaps", "/Users/jay/Code")).toBe(false);
    expect(sessionIsInFolder("/Users/jay/Code/Clutch", "/Users/jay/Code", false)).toBe(false);
    expect(sessionIsInFolder("/Users/jay/Code/../Code/Clutch", "/Users/jay/Code")).toBe(true);
    expect(sessionIsInFolder("/anything", "/")).toBe(true);
  });
  it("rejects ambiguous relative folders and missing directories", () => {
    expect(normalizeSessionFolder("../Code")).toBeNull();
    expect(normalizeSessionFolder("/Code\0")).toBeNull();
    expect(sessionIsInFolder(undefined, "/Code")).toBe(false);
  });
});
