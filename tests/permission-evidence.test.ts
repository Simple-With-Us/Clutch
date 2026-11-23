import { describe, expect, it } from "vitest";

import {
  bounded,
  buildPermissionEvidence,
  compactDiff,
  permissionEvidenceFromParams,
} from "../src/web/chat-bridge.ts";

describe("permission evidence", () => {
  it("carries the command a shell tool wants to run", () => {
    const evidence = buildPermissionEvidence({ command: "rm -rf build" });
    expect(evidence).toEqual({ command: "rm -rf build" });
  });

  it("carries the path a file tool wants to touch", () => {
    expect(buildPermissionEvidence({ file_path: "/tmp/clutch/build.log" })).toEqual({
      path: "/tmp/clutch/build.log",
    });
  });

  it("carries a compact diff of what an edit would write", () => {
    const evidence = buildPermissionEvidence({ old_string: "let a = 1\n", new_string: "let a = 2\n" });
    expect(evidence?.diff).toBe("- let a = 1\n+ let a = 2");
  });

  it("has no evidence when the tool said nothing the owner can read", () => {
    expect(buildPermissionEvidence({})).toBeUndefined();
    expect(buildPermissionEvidence(undefined)).toBeUndefined();
    expect(buildPermissionEvidence([{ command: "ls" }])).toBeUndefined();
  });

  it("drops a field the sidecar does not name", () => {
    const params = {
      sessionId: "s1",
      toolCall: {
        title: "Run a command",
        kind: "bash",
        rawInput: { command: "ls", internal: "a field the sidecar does not name", nested: { command: "rm" } },
      },
    };
    const evidence = permissionEvidenceFromParams(params);
    expect(evidence).toEqual({ command: "ls" });
    expect(JSON.stringify(evidence)).not.toContain("internal");
  });

  it("has no evidence when the params are not a permission request", () => {
    expect(permissionEvidenceFromParams({ sessionId: "s1" })).toBeUndefined();
    expect(permissionEvidenceFromParams(null)).toBeUndefined();
  });

  it("says that a cut command was cut", () => {
    const long = "x".repeat(2_100);
    const evidence = buildPermissionEvidence({ command: long });
    expect(evidence?.command.length).toBe(2_001);
    expect(evidence?.command.endsWith("…")).toBe(true);
    expect(bounded("short", 10)).toBe("short");
  });

  it("shows the lines that changed and leaves the ones that did not out", () => {
    const oldText = ["a", "b", "c", "d", "e"].join("\n");
    const newText = ["a", "b", "c", "x", "y"].join("\n");
    const diff = compactDiff(oldText, newText);
    // The lines both sides share are not a change, so they are not in it.
    expect(diff).toBe("- d\n- e\n+ x\n+ y");
    expect(compactDiff(undefined, undefined)).toBeUndefined();
  });

  it("has no evidence when the tool's input is not an object", () => {
    // A shape the sidecar does not understand is not evidence, and it is
    // not a reason to drop the request:  the engine is blocked on it.
    expect(permissionEvidenceFromParams({ toolCall: { rawInput: "ls -la" } })).toBeUndefined();
    expect(permissionEvidenceFromParams({ toolCall: { rawInput: [{ command: "ls" }] } })).toBeUndefined();
    expect(permissionEvidenceFromParams({ toolCall: { rawInput: 7 } })).toBeUndefined();
  });

  it("has no evidence when the params do not parse", () => {
    // A malformed request is still a request the engine waits on, so the
    // reading of it must not throw and must not invent evidence.
    expect(permissionEvidenceFromParams({ options: [{ optionId: 7 }] })).toBeUndefined();
    expect(permissionEvidenceFromParams({ toolCall: { title: 7 } })).toBeUndefined();
  });

  it("says that an edit was cut rather than showing a change that is not there", () => {
    // The engine's input is unbounded and the request is on the message
    // path, so the diff reads a bounded part of the edit.  A change past
    // the cut is said, and not shown as nothing.
    const filler = "x".repeat(20_100);
    const oldText = `head\n${filler}\nlast`;
    const newText = `head\n${filler}\nchanged`;
    const evidence = buildPermissionEvidence({ old_string: oldText, new_string: newText });
    expect(evidence?.diff).toContain("the edit was cut here");
    expect(evidence?.diff).not.toContain("- last");
  });

  it("shows the change of an edit that is not cut", () => {
    const oldText = "head\nmiddle\nlast";
    const newText = "head\nmiddle\nchanged";
    const evidence = buildPermissionEvidence({ old_string: oldText, new_string: newText });
    expect(evidence?.diff).toContain("- last");
    expect(evidence?.diff).toContain("+ changed");
    expect(evidence?.diff).not.toContain("cut");
  });

  it("shows a few changed lines and says how many it left out", () => {
    const oldText = ["a", "b", "c", "d", "e", "f", "g"].join("\n");
    const newText = ["a", "b", "c", "x", "y", "z", "w"].join("\n");
    const diff = compactDiff(oldText, newText);
    expect(diff).toContain("- d");
    expect(diff).toContain("+ x");
    expect(diff).toContain("2 more lines");
  });
});
