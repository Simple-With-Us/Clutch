import { describe, it, expect } from "vitest";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";

// =============================================================================
// dsh-telemetry — Clutch keeps the dsh engine's telemetry row unmounted.
//
// The dsh base bundle mounts a `session-telemetry-otel` row that exports
// session events to DeepSeek's collector.  Upstream ships a kill switch:
// `apps/cli/src/profile-boot.ts` reads DSH_TELEMETRY_DISABLED, and
// `resolveTelemetryPatch()` turns the row off for ANY non-empty value —
// including "0" and "false" — so the row never mounts.
//
// The launcher turns it on, and the installed dsh build is the thing that has
// to honour it.  These tests check both ends: that Clutch exports the
// variable, and that the dsh it ships actually reads that name.
// =============================================================================

const LAUNCHER = resolve("scripts/lib/clutch-env.sh");
const DSH_LIB = resolve("node_modules/@deepseek-ai/dsh/lib");

describe("dsh telemetry — the launcher", () => {
  it("exports the kill switch with telemetry off by default", () => {
    const source = readFileSync(LAUNCHER, "utf8");
    expect(source).toMatch(/export DSH_TELEMETRY_DISABLED="\$\{DSH_TELEMETRY_DISABLED:-1\}"/);
  });

  it("says why, so the line is not mistaken for dead code", () => {
    const source = readFileSync(LAUNCHER, "utf8");
    expect(source).toContain("session-telemetry-otel");
    expect(source).toContain("resolveTelemetryPatch");
  });
});

describe("dsh telemetry — the installed build", () => {
  it("ships a lib directory to read", () => {
    expect(existsSync(DSH_LIB)).toBe(true);
  });

  it("reads the same environment variable Clutch exports", () => {
    const files = readdirSync(DSH_LIB).filter((name) => name.endsWith(".js"));
    const reads = files.some((name) =>
      readFileSync(join(DSH_LIB, name), "utf8").includes("DSH_TELEMETRY_DISABLED"),
    );
    expect(reads).toBe(true);
  });

  it("knows the telemetry row the switch targets", () => {
    const files = readdirSync(DSH_LIB).filter((name) => name.endsWith(".js"));
    const knows = files.some((name) =>
      readFileSync(join(DSH_LIB, name), "utf8").includes("session-telemetry-otel"),
    );
    expect(knows).toBe(true);
  });
});
