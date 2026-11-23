import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { z } from "zod";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

// The token layer is the one file allowed to hold a design literal.
const THEME = "ios/App/Design/ClutchTheme.swift";

// A design literal: a fixed font size, or a numeric corner radius.
const LITERAL =
  /(?:\.system\(\s*size:\s*[0-9]+(?:\.[0-9]+)?\s*(?:,\s*weight:\s*\.[a-zA-Z]+)?\)|cornerRadius:\s*[0-9]+)/g;

type Allowlist = Record<string, Record<string, number>>;

// The allowlist is a config file, and a config file that drifts in shape
// fails here rather than halfway through a comparison.
const AllowlistSchema = z.record(z.string(), z.record(z.string(), z.number()));

function allowlist(): Allowlist {
  const raw: unknown = JSON.parse(
    readFileSync(join(ROOT, "tests/design-literal-allowlist.json"), "utf8"),
  );
  return AllowlistSchema.parse(raw);
}

function swiftFiles(): string[] {
  return execFileSync("git", ["ls-files", "-z", "ios"], {
    cwd: ROOT,
    encoding: "utf8",
  })
    .split("\0")
    .filter(Boolean)
    .filter((path) => path.endsWith(".swift") && path !== THEME);
}

function normalize(literal: string): string {
  return literal.replace(/\s+/g, " ").trim();
}

/**
 * The design literal guard.
 *
 * The token layer exists so the two native apps draw one concept one way, and
 * the literals that are left are spread across the files the later passes
 * have not reached yet.  Nothing stopped the next one.
 *
 * The guard is a ratchet rather than a blank slate.  The allowlist names every
 * literal that exists today, so the guard is green now and fails on a new
 * one.  A stale allowlist entry fails too, which is what makes the list shrink
 * as later passes migrate files onto the token layer.
 */
describe("the design literal guard", () => {
  const allowed = allowlist();

  it("finds no design literal outside the allowlist", () => {
    const offenders: string[] = [];

    for (const path of swiftFiles()) {
      const text = readFileSync(join(ROOT, path), "utf8");
      const counts = new Map<string, number>();
      for (const match of text.matchAll(LITERAL)) {
        const key = normalize(match[0]);
        counts.set(key, (counts.get(key) ?? 0) + 1);
      }
      const permitted = allowed[path] ?? {};
      for (const [literal, count] of counts) {
        const budget = permitted[literal] ?? 0;
        if (count > budget) {
          offenders.push(
            `${path}: ${literal} appears ${count} times, the allowlist allows ${budget}`,
          );
        }
      }
    }

    expect(offenders).toEqual([]);
  });

  it("has no stale allowlist entry", () => {
    const stale: string[] = [];

    for (const [path, literals] of Object.entries(allowed)) {
      const text = readFileSync(join(ROOT, path), "utf8");
      const present = new Map<string, number>();
      for (const match of text.matchAll(LITERAL)) {
        const key = normalize(match[0]);
        present.set(key, (present.get(key) ?? 0) + 1);
      }
      for (const [literal, budget] of Object.entries(literals)) {
        const actual = present.get(literal) ?? 0;
        if (actual < budget) {
          stale.push(
            `${path}: ${literal} is allowed ${budget} times but appears ${actual} times`,
          );
        }
      }
    }

    expect(stale).toEqual([]);
  });

  it("exempts the token layer and nothing else", () => {
    // The guard exempts one file by name, and the allowlist must not carry
    // an entry for it: the token layer is where a literal belongs.
    expect(allowed[THEME]).toBeUndefined();
    expect(swiftFiles()).not.toContain(THEME);
  });
});
