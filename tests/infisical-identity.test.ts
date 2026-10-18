import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  infisicalIdentityPath,
  readInfisicalIdentity,
  resolveInfisicalIdentity,
  summarizeInfisicalIdentity,
  writeInfisicalIdentity,
  type IdentityEnv,
} from "../src/shared/infisicalIdentity";

// =============================================================================
// infisicalIdentity — every test uses a scratch CLUTCH_HOME and fake values.
// No real credential is ever written, read, or logged here.
// =============================================================================

const CANONICAL_PROJECT = "077fd6f3-9f9b-438e-9b6f-5c69076cf36c";

let home = "";
let env: IdentityEnv;
let errors: string[];

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "clutch-identity-"));
  env = { CLUTCH_HOME: home };
  errors = [];
  vi.spyOn(console, "error").mockImplementation((line: unknown) => {
    errors.push(String(line));
  });
});

afterEach(() => {
  vi.restoreAllMocks();
});

function writeRaw(body: string, mode = 0o600): void {
  writeFileSync(join(home, "infisical.json"), body, { mode });
}

describe("infisicalIdentityPath", () => {
  it("resolves under $CLUTCH_HOME", () => {
    expect(infisicalIdentityPath(env)).toBe(join(home, "infisical.json"));
  });

  it("falls back to $HOME/.clutch when CLUTCH_HOME is unset", () => {
    expect(infisicalIdentityPath({ HOME: "/Users/someone" })).toBe(
      join("/Users/someone", ".clutch", "infisical.json"),
    );
  });
});

describe("readInfisicalIdentity", () => {
  it("returns undefined when the file is absent, without throwing", () => {
    expect(readInfisicalIdentity(env)).toBeUndefined();
  });

  it("returns undefined for malformed JSON", () => {
    writeRaw("{ not json");
    expect(readInfisicalIdentity(env)).toBeUndefined();
  });

  it("returns undefined for a non-object payload", () => {
    writeRaw('"just a string"');
    expect(readInfisicalIdentity(env)).toBeUndefined();
  });

  it("returns undefined when the client secret is missing, rather than half-authenticating", () => {
    writeRaw(JSON.stringify({ projectId: CANONICAL_PROJECT, clientId: "id-only" }));
    expect(readInfisicalIdentity(env)).toBeUndefined();
  });

  it("trims stored values", () => {
    writeRaw(JSON.stringify({ projectId: ` ${CANONICAL_PROJECT} `, clientId: " cid ", clientSecret: " secret " }));
    const identity = readInfisicalIdentity(env);
    expect(identity).toEqual({ projectId: CANONICAL_PROJECT, clientId: "cid", clientSecret: "secret" });
  });

  it("warns when the file is group or world readable", () => {
    writeRaw(JSON.stringify({ projectId: CANONICAL_PROJECT, clientId: "cid", clientSecret: "shh" }), 0o644);
    expect(readInfisicalIdentity(env)).toBeDefined();
    expect(errors.join("\n")).toContain("chmod 600");
  });

  it("stays silent at mode 600", () => {
    writeRaw(JSON.stringify({ projectId: CANONICAL_PROJECT, clientId: "cid", clientSecret: "shh" }), 0o600);
    readInfisicalIdentity(env);
    expect(errors).toEqual([]);
  });
});

describe("writeInfisicalIdentity", () => {
  it("round-trips through read", () => {
    writeInfisicalIdentity({ projectId: CANONICAL_PROJECT, clientId: "cid", clientSecret: "shh" }, env);
    expect(readInfisicalIdentity(env)).toEqual({
      projectId: CANONICAL_PROJECT,
      clientId: "cid",
      clientSecret: "shh",
    });
  });

  it("creates the file at mode 600", () => {
    writeInfisicalIdentity({ projectId: CANONICAL_PROJECT, clientId: "cid", clientSecret: "shh" }, env);
    expect(statSync(join(home, "infisical.json")).mode & 0o777).toBe(0o600);
  });

  it("tightens the mode of a pre-existing loose file", () => {
    writeRaw(JSON.stringify({ projectId: "p", clientId: "i", clientSecret: "s" }), 0o644);
    writeInfisicalIdentity({ projectId: CANONICAL_PROJECT, clientId: "cid", clientSecret: "shh" }, env);
    expect(statSync(join(home, "infisical.json")).mode & 0o777).toBe(0o600);
  });

  it("leaves no scratch file behind", () => {
    writeInfisicalIdentity({ projectId: CANONICAL_PROJECT, clientId: "cid", clientSecret: "shh" }, env);
    expect(readdirSync(home)).toEqual(["infisical.json"]);
  });

  it("creates the parent directory when it is missing", () => {
    const nested: IdentityEnv = { CLUTCH_HOME: join(home, "nested", "clutch") };
    writeInfisicalIdentity({ projectId: CANONICAL_PROJECT, clientId: "cid", clientSecret: "shh" }, nested);
    expect(readInfisicalIdentity(nested)?.clientId).toBe("cid");
  });

  it("never puts the secret in the thrown error", () => {
    // Make the destination a directory so the write genuinely fails.
    const failing: IdentityEnv = { CLUTCH_HOME: join(home, "afile") };
    mkdirSync(join(home, "afile", "infisical.json"), { recursive: true });
    let thrown = "";
    try {
      writeInfisicalIdentity({ projectId: "p", clientId: "i", clientSecret: "TOPSECRET" }, failing);
    } catch (error) {
      thrown = error instanceof Error ? error.message : String(error);
    }
    expect(thrown).toContain("failed to write");
    expect(thrown).not.toContain("TOPSECRET");
    // The scratch file must not survive a failed write.
    expect(readdirSync(join(home, "afile"))).toEqual(["infisical.json"]);
  });
});

describe("resolveInfisicalIdentity", () => {
  beforeEach(() => {
    writeInfisicalIdentity({ projectId: "file-project", clientId: "file-id", clientSecret: "file-secret" }, env);
  });

  it("prefers explicit environment values over the file", () => {
    const resolved = resolveInfisicalIdentity(
      { projectId: CANONICAL_PROJECT },
      { ...env, INFISICAL_CLIENT_ID: "env-id", INFISICAL_CLIENT_SECRET: "env-secret", INFISICAL_PROJECT_ID: "env-project" },
    );
    expect(resolved).toEqual({ projectId: "env-project", clientId: "env-id", clientSecret: "env-secret" });
  });

  it("falls back to the file when the environment is empty", () => {
    expect(resolveInfisicalIdentity({ projectId: CANONICAL_PROJECT }, env)).toEqual({
      projectId: "file-project",
      clientId: "file-id",
      clientSecret: "file-secret",
    });
  });

  it("uses the canonical project only when neither source supplies one", () => {
    const blank: IdentityEnv = { CLUTCH_HOME: join(home, "empty") };
    mkdirSync(join(home, "empty"));
    expect(resolveInfisicalIdentity({ projectId: CANONICAL_PROJECT }, blank).projectId).toBe(CANONICAL_PROJECT);
  });
});

describe("summarizeInfisicalIdentity", () => {
  const identity = { projectId: CANONICAL_PROJECT, clientId: "abcd1234efgh", clientSecret: "TOPSECRET" };

  it("never returns the client secret", () => {
    const summary = summarizeInfisicalIdentity(identity, {});
    expect(JSON.stringify(summary)).not.toContain("TOPSECRET");
    expect(summary.hasClientSecret).toBe(true);
  });

  it("reports an absent secret as absent", () => {
    expect(summarizeInfisicalIdentity({ ...identity, clientSecret: "" }, {}).hasClientSecret).toBe(false);
  });

  it("exposes only a short trailing client-id hint", () => {
    expect(summarizeInfisicalIdentity(identity, {}).clientIdHint).toBe("efgh");
  });

  it("flags values that came from the environment", () => {
    expect(summarizeInfisicalIdentity(identity, { INFISICAL_CLIENT_ID: "x" }).fromEnv).toBe(true);
    expect(summarizeInfisicalIdentity(identity, {}).fromEnv).toBe(false);
  });
});