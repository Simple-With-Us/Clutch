import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { deleteInternalGroups, externalInstallability } from "../scripts/ios-fleet/asc-api.mjs";

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

  it("has no internal-group creation surface at all", () => {
    // Kody #208 finding 3 resolved by removal (minimum correction): Clutch is
    // external-only and had no consumer of ensureInternalTesterGroup, so the
    // dead helper and any CLI route to it are gone rather than wired up.
    const mjs = read("scripts/ios-fleet/asc-api.mjs");
    expect(mjs).not.toMatch(/ensureInternalTesterGroup/);
    expect(mjs).not.toMatch(/ensure-internal-testers/);
    expect(mjs).not.toMatch(/INTERNAL_GROUP_NAME/);
    const yml = read(".github/workflows/ios-ship.yml");
    expect(yml).not.toMatch(/ensure-internal-testers/);
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
    expect(branch).toMatch(/await deleteInternalGroups\(/);
    // Standing testers join the external group with createFirst: an email
    // whose only tester record belongs to another app of the team cannot be
    // related to this app's group (409 STATE_ERROR, seen live 2026-10-09),
    // so the external add must create this app's own betaTester record first.
    expect(branch).toMatch(/createFirst: true/);
    expect(mjs).toMatch(/export async function deleteInternalGroups\(/);
    expect(mjs).toMatch(/api\("DELETE", `\/v1\/betaGroups\/\$\{g\.id\}`\)/);
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



  it("ship-testflight.sh no longer claims internal testers can install", () => {
    const sh = read("scripts/ios-fleet/ship-testflight.sh");
    expect(sh).not.toMatch(/TestFlight internal testers can install this build/);
    expect(sh).toMatch(/TestFlight external testers can install this build after Beta App Review/);
    expect(sh).not.toMatch(/has no internal TestFlight tester/);
  });
});

// Behavior tests against a mock App Store Connect API.  These exercise the
// actual delete/readiness logic against external-group and public-link state,
// not string assertions.
const group = (id, name, internal, publicLink = false) => ({
  id,
  attributes: { name, isInternalGroup: internal, publicLinkEnabled: publicLink }
});
const listRes = (data) => ({ ok: true, status: 200, parsed: { data } });

describe("deleteInternalGroups behavior", () => {
  const logs = [];
  const log = (m) => logs.push(m);
  const warn = (m) => logs.push("WARN " + m);

  it("deletes every internal group and leaves external groups alone", async () => {
    const deleted = [];
    const api = vi.fn(async (method, path) => {
      if (method === "GET") return listRes([
        group("g-int", "Internal Testers", true),
        group("g-ext", "Public Beta", false)
      ]);
      if (method === "DELETE") { deleted.push(path); return { ok: true, status: 204, parsed: {} }; }
      throw new Error(`unexpected ${method} ${path}`);
    });
    const out = await deleteInternalGroups({ api, appId: "6817951255", log, warn });
    expect(out).toEqual({ deleted: 1, failed: 0 });
    expect(deleted).toEqual(["/v1/betaGroups/g-int"]);
  });

  it("treats an already-gone group (404) as deleted", async () => {
    const api = vi.fn(async (method) =>
      method === "GET" ? listRes([group("g1", "Internal Testers", true)]) : { ok: false, status: 404, parsed: {} });
    const out = await deleteInternalGroups({ api, appId: "6817951255", log, warn });
    expect(out).toEqual({ deleted: 1, failed: 0 });
  });

  it("leaves every group alone for an app outside the external-only set", async () => {
    const api = vi.fn(async () => { throw new Error("must not be called"); });
    const out = await deleteInternalGroups({ api, appId: "6798076688", log, warn });
    expect(out).toEqual({ deleted: 0, failed: 0 });
    expect(api).not.toHaveBeenCalled();
  });

  it("warns instead of throwing when the delete fails", async () => {
    const api = vi.fn(async (method) =>
      method === "GET" ? listRes([group("g1", "Internal Testers", true)]) : { ok: false, status: 500, parsed: { errors: [{ detail: "boom" }] } });
    const out = await deleteInternalGroups({ api, appId: "6817951255", log, warn });
    expect(out).toEqual({ deleted: 0, failed: 1 });
  });
});

describe("externalInstallability behavior", () => {
  it("is installable when an external group has a public link, even with zero testers", async () => {
    const api = vi.fn(async () => listRes([group("g1", "Public Beta", false, true)]));
    const out = await externalInstallability({ api, buildId: "b1" });
    expect(out).toMatchObject({ ok: true, installable: true });
    expect(api).toHaveBeenCalledTimes(1); // public link short-circuits the tester read
  });

  it("is installable when an external group has testers but no public link", async () => {
    const api = vi.fn(async (method, path) =>
      path.includes("/betaTesters")
        ? listRes([{ id: "t1", attributes: { email: "a@b.c" } }])
        : listRes([group("g1", "Public Beta", false, false)]));
    const out = await externalInstallability({ api, buildId: "b1" });
    expect(out).toMatchObject({ ok: true, installable: true });
  });

  it("is not installable when external groups have neither testers nor a public link", async () => {
    const api = vi.fn(async (method, path) =>
      path.includes("/betaTesters") ? listRes([]) : listRes([group("g1", "Public Beta", false, false)]));
    const out = await externalInstallability({ api, buildId: "b1" });
    expect(out).toMatchObject({ ok: true, installable: false });
  });

  it("is not installable when the build is in no external group (internal groups do not count)", async () => {
    const api = vi.fn(async () => listRes([group("g-int", "Internal Testers", true)]));
    const out = await externalInstallability({ api, buildId: "b1" });
    expect(out).toMatchObject({ ok: true, installable: false });
  });

  it("sees a later group's public link even when another group's tester read fails", async () => {
    const api = vi.fn(async (method, path) => {
      if (path.includes("/betaTesters")) return { ok: false, status: 500, parsed: { errors: [{ detail: "boom" }] } };
      return listRes([group("g-bad", "Public Beta", false, false), group("g-link", "Beta Link", false, true)]);
    });
    const out = await externalInstallability({ api, buildId: "b1" });
    expect(out).toMatchObject({ ok: true, installable: true });
    expect(out.detail).toContain("Beta Link");
  });

  it("counts a group with a missing isInternalGroup flag as external", async () => {
    const api = vi.fn(async () => listRes([{ id: "g1", attributes: { name: "Public Beta", publicLinkEnabled: true } }]));
    const out = await externalInstallability({ api, buildId: "b1" });
    expect(out).toMatchObject({ ok: true, installable: true });
  });

  it("reports ok:false instead of throwing when the transport itself throws", async () => {
    const api = vi.fn(async () => { throw new Error("socket hangup"); });
    const out = await externalInstallability({ api, buildId: "b1" });
    expect(out).toMatchObject({ ok: false, installable: false });
    expect(out.error).toContain("socket hangup");
  });

  it("reports ok:false when every tester read fails and no public link exists", async () => {
    const api = vi.fn(async (method, path) =>
      path.includes("/betaTesters")
        ? { ok: false, status: 500, parsed: { errors: [{ detail: "boom" }] } }
        : listRes([group("g1", "Public Beta", false, false)]));
    const out = await externalInstallability({ api, buildId: "b1" });
    expect(out).toMatchObject({ ok: false, installable: false });
  });

  it("reports ok:false when the read fails, which is not the same as uninstallable", async () => {
    const api = vi.fn(async () => ({ ok: false, status: 401, parsed: { errors: [{ detail: "denied" }] } }));
    const out = await externalInstallability({ api, buildId: "b1" });
    expect(out.ok).toBe(false);
    expect(out.installable).toBe(false);
  });
});
