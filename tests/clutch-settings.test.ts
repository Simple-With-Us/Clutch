import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  initClutchSettings,
  CLUTCH_SETTINGS_SCHEMA,
  isSecretSetting,
  type ClutchSettings,
} from "../src/shared/clutchSettings.ts";
import { createInfisicalSettings } from "../src/shared/infisicalSettings.ts";

// =============================================================================
// clutchSettings — no real Infisical, no real secret values.  process.env is
// snapshotted and restored around every test.
// =============================================================================

const MANAGED_KEYS = CLUTCH_SETTINGS_SCHEMA.map((d) => d.key);

const LOGIN_URL = "https://app.infisical.com/api/v1/auth/universal-auth/login";

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
  } as Response;
}

interface Scenario {
  fetchMock: (input: unknown, init?: RequestInit) => Promise<Response>;
  serverSecrets: Array<{ secretKey: string; secretValue: string }>;
  calls: string[];
  failLogin: boolean;
}

function makeScenario(): Scenario {
  const calls: string[] = [];
  const scenario: Scenario = {
    calls,
    failLogin: false,
    serverSecrets: [
      { secretKey: "CLUTCH_WEB_PORT", secretValue: "3199" },
      { secretKey: "MINIMAX_API_KEY", secretValue: "test-key-value" },
    ],
    fetchMock: (async (input: unknown, init?: RequestInit) => {
      const url = String(input);
      const method = (init?.method ?? "GET").toUpperCase();
      calls.push(`${method} ${url}`);
      if (url === LOGIN_URL && method === "POST") {
        return scenario.failLogin
          ? jsonResponse({ message: "unauthorized" }, 401)
          : jsonResponse({ accessToken: "test-access-token" });
      }
      if (url.includes("/api/v3/secrets/raw?") && method === "GET") {
        return jsonResponse({ secrets: scenario.serverSecrets });
      }
      if (url.includes("/api/v3/secrets/raw/") && method === "PATCH") {
        return jsonResponse({ secret: { secretKey: "x" } });
      }
      throw new Error(`unexpected fetch: ${method} ${url}`);
    }) as typeof fetch,
  };
  return scenario;
}

let savedEnv: Record<string, string | undefined>;
let consoleErrorSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  savedEnv = {};
  for (const key of [...MANAGED_KEYS, "INFISICAL_CLIENT_ID", "INFISICAL_CLIENT_SECRET", "CLUTCH_INFISICAL_ENV"]) {
    savedEnv[key] = process.env[key];
    delete process.env[key];
  }
  consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  for (const [key, value] of Object.entries(savedEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  consoleErrorSpy.mockRestore();
  vi.unstubAllGlobals();
});

describe("clutchSettings", () => {
  it("schema covers every managed key exactly once", () => {
    const keys = CLUTCH_SETTINGS_SCHEMA.map((d) => d.key);
    expect(new Set(keys).size).toBe(keys.length);
    expect(keys).toContain("MINIMAX_API_KEY");
    expect(keys).toContain("DEEPSEEK_API_KEY");
    expect(keys).toContain("CLUTCH_WEB_PORT");
    expect(keys).toContain("CLUTCH_MINIMAX_MODEL");
    expect(isSecretSetting("MINIMAX_API_KEY")).toBe(true);
    expect(isSecretSetting("DEEPSEEK_API_KEY")).toBe(true);
    expect(isSecretSetting("CLUTCH_WEB_PORT")).toBe(false);
  });

  it("seeds from process.env with a loud warning when Infisical is unconfigured", async () => {
    process.env.CLUTCH_WEB_PORT = "4000";
    const settings = await initClutchSettings();
    try {
      expect(settings.source).toBe("env-seed");
      expect(settings.get("CLUTCH_WEB_PORT")).toBe("4000");
      // Schema default applies when neither env nor Infisical provides it.
      expect(settings.get("CLUTCH_WEB_HOST")).toBe("127.0.0.1");
      expect(consoleErrorSpy).toHaveBeenCalled();
      const warned = consoleErrorSpy.mock.calls.some((c) => String(c[0]).includes("INFISICAL_CLIENT_ID"));
      expect(warned).toBe(true);
    } finally {
      settings.stop();
    }
  });

  it("loads from Infisical and backfills process.env without clobbering explicit env", async () => {
    const scenario = makeScenario();
    vi.stubGlobal("fetch", scenario.fetchMock);
    process.env.INFISICAL_CLIENT_ID = "test-id";
    process.env.INFISICAL_CLIENT_SECRET = "test-secret";
    process.env.CLUTCH_WEB_HOST = "0.0.0.0"; // explicit env wins over Infisical

    const settings: ClutchSettings = await initClutchSettings();
    try {
      expect(settings.source).toBe("infisical");
      // Infisical value backfilled (was unset in env).
      expect(settings.get("CLUTCH_WEB_PORT")).toBe("3199");
      expect(process.env.CLUTCH_WEB_PORT).toBe("3199");
      // Explicit env wins over the backfill.
      expect(process.env.CLUTCH_WEB_HOST).toBe("0.0.0.0");
      expect(settings.get("CLUTCH_WEB_HOST")).toBe("0.0.0.0");
      // Secret from Infisical is readable via get() but backfilled into env.
      expect(settings.get("MINIMAX_API_KEY")).toBe("test-key-value");
      // Schema default for a key present nowhere.
      expect(settings.get("CLUTCH_MINIMAX_MODEL")).toBe("MiniMax-M2.7-highspeed");
    } finally {
      settings.stop();
    }
  });

  it("reads the prod environment by default", async () => {
    const scenario = makeScenario();
    vi.stubGlobal("fetch", scenario.fetchMock);
    process.env.INFISICAL_CLIENT_ID = "test-id";
    process.env.INFISICAL_CLIENT_SECRET = "test-secret";

    const settings = await initClutchSettings();
    try {
      const reads = scenario.calls.filter((c) => c.startsWith("GET") && c.includes("/api/v3/secrets/raw?"));
      expect(reads.length).toBeGreaterThan(0);
      expect(reads.every((c) => c.includes("environment=prod"))).toBe(true);
    } finally {
      settings.stop();
    }
  });

  it.each(["dev", "staging", "production"])(
    "ignores CLUTCH_INFISICAL_ENV=%s with a loud error and still reads prod",
    async (requested) => {
      const scenario = makeScenario();
      vi.stubGlobal("fetch", scenario.fetchMock);
      process.env.INFISICAL_CLIENT_ID = "test-id";
      process.env.INFISICAL_CLIENT_SECRET = "test-secret";
      process.env.CLUTCH_INFISICAL_ENV = requested;

      const settings = await initClutchSettings();
      try {
        expect(settings.source).toBe("infisical");
        const reads = scenario.calls.filter((c) => c.startsWith("GET") && c.includes("/api/v3/secrets/raw?"));
        expect(reads.length).toBeGreaterThan(0);
        expect(reads.every((c) => c.includes("environment=prod"))).toBe(true);
        expect(scenario.calls.some((c) => c.includes(`environment=${requested}`))).toBe(false);
        const warned = consoleErrorSpy.mock.calls.some(
          (c) => String(c[0]).includes("CLUTCH_INFISICAL_ENV") && String(c[0]).includes("ignored"),
        );
        expect(warned).toBe(true);
      } finally {
        settings.stop();
      }
    },
  );

  it("falls back to env seeding when the Infisical load fails", async () => {
    const scenario = makeScenario();
    scenario.failLogin = true;
    vi.stubGlobal("fetch", scenario.fetchMock);
    process.env.INFISICAL_CLIENT_ID = "test-id";
    process.env.INFISICAL_CLIENT_SECRET = "test-secret";
    process.env.CLUTCH_WEB_PORT = "4001";

    const settings = await initClutchSettings();
    try {
      expect(settings.source).toBe("env-seed");
      expect(settings.get("CLUTCH_WEB_PORT")).toBe("4001");
      expect(consoleErrorSpy).toHaveBeenCalled();
    } finally {
      settings.stop();
    }
  });

  it("set() writes through to Infisical before updating process.env", async () => {
    const scenario = makeScenario();
    vi.stubGlobal("fetch", scenario.fetchMock);
    process.env.INFISICAL_CLIENT_ID = "test-id";
    process.env.INFISICAL_CLIENT_SECRET = "test-secret";

    const settings = await initClutchSettings();
    try {
      scenario.calls.length = 0;
      await settings.set("CLUTCH_WEB_PORT", "3200");
      const patchIdx = scenario.calls.findIndex((c) => c.startsWith("PATCH") && c.includes("/api/v3/secrets/raw/CLUTCH_WEB_PORT"));
      expect(patchIdx).toBeGreaterThanOrEqual(0);
      expect(process.env.CLUTCH_WEB_PORT).toBe("3200");
      expect(settings.get("CLUTCH_WEB_PORT")).toBe("3200");
    } finally {
      settings.stop();
    }
  });

  it("set() refuses unknown keys and refuses in env-seed mode", async () => {
    const settings = await initClutchSettings(); // no creds -> env-seed
    try {
      await expect(settings.set("NOT_A_MANAGED_KEY", "x")).rejects.toThrow(/unknown key/);
      await expect(settings.set("CLUTCH_WEB_PORT", "1234")).rejects.toThrow(/not configured/);
      // process.env untouched by the refused writes.
      expect(process.env.CLUTCH_WEB_PORT).toBeUndefined();
    } finally {
      settings.stop();
    }
  });

  it("refresh() is a no-op in env-seed mode and re-backfills after Infisical refresh", async () => {
    const scenario = makeScenario();
    vi.stubGlobal("fetch", scenario.fetchMock);
    process.env.INFISICAL_CLIENT_ID = "test-id";
    process.env.INFISICAL_CLIENT_SECRET = "test-secret";

    const settings = await initClutchSettings();
    try {
      // Change the server-side value, then refresh.
      scenario.serverSecrets = [{ secretKey: "CLUTCH_WEB_PORT", secretValue: "3210" }];
      delete process.env.CLUTCH_WEB_PORT; // simulate: let the refresh re-backfill
      await settings.refresh();
      expect(settings.get("CLUTCH_WEB_PORT")).toBe("3210");
      expect(process.env.CLUTCH_WEB_PORT).toBe("3210");
    } finally {
      settings.stop();
    }

    // Env-seed mode: refresh() resolves without network.
    const seeded = await initClutchSettings();
    try {
      await expect(seeded.refresh()).resolves.toBeUndefined();
    } finally {
      seeded.stop();
    }
  });

  it("runtime reads make zero fetch calls after init", async () => {
    const scenario = makeScenario();
    let runtimeCalls = 0;
    const countingFetch = (async (input: unknown, init?: RequestInit) => {
      runtimeCalls += 1;
      return scenario.fetchMock(input, init);
    }) as typeof fetch;
    vi.stubGlobal("fetch", countingFetch);
    process.env.INFISICAL_CLIENT_ID = "test-id";
    process.env.INFISICAL_CLIENT_SECRET = "test-secret";

    const settings = await initClutchSettings();
    try {
      const callsAfterInit = scenario.calls.length;
      runtimeCalls = 0;
      for (const def of CLUTCH_SETTINGS_SCHEMA) {
        settings.get(def.key);
        settings.has(def.key);
      }
      settings.getAll();
      expect(runtimeCalls).toBe(0);
      expect(scenario.calls.length).toBe(callsAfterInit);
    } finally {
      settings.stop();
    }
  });

  it("vendored client is the fleet reference implementation", async () => {
    const scenario = makeScenario();
    const client = createInfisicalSettings({
      projectId: "077fd6f3-9f9b-438e-9b6f-5c69076cf36c",
      environment: "dev",
      refreshIntervalMs: 0,
      clientId: "test-id",
      clientSecret: "test-secret",
      fetchImpl: scenario.fetchMock as typeof fetch,
    });
    await client.init();
    try {
      expect(client.get("CLUTCH_WEB_PORT")).toBe("3199");
    } finally {
      client.stop();
    }
  });
});
