import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";
import { MAX_QUOTA_BYTES, parseCodeCapsQuotas, readCodeCapsQuotas } from "../src/shared/codeCapsQuotas.ts";
import { handleQuotasRequest } from "../src/web/quotas-route.ts";

const now = Date.parse("2026-10-20T12:00:00Z");
const window = { id: "claude", provider: "Claude", label: "Weekly", planName: "Max", remainingUnknown: true, remainingPercent: 0, source: "local sign-in" };
const snapshot = (extra = {}) => ({ format: "usage-monitor-local-quotas", version: 1, generatedAt: new Date(now).toISOString(), windows: [window], ...extra });
const homes: string[] = [];
afterEach(() => { for (const home of homes.splice(0)) rmSync(home, { recursive: true, force: true }); });
function fixture() {
  const home = mkdtempSync(join(tmpdir(), "clutch-quotas-")); homes.push(home);
  const dir = join(home, "Library/Application Support/Usage Monitor"); mkdirSync(dir, { recursive: true });
  return { home, path: join(dir, "quota-windows.json") };
}
describe("CodeCaps consumption", () => {
  it("retains legacy detection and provenance without manufacturing unknown quota", () => {
    const result = parseCodeCapsQuotas(snapshot(), now);
    expect(result.available).toBe(true);
    expect(result.windows[0]).toMatchObject({ planName: "Max", source: "local sign-in", remainingUnknown: true });
    expect(result.windows[0]).not.toHaveProperty("remainingPercent");
    expect(result.windows[0]).not.toHaveProperty("planMetadata");
    const nonBoolean = parseCodeCapsQuotas(snapshot({ windows: [{ ...window, remainingUnknown: "true" }] }), now);
    expect(nonBoolean.windows[0]).not.toHaveProperty("remainingPercent");
  });
  it("round trips additive metadata and filters unknown fields and scalar types", () => {
    const planMetadata = { detectedPlanName: "Max", userPlanName: "Pro", userCostUsd: "20", userRenewalDateText: "November 1", userSubtitle: "Work", showCostAndRenewal: false, hasMismatch: true };
    const result = parseCodeCapsQuotas(snapshot({ windows: [{ ...window, credential: "never relay", planMetadata: { ...planMetadata, secret: "never relay" } }] }), now);
    expect(result.windows[0]?.planMetadata).toEqual(planMetadata);
    const longFields = { userSubtitle: "s".repeat(1024), userRenewalDateText: "r".repeat(512) };
    const longResult = parseCodeCapsQuotas(snapshot({ windows: [{ ...window, planMetadata: longFields }] }), now);
    expect(longResult.windows[0]?.planMetadata).toEqual(longFields);
    expect(JSON.stringify(result)).not.toContain("never relay");
    const bad = parseCodeCapsQuotas(snapshot({ windows: [{ ...window, planMetadata: { userPlanName: "x".repeat(257), userCostUsd: {}, hasMismatch: "true" } }] }), now);
    expect(bad.windows[0]?.planMetadata).toEqual({});
  });
  it("rejects malformed, unknown-version, oversized-array, stale and future snapshots", () => {
    for (const input of [null, [], snapshot({ version: 2 }), snapshot({ windows: [null] }), snapshot({ windows: Array(513).fill(window) }), snapshot({ generatedAt: new Date(now - 1_800_001).toISOString() }), snapshot({ generatedAt: new Date(now + 60_001).toISOString() })]) {
      expect(parseCodeCapsQuotas(input, now)).toMatchObject({ available: false, windows: [] });
    }
  });
  it("reads the fixed handoff path and gracefully handles absence, invalid JSON and oversize", async () => {
    const { home, path } = fixture();
    expect((await readCodeCapsQuotas(home, now)).available).toBe(false);
    writeFileSync(path, JSON.stringify(snapshot()));
    expect((await readCodeCapsQuotas(home, now)).available).toBe(true);
    writeFileSync(path, "{"); expect((await readCodeCapsQuotas(home, now)).available).toBe(false);
    writeFileSync(path, " ".repeat(MAX_QUOTA_BYTES + 1)); expect((await readCodeCapsQuotas(home, now)).available).toBe(false);
    rmSync(path); symlinkSync(join(home, "other"), path);
    expect((await readCodeCapsQuotas(home, now)).available).toBe(false);
  });
  it("protects the route and permits only read access", async () => {
    for (const [method, authorization, status] of [["GET", "", 401], ["GET", "Bearer wrong", 401], ["POST", "Bearer fixture", 405], ["GET", "Bearer fixture", 200]]) {
      let actual = 0; let body = ""; let reads = 0;
      const res = { writeHead(code: number) { actual = code; return this; }, end(value: string) { body = value; } } as unknown as ServerResponse;
      const req = { method, headers: { authorization } } as IncomingMessage;
      expect(await handleQuotasRequest(req, res, "/clutch/v1/quotas", "fixture", async () => { reads++; return parseCodeCapsQuotas(snapshot(), now); })).toBe(true);
      expect(actual).toBe(status); expect(reads).toBe(status === 200 ? 1 : 0);
      if (status === 200) expect(JSON.parse(body).windows[0].planName).toBe("Max");
      expect(await handleQuotasRequest(req, res, "/api", "fixture")).toBe(false);
    }
  });
});
