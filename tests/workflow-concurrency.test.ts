import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Concurrency isolation between pull_request runs and main runs.
 *
 * 2026-10-24: ios-ship.yml and mac-app-build.yml both put the push-to-main
 * run and the pull_request run in ONE concurrency group.  GitHub cancels the
 * run already pending in a group when a newer run enters it, so a
 * pull_request run -- which ships nothing and builds nothing, because the
 * ship and build jobs are skipped on pull_request -- silently destroyed the
 * push-to-main run waiting behind it:
 *
 *   - PR #195 (merge 6b3487f2) ship run 40075066124 was cancelled at
 *     07:48:58Z by PR run 40075616002 on another branch.  jobs: [], never
 *     dispatched, so that merge never reached TestFlight.
 *   - push 6b3487f2 mac build run 40075066076 was cancelled at 07:42:50Z by
 *     PR run 40073521084.
 *   - push ed510c85 ship run 40070842392 and mac build run 40070842512 were
 *     cancelled the same way at 06:36.
 *
 * These checks evaluate the real group expression for a push and a
 * pull_request event and require the two to differ, so a refactor cannot put
 * PR traffic back into the main group.  The expression is evaluated, not
 * pattern-matched, because the failure mode is semantic: a group that looks
 * event-scoped but resolves to one name for every event is exactly the bug.
 */

const ROOT = join(__dirname, "..");
const read = (rel: string): string => readFileSync(join(ROOT, rel), "utf8");

// --------------------------------------------------------- group extraction

/** The body of the top-level `concurrency:` mapping, up to the next top-level key. */
function concurrencyBlock(yml: string): string {
  const m = yml.match(/^concurrency:\n((?:[ \t]+.*\n|[ \t]*#.*\n|\n)*)/m);
  if (!m || m[1] === undefined) throw new Error("workflow must declare a concurrency block");
  return m[1];
}

function concurrencyGroup(yml: string): string {
  const m = concurrencyBlock(yml).match(/^[ \t]+group:[ \t]*(.+)$/m);
  if (!m || m[1] === undefined) throw new Error("workflow must declare concurrency.group");
  return m[1].trim();
}

function cancelInProgress(yml: string): string {
  const m = concurrencyBlock(yml).match(/^[ \t]+cancel-in-progress:[ \t]*(.+)$/m);
  return m && m[1] !== undefined ? m[1].trim() : "";
}

// --------------------------------------------------- expression evaluation

interface Ctx {
  event_name: string;
  head_ref: string;
}

const IDENT = /^[A-Za-z_][A-Za-z0-9_.]*$/;

function tokenize(src: string): string[] {
  const out: string[] = [];
  let i = 0;
  while (i < src.length) {
    const ch = src[i] as string;
    if (ch === " " || ch === "\t" || ch === "\n") {
      i += 1;
      continue;
    }
    if (ch === "'") {
      let j = i + 1;
      let s = "";
      while (j < src.length && src[j] !== "'") {
        s += src[j];
        j += 1;
      }
      out.push(`"${s}"`);
      i = j + 1;
      continue;
    }
    if (src.startsWith("==", i)) {
      out.push("==");
      i += 2;
      continue;
    }
    if (src.startsWith("&&", i)) {
      out.push("&&");
      i += 2;
      continue;
    }
    if (src.startsWith("||", i)) {
      out.push("||");
      i += 2;
      continue;
    }
    const m = /^[A-Za-z_][A-Za-z0-9_.]*/.exec(src.slice(i));
    if (!m) throw new Error(`unexpected character ${ch} in expression`);
    out.push(m[0]);
    i += m[0].length;
  }
  return out;
}

function lookup(name: string, ctx: Ctx): string {
  if (name === "github.event_name") return ctx.event_name;
  if (name === "github.head_ref") return ctx.head_ref;
  throw new Error(`expression uses an unsupported context: ${name}`);
}

function truthy(v: unknown): boolean {
  if (typeof v === "string") return v !== "";
  return Boolean(v);
}

/**
 * A tiny evaluator for the GitHub Actions expression subset used in a
 * concurrency group: string literals, `github.event_name`, `github.head_ref`,
 * `==`, `&&` and `||`, with GitHub's short-circuit semantics (so
 * `a && b || c` is the usual ternary trick).
 */
function parseExpression(tokens: string[]): (ctx: Ctx) => unknown {
  let pos = 0;
  const peek = (): string | undefined => tokens[pos];
  const eat = (t: string): void => {
    if (tokens[pos] !== t) throw new Error(`expected ${t}, got ${String(tokens[pos])}`);
    pos += 1;
  };

  function primary(): (ctx: Ctx) => unknown {
    const t = tokens[pos] as string;
    if (t === "(") {
      pos += 1;
      const e = orExpr();
      eat(")");
      return e;
    }
    if (t.startsWith('"')) {
      pos += 1;
      return () => t.slice(1, -1);
    }
    if (IDENT.test(t)) {
      pos += 1;
      return (ctx) => lookup(t, ctx);
    }
    throw new Error(`unexpected token ${t}`);
  }

  function equality(): (ctx: Ctx) => unknown {
    const left = primary();
    if (peek() === "==") {
      eat("==");
      const right = primary();
      return (ctx) => left(ctx) === right(ctx);
    }
    return left;
  }

  function andExpr(): (ctx: Ctx) => unknown {
    let left = equality();
    while (peek() === "&&") {
      eat("&&");
      const right = equality();
      const l = left;
      left = (ctx) => {
        const v = l(ctx);
        return truthy(v) ? right(ctx) : v;
      };
    }
    return left;
  }

  function orExpr(): (ctx: Ctx) => unknown {
    let left = andExpr();
    while (peek() === "||") {
      eat("||");
      const right = andExpr();
      const l = left;
      left = (ctx) => {
        const v = l(ctx);
        return truthy(v) ? v : right(ctx);
      };
    }
    return left;
  }

  const fn = orExpr();
  return fn;
}

/** The concurrency group name a run of this event would occupy. */
function resolveGroup(template: string, ctx: Ctx): string {
  const resolved = template.replace(/\$\{\{([\s\S]*?)\}\}/g, (_whole, expr: string) => {
    const value = parseExpression(tokenize(expr.trim()))(ctx);
    if (typeof value !== "string") {
      throw new Error(`group expression did not resolve to a string: ${JSON.stringify(value)}`);
    }
    return value;
  });
  if (resolved.includes("${{")) throw new Error("group template still has an unresolved expression");
  return resolved;
}

// ------------------------------------------------------------- the invariant

describe("a pull_request run never shares a concurrency group with a main run", () => {
  const workflows = [
    { rel: ".github/workflows/ios-ship.yml", label: "ios-ship.yml" },
    { rel: ".github/workflows/mac-app-build.yml", label: "mac-app-build.yml" },
  ];

  it.each(workflows)("$label resolves a PR run away from the main group", ({ rel }) => {
    const group = concurrencyGroup(read(rel));
    const push = resolveGroup(group, { event_name: "push", head_ref: "" });
    const schedule = resolveGroup(group, { event_name: "schedule", head_ref: "" });
    const pr = resolveGroup(group, { event_name: "pull_request", head_ref: "feature/x" });

    // The whole bug: a PR run and a main run in one group means the PR run
    // evicts the pending main run.
    expect(pr).not.toBe(push);
    expect(pr).not.toBe(schedule);

    // push and schedule must still share the main group, so a cron tick and a
    // push can never upload two builds for the same HEAD.
    expect(push).toBe(schedule);
  });

  it.each(workflows)("$label gives each PR branch its own group", ({ rel }) => {
    const group = concurrencyGroup(read(rel));
    const a = resolveGroup(group, { event_name: "pull_request", head_ref: "feature/a" });
    const b = resolveGroup(group, { event_name: "pull_request", head_ref: "feature/b" });
    expect(a).not.toBe(b);
    expect(a).toContain("feature/a");
    expect(b).toContain("feature/b");
  });

  it("ios-ship.yml keeps cancel-in-progress false so an in-flight main ship is never killed", () => {
    expect(cancelInProgress(read(".github/workflows/ios-ship.yml"))).toBe("false");
  });

  it("mac-app-build.yml keeps cancel-in-progress true so a newer push to the same PR wins", () => {
    expect(cancelInProgress(read(".github/workflows/mac-app-build.yml"))).toBe("true");
  });
});

// ------------------------------------------ the ship contract must not change

describe("the concurrency fix did not change what either workflow ships", () => {
  const ship = read(".github/workflows/ios-ship.yml");
  // The cron line carries comment lines above it, so match against the file
  // with its comment lines removed.
  const code = ship
    .split("\n")
    .filter((line) => !/^\s*#/.test(line))
    .join("\n");

  it("still ships on a push to main that touches the native tree", () => {
    expect(ship).toMatch(/push:\s*\n\s+branches:\s*\[main\]/);
    expect(ship).toMatch(/paths:\s*\n(?:\s+-\s+'[^']+'\n)*?\s+-\s+'ios\/\*\*'/);
  });

  it("still retries a failed push ship on the hourly schedule", () => {
    expect(code).toMatch(/^\s+schedule:\s*\n\s+- cron: '[^']+'/m);
    expect(ship).toMatch(/scheduled-ship-gate\.sh/);
  });

  it("still runs the PR-only iOS Release dry-run", () => {
    expect(ship).toMatch(/pr-build-only:/);
    expect(ship).toMatch(/name: iOS archive dry-run \(PR\)/);
    expect(ship).toMatch(/github\.event_name == 'pull_request'/);
    expect(ship).toMatch(/build-ios\.sh --simulator --release/);
  });

  it("still skips the ship job on pull_request, so a PR run uploads nothing", () => {
    expect(ship).toMatch(/if: github\.event\.repository\.fork == false && github\.event_name != 'pull_request'/);
  });
});
