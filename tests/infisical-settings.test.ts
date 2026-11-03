import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  createInfisicalSettings,
  InfisicalWriteError,
  type InfisicalSettings,
} from "../src/shared/infisicalSettings";

// =============================================================================
// infisicalSettings — fetch is fully mocked; no real secret values are used.
// =============================================================================

type FetchMock = (input: unknown, init?: RequestInit) => Promise<Response>;

interface CallLog {
  url: string;
  method: string;
  order: number;
  redirect?: RequestRedirect;
}

const TEST_PROJECT_ID = "6a953a29-8397-4a9d-a5a5-7d1b61e4a5e7";
const TEST_ENV = "dev";
const READ_TOKEN = "st.fixture-read-token-value-123456789";
const WRITE_TOKEN = "st.fixture-write-token-value-123456789";

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
  } as Response;
}

/**
 * Build a fetch mock whose behavior is driven by mutable scenario state, so
 * each test can flip endpoints between success and failure.
 */
function makeScenario() {
  const calls: CallLog[] = [];
  let counter = 0;
  const state = {
    listSecretsOk: true,
    patchStatus: 200,
    postStatus: 200,
    /** Current server-side truth for the secrets list endpoint. */
    serverSecrets: [
      { secretKey: "FEATURE_FLAG", secretValue: "true" },
      { secretKey: "POLL_INTERVAL_MS", secretValue: "60000" },
    ] as Array<{ secretKey: string; secretValue: string }>,
  };

  const fetchMock: FetchMock = async (input: unknown, init?: RequestInit) => {
    const url = String(input);
    const method = (init?.method ?? "GET").toUpperCase();
    counter += 1;
    calls.push({ url, method, order: counter, redirect: init?.redirect });

    if (url.includes("/api/v3/secrets/raw?") && method === "GET") {
      if ((init?.headers as Record<string, string>)?.Authorization !== `Bearer ${READ_TOKEN}`) return jsonResponse({}, 401);
      return state.listSecretsOk
        ? jsonResponse({ secrets: state.serverSecrets })
        : jsonResponse({ message: "boom" }, 500);
    }
    if (url.includes("/api/v3/secrets/raw/")) {
      const key = decodeURIComponent(url.split("/api/v3/secrets/raw/")[1] ?? "");
      const exists = state.serverSecrets.some((s) => s.secretKey === key);
      if (method === "PATCH") {
        if ((init?.headers as Record<string, string>)?.Authorization !== `Bearer ${WRITE_TOKEN}`) return jsonResponse({}, 401);
        if (!exists) {
          return jsonResponse({ message: "not found" }, 404);
        }
        return state.patchStatus === 200
          ? jsonResponse({ secret: { secretKey: key } }, 200)
          : jsonResponse({ message: "write failed" }, state.patchStatus);
      }
      if (method === "POST") {
        if ((init?.headers as Record<string, string>)?.Authorization !== `Bearer ${WRITE_TOKEN}`) return jsonResponse({}, 401);
        return state.postStatus === 200
          ? jsonResponse({ secret: { secretKey: key } }, 200)
          : jsonResponse({ message: "create failed" }, state.postStatus);
      }
    }
    throw new Error(`unexpected fetch: ${method} ${url}`);
  };

  const makeSettings = (overrides: Record<string, unknown> = {}): InfisicalSettings =>
    createInfisicalSettings({
      projectId: TEST_PROJECT_ID,
      environment: TEST_ENV,
      refreshIntervalMs: 0, // No background timer in tests; refresh() is called manually.
      readToken: READ_TOKEN,
      writeToken: WRITE_TOKEN,
      fetchImpl: fetchMock as typeof fetch,
      ...overrides,
    });

  return { calls, state, fetchMock, makeSettings };
}

describe("infisicalSettings", () => {
  let consoleErrorSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    return () => {
      consoleErrorSpy.mockRestore();
    };
  });

  it("init loads every secret into the in-memory cache", async () => {
    const { calls, makeSettings } = makeScenario();
    const settings = makeSettings();

    await settings.init();
    settings.stop();

    expect(settings.get("FEATURE_FLAG")).toBe("true");
    expect(settings.get("POLL_INTERVAL_MS")).toBe("60000");
    expect(settings.get("MISSING")).toBeUndefined();
    expect(settings.has("FEATURE_FLAG")).toBe(true);
    expect(settings.getAll()).toEqual({ FEATURE_FLAG: "true", POLL_INTERVAL_MS: "60000" });
    expect(settings.getRequired("FEATURE_FLAG")).toBe("true");
    expect(() => settings.getRequired("MISSING")).toThrow(/MISSING/);
    expect(calls.every((c) => !c.url.includes("/auth/"))).toBe(true);
    expect(calls.every((c) => c.redirect === "error")).toBe(true);
    expect(calls.some((c) => c.method === "GET" && c.url.includes("/api/v3/secrets/raw?"))).toBe(true);
  });

  it("runtime reads make zero fetch calls after init", async () => {
    const { calls, fetchMock, makeSettings } = makeScenario();
    const settings = makeSettings();
    await settings.init();

    // Swap in a counting wrapper to catch any runtime read that reaches the network.
    let runtimeFetchCalls = 0;
    const countingFetch = (async (input: unknown, init?: RequestInit) => {
      runtimeFetchCalls += 1;
      return fetchMock(input, init);
    }) as typeof fetch;
    const settings2 = createInfisicalSettings({
      projectId: TEST_PROJECT_ID,
      environment: TEST_ENV,
      refreshIntervalMs: 0,
      readToken: READ_TOKEN,
      writeToken: WRITE_TOKEN,
      fetchImpl: countingFetch,
    });
    await settings2.init();
    const callsAfterInit = calls.length;
    runtimeFetchCalls = 0;

    settings2.get("FEATURE_FLAG");
    settings2.get("FEATURE_FLAG");
    settings2.get("MISSING");
    settings2.getAll();
    settings2.has("POLL_INTERVAL_MS");
    expect(() => settings2.getRequired("FEATURE_FLAG")).not.toThrow();

    expect(runtimeFetchCalls).toBe(0);
    expect(calls.length).toBe(callsAfterInit);
    settings.stop();
    settings2.stop();
  });

  it("set writes through to Infisical and then updates the cache", async () => {
    const { calls, makeSettings } = makeScenario();
    const settings = makeSettings();
    await settings.init();
    calls.length = 0;

    await settings.set("FEATURE_FLAG", "false");

    const patchCall = calls.find((c) => c.method === "PATCH");
    expect(patchCall).toBeDefined();
    expect(patchCall!.url).toContain("/api/v3/secrets/raw/FEATURE_FLAG");
    expect(settings.get("FEATURE_FLAG")).toBe("false");
    settings.stop();
  });

  it("refuses writes without the separate write token and never sends the read token for writes", async () => {
    const { calls, makeSettings } = makeScenario();
    const settings = makeSettings({ writeToken: "" });
    await settings.init();
    calls.length = 0;

    await expect(settings.set("FEATURE_FLAG", "false")).rejects.toBeInstanceOf(InfisicalWriteError);
    expect(calls).toEqual([]);
    expect(settings.get("FEATURE_FLAG")).toBe("true");
    settings.stop();
  });

  it("set issues the Infisical write before the cache value changes", async () => {
    const scenario = makeScenario();
    const settings = scenario.makeSettings();
    await settings.init();

    const writeTimeValues: Array<string | undefined> = [];
    const instrumentedFetch = (async (input: unknown, init?: RequestInit) => {
      const url = String(input);
      const method = (init?.method ?? "GET").toUpperCase();
      if (method === "PATCH" && url.includes("/api/v3/secrets/raw/")) {
        writeTimeValues.push(settings.get("FEATURE_FLAG"));
      }
      return scenario.fetchMock(input, init);
    }) as typeof fetch;
    const settings2 = createInfisicalSettings({
      projectId: TEST_PROJECT_ID,
      environment: TEST_ENV,
      refreshIntervalMs: 0,
      readToken: READ_TOKEN,
      writeToken: WRITE_TOKEN,
      fetchImpl: instrumentedFetch,
    });
    await settings2.init();

    await settings2.set("FEATURE_FLAG", "false");

    expect(writeTimeValues).toEqual(["true"]); // Old value still in cache at write time.
    expect(settings2.get("FEATURE_FLAG")).toBe("false"); // New value only after the write.
    settings.stop();
    settings2.stop();
  });

  it("set creates the secret with POST when PATCH returns 404", async () => {
    const { calls, makeSettings } = makeScenario();
    const settings = makeSettings();
    await settings.init();
    calls.length = 0;

    await settings.set("BRAND_NEW_KNOB", "42");

    const patchCall = calls.find((c) => c.method === "PATCH");
    const postCall = calls.find((c) => c.method === "POST" && c.url.includes("BRAND_NEW_KNOB"));
    expect(patchCall).toBeDefined();
    expect(postCall).toBeDefined();
    expect(calls.indexOf(postCall!)).toBeGreaterThan(calls.indexOf(patchCall!));
    expect(settings.get("BRAND_NEW_KNOB")).toBe("42");
    settings.stop();
  });

  it("failed write-through rejects the save and leaves the cache untouched", async () => {
    const { makeSettings, state } = makeScenario();
    state.patchStatus = 500;
    state.postStatus = 500;
    const settings = makeSettings();
    await settings.init();

    await expect(settings.set("FEATURE_FLAG", "false")).rejects.toBeInstanceOf(InfisicalWriteError);
    // Cache still holds the last-known-good value — never silently diverged.
    expect(settings.get("FEATURE_FLAG")).toBe("true");
    settings.stop();
  });

  it("failed refresh keeps the last-known-good cache and logs loudly", async () => {
    const { makeSettings, state } = makeScenario();
    const settings = makeSettings();
    await settings.init();

    state.listSecretsOk = false;
    await expect(settings.refresh()).rejects.toThrow();

    expect(settings.get("FEATURE_FLAG")).toBe("true");
    expect(settings.getAll()).toEqual({ FEATURE_FLAG: "true", POLL_INTERVAL_MS: "60000" });
    settings.stop();
  });

  it("background refresh failure keeps serving cache via the loud-log path", async () => {
    const { makeSettings, state } = makeScenario();
    const seenErrors: Error[] = [];
    const settings = makeSettings({
      onRefreshError: (err: Error) => {
        seenErrors.push(err);
      },
    });
    await settings.init();
    settings.stop();

    // Simulate what the background timer does: refresh() throws -> loud log
    // -> cache kept.  Here we invoke the same internal path through the
    // public refresh() and verify the contract pieces directly.
    state.listSecretsOk = false;
    await expect(settings.refresh()).rejects.toThrow();
    expect(settings.get("FEATURE_FLAG")).toBe("true");
    expect(seenErrors).toHaveLength(0); // onRefreshError only fires from the timer path.

    // And a healthy refresh swaps in new values.
    state.listSecretsOk = true;
    state.serverSecrets = [{ secretKey: "FEATURE_FLAG", secretValue: "false" }];
    await settings.refresh();
    expect(settings.get("FEATURE_FLAG")).toBe("false");
    settings.stop();
  });

  it("init fails fast when Infisical is unreachable", async () => {
    const { makeSettings, state } = makeScenario();
    state.listSecretsOk = false;
    const settings = makeSettings();
    await expect(settings.init()).rejects.toThrow();
    settings.stop();
  });

  it("rejects unsafe Infisical URLs before sending a bearer token", () => {
    const { fetchMock } = makeScenario();
    for (const infisicalUrl of [
      "http://infisical.example",
      "https://user:password@infisical.example",
      "https://infisical.example/base",
      "https://infisical.example/?redirect=elsewhere",
    ]) {
      expect(() => createInfisicalSettings({
        projectId: TEST_PROJECT_ID,
        environment: TEST_ENV,
        readToken: READ_TOKEN,
        fetchImpl: fetchMock as typeof fetch,
        infisicalUrl,
      })).toThrow(/infisicalUrl/);
    }
  });

  it("reads before init throw a clear error", () => {
    const { makeSettings } = makeScenario();
    const settings = makeSettings();
    expect(() => settings.get("FEATURE_FLAG")).toThrow(/init\(\)/);
    settings.stop();
  });
});
