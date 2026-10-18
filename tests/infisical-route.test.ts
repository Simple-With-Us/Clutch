import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, readFileSync, statSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { handleInfisicalSettingsRequest } from "../src/web/infisical-route";
import type { ClutchSettings } from "../src/shared/clutchSettings";

// =============================================================================
// infisical-route — the native settings panel's transport.
//
// The contract under test is the one that protects the machine secret: values
// never cross the wire, an empty secret never wipes a stored one, and a
// request that changes credentials cannot also write a setting under them.
// Fake credentials only; nothing here touches a real Infisical.
// =============================================================================

const PATH = "/clutch/v1/infisical";
const CANONICAL_PROJECT = "077fd6f3-9f9b-438e-9b6f-5c69076cf36c";
const SECRET_KEY = "MINIMAX_API_KEY";
const OPEN_KEY = "CLUTCH_MINIMAX_MODEL";

let home = "";
let env: NodeJS.ProcessEnv;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "clutch-route-"));
  env = { CLUTCH_HOME: home };
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

function makeReq(method: string, body?: unknown): IncomingMessage {
  const payload = body === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(body));
  return {
    method,
    headers: {},
    async *[Symbol.asyncIterator]() {
      if (payload.length > 0) yield payload;
    },
  } as unknown as IncomingMessage;
}

function makeRes() {
  const state = { status: 0, body: "" };
  const res = {
    writeHead(status: number) {
      state.status = status;
      return res;
    },
    end(body?: string) {
      state.body = body ?? "";
      return res;
    },
  };
  return { res: res as unknown as ServerResponse, state };
}

/** Minimal ClutchSettings stand-in; `set` records its calls. */
function makeSettings(overrides: Partial<ClutchSettings> = {}): ClutchSettings & { set: ReturnType<typeof vi.fn> } {
  const values: Record<string, string> = {
    [SECRET_KEY]: "shh",
    [OPEN_KEY]: "MiniMax-M2.7-highspeed",
  };
  const set = vi.fn(async () => {});
  return {
    source: "infisical",
    client: undefined,
    get: (key: string) => values[key] ?? "",
    has: (key: string) => (values[key] ?? "").length > 0,
    getAll: () => ({ ...values }),
    set,
    refresh: async () => {},
    stop: () => {},
    ...overrides,
  } as unknown as ClutchSettings & { set: ReturnType<typeof vi.fn> };
}

async function call(
  method: string,
  body?: unknown,
  settings: ClutchSettings = makeSettings(),
  pathname = PATH,
) {
  const { res, state } = makeRes();
  const handled = await handleInfisicalSettingsRequest(makeReq(method, body), res, pathname, { settings, env });
  return { handled, status: state.status, body: state.body ? JSON.parse(state.body) : undefined, raw: state.body };
}

describe("route matching", () => {
  it("ignores other paths", async () => {
    expect((await call("GET", undefined, makeSettings(), "/clutch/v1/health")).handled).toBe(false);
  });
});

describe("GET /clutch/v1/infisical", () => {
  it("reports the source and the identity file path", async () => {
    const { status, body } = await call("GET");
    expect(status).toBe(200);
    expect(body.source).toBe("infisical");
    expect(body.identityPath).toBe(join(home, "infisical.json"));
    expect(body.restartRequired).toBe(false);
  });

  it("returns the canonical project when no identity file exists", async () => {
    const { body } = await call("GET");
    expect(body.identity.projectId).toBe(CANONICAL_PROJECT);
    expect(body.identity.hasClientSecret).toBe(false);
  });

  it("never returns a secret value, only presence", async () => {
    const { raw } = await call("GET");
    const secretRow = JSON.parse(raw).keys.find((k: { key: string }) => k.key === SECRET_KEY);
    expect(secretRow.isSet).toBe(true);
    expect(secretRow.value).toBe("");
    expect(raw).not.toContain("shh");
  });

  it("returns the current value for non-secret keys", async () => {
    const { body } = await call("GET");
    const open = body.keys.find((k: { key: string }) => k.key === OPEN_KEY);
    expect(open.value).toBe("MiniMax-M2.7-highspeed");
    expect(open.kind).toBe("config");
  });
});

describe("PUT /clutch/v1/infisical — machine identity", () => {
  const identity = { projectId: "new-project", clientId: "new-id", clientSecret: "new-secret" };

  it("saves the identity at mode 600 and demands a restart", async () => {
    const { status, body } = await call("PUT", { identity });
    expect(status).toBe(200);
    expect(body.identitySaved).toBe(true);
    expect(body.restartRequired).toBe(true);
    const path = join(home, "infisical.json");
    expect(statSync(path).mode & 0o777).toBe(0o600);
    expect(JSON.parse(readFileSync(path, "utf8"))).toEqual(identity);
  });

  it("never echoes the submitted secret back", async () => {
    const { raw, body } = await call("PUT", { identity });
    expect(raw).not.toContain("new-secret");
    expect(body.identity.hasClientSecret).toBe(true);
  });

  it("keeps the stored secret when the field is submitted empty", async () => {
    await call("PUT", { identity });
    const { body } = await call("PUT", {
      identity: { projectId: "changed-project", clientId: "changed-id", clientSecret: "" },
    });
    expect(body.identitySaved).toBe(true);
    expect(JSON.parse(readFileSync(join(home, "infisical.json"), "utf8")).clientSecret).toBe("new-secret");
  });

  it("is a no-op save when nothing actually changed", async () => {
    await call("PUT", { identity });
    const { body } = await call("PUT", { identity });
    expect(body.identitySaved).toBe(false);
    expect(body.restartRequired).toBe(false);
  });

  it("rejects an identity with no credentials available", async () => {
    const { status, body } = await call("PUT", { identity: { projectId: "p" } });
    expect(status).toBe(400);
    expect(body.error).toContain("client ID");
  });

  it("rejects a non-object body", async () => {
    const { status } = await call("PUT", ["not", "an", "object"]);
    expect(status).toBe(400);
  });
});

describe("PUT /clutch/v1/infisical — managed setting write-through", () => {
  it("writes a non-secret key through to Infisical", async () => {
    const settings = makeSettings();
    const { status, body } = await call("PUT", { setting: { key: OPEN_KEY, value: "MiniMax-M3" } }, settings);
    expect(status).toBe(200);
    expect(settings.set).toHaveBeenCalledWith(OPEN_KEY, "MiniMax-M3");
    expect(body.settingSaved).toBe(OPEN_KEY);
    expect(body.restartRequired).toBe(false);
  });

  it("writes a secret key through without echoing the value", async () => {
    const settings = makeSettings();
    const { raw, body } = await call("PUT", { setting: { key: SECRET_KEY, value: "brand-new-secret" } }, settings);
    expect(settings.set).toHaveBeenCalledWith(SECRET_KEY, "brand-new-secret");
    expect(body.settingSaved).toBe(SECRET_KEY);
    expect(raw).not.toContain("brand-new-secret");
  });

  it("refuses an unknown key instead of forwarding it", async () => {
    const settings = makeSettings();
    const { status, body } = await call("PUT", { setting: { key: "NOT_A_REAL_KEY", value: "x" } }, settings);
    expect(status).toBe(400);
    expect(body.error).toContain("NOT_A_REAL_KEY");
    expect(settings.set).not.toHaveBeenCalled();
  });

  it("reports 503 when Infisical is not configured to accept writes", async () => {
    const settings = makeSettings({
      set: vi.fn(async () => {
        throw new Error('Infisical write-through failed for key "CLUTCH_MINIMAX_MODEL": Infisical is not configured');
      }),
    });
    const { status, body } = await call("PUT", { setting: { key: OPEN_KEY, value: "x" } }, settings);
    expect(status).toBe(503);
    expect(body.writeThrough).toBe(false);
    expect(body.key).toBe(OPEN_KEY);
  });

  it("refuses to change credentials and write a setting in one request", async () => {
    const settings = makeSettings();
    const { status, body } = await call(
      "PUT",
      {
        identity: { projectId: "p", clientId: "i", clientSecret: "s" },
        setting: { key: OPEN_KEY, value: "x" },
      },
      settings,
    );
    expect(status).toBe(409);
    expect(body.restartRequired).toBe(true);
    // The rejected request must not have saved half of itself.
    expect(settings.set).not.toHaveBeenCalled();
  });
});

describe("method handling", () => {
  it("rejects DELETE", async () => {
    const { status, handled } = await call("DELETE");
    expect(handled).toBe(true);
    expect(status).toBe(405);
  });
});