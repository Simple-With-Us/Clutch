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

  it("deletes leftover internal groups during the sync", () => {
    // Owner directive 2026-10-18 ("delete internal group if that isn't
    // problem to do"), made automatic 2026-10-19.  The sync must remove any
    // internal group the old pipeline left behind; deleting a group never
    // deletes the testers themselves.
    const mjs = read("scripts/ios-fleet/asc-api.mjs");
    const start = mjs.indexOf('method === "ensure-standing-testers"');
    const end = mjs.indexOf('method === "ensure-tf-ready"');
    expect(start).toBeGreaterThan(-1);
    expect(end).toBeGreaterThan(start);
    const branch = mjs.slice(start, end);
    expect(branch).toMatch(/isInternalGroup === true/);
    expect(branch).toMatch(/api\("DELETE", `\/v1\/betaGroups\/\$\{g\.id\}`\)/);
  });
});

// Installability no longer comes from an internal tester count: there is no
// internal group.  ensure-tf-ready must decide rc=0/5/6 from the external
// group assignment and public-link state of the shipped build.
describe("ensure-tf-ready readiness is external-only", () => {
  it("never calls countInternalTesters from ensure-tf-ready", () => {
    const mjs = read("scripts/ios-fleet/asc-api.mjs");
    const start = mjs.indexOf('method === "ensure-tf-ready"');
    expect(start).toBeGreaterThan(-1);
    const branch = mjs.slice(start);
    expect(branch).not.toMatch(/countInternalTesters\(/);
    expect(branch).toMatch(/externalInstallability\(/);
  });

  it("keeps countInternalTesters exported for opt-in flows", () => {
    const mjs = read("scripts/ios-fleet/asc-api.mjs");
    expect(mjs).toMatch(/export async function countInternalTesters\(/);
  });

  it("ship-testflight.sh no longer claims internal testers can install", () => {
    const sh = read("scripts/ios-fleet/ship-testflight.sh");
    expect(sh).not.toMatch(/TestFlight internal testers can install this build/);
    expect(sh).toMatch(/TestFlight external testers can install this build after Beta App Review/);
    expect(sh).not.toMatch(/has no internal TestFlight tester/);
  });
});
