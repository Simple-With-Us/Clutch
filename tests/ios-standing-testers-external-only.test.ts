import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(__dirname, "..");
const read = (rel: string): string => readFileSync(join(ROOT, rel), "utf8");

// Owner directive 2026-10-18/19: TestFlight is public external testing only.
// The ensure-standing-testers sync runs after every ship; it must not
// re-create the internal "Internal Testers" group.  ensureInternalTesterGroup
// itself stays exported for flows that need an internal group on purpose.
describe("standing testers sync is external-only", () => {
  it("never calls ensureInternalTesterGroup from ensure-standing-testers", () => {
    const mjs = read("scripts/ios-fleet/asc-api.mjs");
    const start = mjs.indexOf('method === "ensure-standing-testers"');
    const end = mjs.indexOf('method === "ensure-tf-ready"');
    expect(start).toBeGreaterThan(-1);
    expect(end).toBeGreaterThan(start);
    const branch = mjs.slice(start, end);
    expect(branch).not.toMatch(/await ensureInternalTesterGroup\(/);
  });

  it("keeps ensureInternalTesterGroup exported for opt-in flows", () => {
    const mjs = read("scripts/ios-fleet/asc-api.mjs");
    expect(mjs).toMatch(/export async function ensureInternalTesterGroup\(/);
  });
});
