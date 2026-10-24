import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

// The Fleet Recall surfaces whose user-visible copy the owner ruled on
// 2026-10-23: between sentences, a real U+00A0 then a normal space.  SwiftUI
// collapses two ASCII spaces to one, so the gap has to be the no-break pair.
const SWIFT_FILES = [
  "ios/App/Models/FleetRecallModels.swift",
  "ios/App/Services/FleetRecallClient.swift",
  "ios/App/Views/FleetRecallView.swift",
];

// A sentence end followed by two ASCII spaces and more text.
const TWO_ASCII_SPACES = /[.!?]  \S/;

/** Drops everything from the first `//` that sits outside a string literal. */
function stripComments(line: string): string {
  let out = "";
  let i = 0;
  let inString = false;

  while (i < line.length) {
    const ch = line[i]!;
    if (inString) {
      if (ch === "\\") {
        out += ch + (line[i + 1] ?? "");
        i += 2;
        continue;
      }
      if (ch === '"') inString = false;
      out += ch;
      i += 1;
      continue;
    }
    if (ch === '"') {
      inString = true;
      out += ch;
      i += 1;
      continue;
    }
    if (ch === "/" && line[i + 1] === "/") break;
    out += ch;
    i += 1;
  }

  return out;
}

/** Every Swift string literal on a line, interpolation-aware. */
function swiftStringLiterals(code: string): string[] {
  const literals: string[] = [];
  let i = 0;

  while (i < code.length) {
    if (code[i] !== '"') {
      i += 1;
      continue;
    }
    let j = i + 1;
    let depth = 0;
    let literal = "";
    while (j < code.length) {
      const ch = code[j]!;
      if (ch === "\\") {
        if (code[j + 1] === "(") {
          depth += 1;
          literal += ch + "(";
          j += 2;
          continue;
        }
        literal += ch + (code[j + 1] ?? "");
        j += 2;
        continue;
      }
      if (depth > 0) {
        if (ch === "(") depth += 1;
        if (ch === ")") depth -= 1;
        literal += ch;
        j += 1;
        continue;
      }
      if (ch === '"') break;
      literal += ch;
      j += 1;
    }
    literals.push(literal);
    i = j + 1;
  }

  return literals;
}

/** The `///` block sitting directly above a line, bottom-up collected. */
function docCommentAbove(lines: string[], index: number): string {
  const doc: string[] = [];
  for (let i = index - 1; i >= 0; i -= 1) {
    const trimmed = lines[i]!.trim();
    if (!trimmed.startsWith("///")) break;
    doc.unshift(trimmed);
  }
  return doc.join("\n");
}

describe("fleet recall copy gap", () => {
  it("has no two-ASCII-space sentence gaps in user-visible Swift literals", () => {
    for (const rel of SWIFT_FILES) {
      expect(existsSync(join(ROOT, rel)), `${rel} should exist`).toBe(true);
    }

    const hits: string[] = [];
    for (const rel of SWIFT_FILES) {
      const lines = readFileSync(join(ROOT, rel), "utf8").split("\n");
      lines.forEach((line, i) => {
        for (const literal of swiftStringLiterals(stripComments(line))) {
          if (TWO_ASCII_SPACES.test(literal)) {
            hits.push(`${rel}:${i + 1}: ${literal.trim().slice(0, 120)}`);
          }
        }
      });
    }

    expect(hits).toEqual([]);
  });

  it("detects two-ASCII-space gaps and ignores comment lines", () => {
    // Positive control: the guard has to fire on the old copy.
    const bad = swiftStringLiterals(stripComments('        return "One.  Two."'));
    expect(bad.some((literal) => TWO_ASCII_SPACES.test(literal))).toBe(true);

    // And it has to pass both spellings of the ruled fix: a literal U+00A0 in
    // the source, and the Swift `\u{00A0}` escape.
    const realNbsp = swiftStringLiterals(stripComments('        return "One.\u00A0 Two."'));
    expect(realNbsp.some((literal) => TWO_ASCII_SPACES.test(literal))).toBe(false);

    const escapedNbsp = swiftStringLiterals(stripComments('        return "One.\\u{00A0} Two."'));
    expect(escapedNbsp.some((literal) => TWO_ASCII_SPACES.test(literal))).toBe(false);

    // A `//` comment line never contributes a literal.
    const commented = swiftStringLiterals(stripComments("    /// Two spaces between sentences."));
    expect(commented).toEqual([]);
  });

  it("documents the sentence gap helper on the contribution error copy", () => {
    const rel = "ios/App/Models/FleetRecallModels.swift";
    const text = readFileSync(join(ROOT, rel), "utf8");
    const lines = text.split("\n");

    expect(text).not.toContain("two spaces between sentences");

    const index = lines.findIndex((line) => line.includes("public var message"));
    expect(index, `${rel} should declare public var message`).toBeGreaterThan(-1);

    expect(docCommentAbove(lines, index)).toContain("Copy.sentenceGap");
  });
});
