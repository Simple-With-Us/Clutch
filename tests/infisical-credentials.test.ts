import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { randomBytes } from "node:crypto";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, symlinkSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  infisicalCredentialsPath,
  readInfisicalCredentials,
  resolveInfisicalCredentials,
  summarizeInfisicalCredentials,
  writeInfisicalCredentials,
} from "../src/shared/infisicalCredentials.ts";

const PROJECT = "077fd6f3-9f9b-438e-9b6f-5c69076cf36c";
const READ = "st.fixture-read-token-value-123456789";
const WRITE = "st.fixture-write-token-value-123456789";
let home = "";
let errors: string[];

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "clutch-service-token-"));
  errors = [];
  vi.spyOn(console, "error").mockImplementation((line: unknown) => errors.push(String(line)));
});

afterEach(() => vi.restoreAllMocks());

function writeRaw(body: string, mode = 0o600): void {
  const path = join(home, "infisical.json");
  writeFileSync(path, body, { mode });
  chmodSync(path, mode);
}

describe("per-host service-token bootstrap", () => {
  it("uses the scoped Clutch home path", () => {
    expect(infisicalCredentialsPath({ CLUTCH_HOME: home })).toBe(join(home, "infisical.json"));
    expect(infisicalCredentialsPath({ HOME: "/Users/tester" })).toBe("/Users/tester/.clutch/infisical.json");
  });

  it("reads serviceToken and optional writeServiceToken without returning malformed data", () => {
    writeRaw(JSON.stringify({ projectId: PROJECT, serviceToken: ` ${READ} `, writeServiceToken: ` ${WRITE} ` }));
    expect(readInfisicalCredentials({ CLUTCH_HOME: home })).toEqual({ projectId: PROJECT, readToken: READ, writeToken: WRITE });
    writeRaw(JSON.stringify({ projectId: PROJECT, serviceToken: "not-a-service-token" }));
    expect(readInfisicalCredentials({ CLUTCH_HOME: home })).toBeUndefined();
  });

  it("rejects config that fails the strict credential-file schema", () => {
    for (const invalid of [
      null,
      [],
      { projectId: PROJECT },
      { projectId: 42, serviceToken: READ },
      { projectId: PROJECT, serviceToken: READ, clientSecret: "legacy" },
    ]) {
      writeRaw(JSON.stringify(invalid));
      expect(readInfisicalCredentials({ CLUTCH_HOME: home })).toBeUndefined();
    }
  });

  it("retains valid read access and clears malformed optional write tokens", () => {
    for (const writeServiceToken of [42, "not-a-service-token", "st.invalid token"]) {
      writeRaw(JSON.stringify({ projectId: PROJECT, serviceToken: READ, writeServiceToken }));
      expect(readInfisicalCredentials({ CLUTCH_HOME: home })).toEqual({
        projectId: PROJECT,
        readToken: READ,
        writeToken: "",
      });
      expect(resolveInfisicalCredentials({ projectId: PROJECT }, { CLUTCH_HOME: home })).toEqual({
        projectId: PROJECT,
        readToken: READ,
        writeToken: "",
      });
    }
  });

  it("refuses group/world-readable files and symlinks, and accepts private files", () => {
    writeRaw(JSON.stringify({ projectId: PROJECT, serviceToken: READ }), 0o644);
    expect(readInfisicalCredentials({ CLUTCH_HOME: home })).toBeUndefined();
    expect(errors.join("\n")).toContain("refusing to read service tokens");
    errors = [];
    writeRaw(JSON.stringify({ projectId: PROJECT, serviceToken: READ }), 0o600);
    expect(readInfisicalCredentials({ CLUTCH_HOME: home })).toBeDefined();
    expect(errors).toEqual([]);
    const target = join(home, "private-target.json");
    writeFileSync(target, JSON.stringify({ projectId: PROJECT, serviceToken: READ }), { mode: 0o600 });
    const path = join(home, "infisical.json");
    unlinkSync(path);
    symlinkSync(target, path);
    expect(readInfisicalCredentials({ CLUTCH_HOME: home })).toBeUndefined();
  });

  it("writes atomically with owner-only mode and replaces old identity fields", () => {
    writeRaw(JSON.stringify({ projectId: PROJECT, clientId: "legacy", clientSecret: "legacy-secret" }));
    writeInfisicalCredentials({ projectId: PROJECT, readToken: READ, writeToken: WRITE }, { CLUTCH_HOME: home });
    expect(statSync(join(home, "infisical.json")).mode & 0o777).toBe(0o600);
    const stored = JSON.parse(readFileSync(join(home, "infisical.json"), "utf8"));
    expect(stored).toEqual({ projectId: PROJECT, serviceToken: READ, writeServiceToken: WRITE });
    expect(readdirSync(home)).toEqual(["infisical.json"]);
  });

  it("creates a private parent directory when missing", () => {
    const nested = join(home, "nested", ".clutch");
    writeInfisicalCredentials({ projectId: PROJECT, readToken: READ, writeToken: "" }, { CLUTCH_HOME: nested });
    expect(statSync(nested).mode & 0o777).toBe(0o700);
    expect(readInfisicalCredentials({ CLUTCH_HOME: nested })).toEqual({ projectId: PROJECT, readToken: READ, writeToken: "" });
  });

  it("prefers explicit environment tokens and never includes token values in summaries", () => {
    writeInfisicalCredentials({ projectId: "file-project", readToken: READ, writeToken: WRITE }, { CLUTCH_HOME: home });
    const explicitReadToken = `st.${randomBytes(24).toString("hex")}`;
    const envOnlyReadToken = { CLUTCH_HOME: home, INFISICAL_TOKEN: explicitReadToken };
    expect(resolveInfisicalCredentials({ projectId: PROJECT }, envOnlyReadToken)).toEqual({
      projectId: PROJECT,
      readToken: explicitReadToken,
      writeToken: WRITE,
    });
    const env = { CLUTCH_HOME: home, INFISICAL_PROJECT_ID: "env-project", INFISICAL_TOKEN: "st.env-read-token-value-123456789" };
    const resolved = resolveInfisicalCredentials({ projectId: PROJECT }, env);
    expect(resolved).toEqual({ projectId: "env-project", readToken: env.INFISICAL_TOKEN, writeToken: WRITE });
    const summary = JSON.stringify(summarizeInfisicalCredentials(resolved, env));
    expect(summary).toContain("hasReadToken");
    expect(summary).not.toContain(READ);
    expect(summary).not.toContain(WRITE);
    expect(summary).not.toContain(env.INFISICAL_TOKEN);
  });

  it("rejects writes without a separate write service token", () => {
    expect(() => writeInfisicalCredentials({ projectId: PROJECT, readToken: READ, writeToken: "bad" }, { CLUTCH_HOME: home })).toThrow(/write service token is invalid/);
  });
});
