import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const IOS_ROOT = join(ROOT, "ios");

// The owner ruled on 2026-10-23: user-visible copy joins sentences with a real
// U+00A0 then a normal space.  SwiftUI collapses two ASCII spaces to one, so a
// two-ASCII-space gap silently loses the sentence gap on screen.  The guard
// covers EVERY Swift file under ios/ -- the iOS app, the Mac app, the unit
// tests and the UI tests -- not just the Fleet Recall surfaces.
const SWIFT_ROOT = "ios";

// A sentence end followed by two ASCII spaces and more text.
const TWO_ASCII_SPACES = /[.!?]  \S/;

// A sentence that closes with an ellipsis, then a plain space and a capital.
// SwiftUI collapses the gap here exactly as it does after `.`, `!` and `?`, so
// an ellipsis boundary needs the same U+00A0 treatment.
const ELLIPSIS_ASCII_GAP = /…[ \t](?=[A-Z])/;

/** Every `.swift` file under a directory, recursively, sorted. */
function swiftFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...swiftFiles(full));
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".swift")) out.push(full);
  }
  return out.sort();
}

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

describe("swift copy gap", () => {
  it("scans every Swift file under ios/", () => {
    const files = swiftFiles(IOS_ROOT).map((full) => relative(ROOT, full));
    expect(files.length).toBeGreaterThan(40);

    // The scan has to reach the app, the Mac app and the test targets.
    expect(files).toContain("ios/App/Views/PairView.swift");
    expect(files).toContain("ios/App/Views/InfisicalSettingsSection.swift");
    expect(files).toContain("ios/App/Services/DictationController.swift");
    expect(files).toContain("ios/App/Services/TranscriptionService.swift");
    expect(files).toContain("ios/Mac/ChatViewMac.swift");
  });

  it("has no two-ASCII-space sentence gaps in user-visible Swift literals", () => {
    const hits: string[] = [];
    for (const full of swiftFiles(IOS_ROOT)) {
      const rel = relative(ROOT, full);
      const lines = readFileSync(full, "utf8").split("\n");
      lines.forEach((line, i) => {
        for (const literal of swiftStringLiterals(stripComments(line))) {
          if (TWO_ASCII_SPACES.test(literal)) {
            hits.push(`${rel}:${i + 1}: ${literal.trim().slice(0, 120)}`);
          }
        }
      });
    }

    expect(
      hits,
      `two-ASCII-space sentence gaps found:\n${hits.join("\n")}`,
    ).toEqual([]);
  });

  it("has no plain-space gap after an ellipsis in user-visible Swift literals", () => {
    const hits: string[] = [];
    for (const full of swiftFiles(IOS_ROOT)) {
      const rel = relative(ROOT, full);
      const lines = readFileSync(full, "utf8").split("\n");
      lines.forEach((line, i) => {
        for (const literal of swiftStringLiterals(stripComments(line))) {
          if (ELLIPSIS_ASCII_GAP.test(literal)) {
            hits.push(`${rel}:${i + 1}: ${literal.trim().slice(0, 120)}`);
          }
        }
      });
    }

    expect(
      hits,
      `plain-space gaps after an ellipsis found:\n${hits.join("\n")}`,
    ).toEqual([]);
  });

  it("detects a plain-space gap after an ellipsis and accepts the Copy helper", () => {
    // Positive control: the guard has to fire on the old copy.
    const bad = swiftStringLiterals(stripComments('        Text("Listening… Tap The Mic Again To Stop.")'));
    expect(bad.some((literal) => ELLIPSIS_ASCII_GAP.test(literal))).toBe(true);

    // And it has to pass the ruled fix, in both spellings, and the helper.
    const escapedNbsp = swiftStringLiterals(stripComments('        Text("Listening…\\u{00A0} Tap The Mic Again To Stop.")'));
    expect(escapedNbsp.some((literal) => ELLIPSIS_ASCII_GAP.test(literal))).toBe(false);

    const helper = swiftStringLiterals(stripComments('        Text(Copy.gap("Listening…", "Tap The Mic Again To Stop."))'));
    expect(helper.some((literal) => ELLIPSIS_ASCII_GAP.test(literal))).toBe(false);
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

    // `Copy.gap` joins its arguments with the gap, so it never carries one.
    const helper = swiftStringLiterals(stripComments('        Copy.gap("One.", "Two.")'));
    expect(helper.some((literal) => TWO_ASCII_SPACES.test(literal))).toBe(false);

    // A `//` comment line never contributes a literal.
    const commented = swiftStringLiterals(stripComments("    /// Two spaces between sentences."));
    expect(commented).toEqual([]);
  });

  it("keeps the sentence gap helper in PairView.swift", () => {
    const rel = "ios/App/Views/PairView.swift";
    const text = readFileSync(join(ROOT, rel), "utf8");

    expect(text).toContain('static let sentenceGap = "\\u{00A0} "');
    expect(text).toContain("static func gap(");
  });

  it("keeps every Swift target compiling the Copy helper's file", () => {
    // `Copy` lives in ios/App/Views/PairView.swift.  Any Swift file that calls
    // Copy.gap has to sit in a target that also compiles PairView.swift, or the
    // call does not resolve.  ios/project.yml is the source of truth.
    const yml = readFileSync(join(ROOT, "ios/project.yml"), "utf8");
    const pairView = "App/Views/PairView.swift";

    // The iOS app target compiles the whole App directory.
    expect(yml).toContain("path: App");

    // The macOS target compiles App as well, minus an explicit exclude list
    // that does not mention PairView.swift.
    const excludes = [...yml.matchAll(/- ([^\n]*\.swift)/g)].map((m) => m[1]!);
    expect(excludes).not.toContain(pairView);
  });
});

describe("swift copy gap scan helper", () => {
  it("reads the ios tree without throwing", () => {
    expect(statSync(IOS_ROOT).isDirectory()).toBe(true);
    expect(swiftFiles(IOS_ROOT).length).toBeGreaterThan(0);
  });
});
