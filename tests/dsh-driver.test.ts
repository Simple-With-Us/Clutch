import { describe, expect, it } from "vitest";

import {
  STATIC_DSH_MODELS,
  DSH_MINIMUM_ACP_VERSION,
  DSH_PROVIDER_ID,
  DSH_MINIMAX_PROVIDER_ID,
  DSH_PER_MODEL_EFFORT_LEVELS,
  DSH_PROVIDER_DEFAULT_EFFORT,
  classifyDshError,
  dshEffortLevelsForModel,
  dshInstalledEffortLevels,
  dshModelIdFromOptionValue,
  dshModelOptionValue,
  dshPerModelEffortLevels,
  dshProviderForModel,
  dshReasoningEffortValue,
  dshSpawnArgs,
  dshSupport,
  dshVersionCompatibilityReason,
} from "../src/dsh/acp/driver.ts";

describe("dshSpawnArgs", () => {
  it("selects the published ACP profile", () => {
    expect(dshSpawnArgs({ cli: "dsh" }, { integrations: undefined })).toEqual(["--profile", "acp"]);
  });
});

describe("model option round-trip", () => {
  it("encodes and decodes a catalog id", () => {
    expect(dshProviderForModel("deepseek-v4-flash")).toBe(DSH_PROVIDER_ID);
    const value = dshModelOptionValue("deepseek-v4-flash");
    // Retired Flash spelling folds onto the preferred stock wire id when
    // nothing is advertised.
    expect(value).toBe('["deepseek-official","deepseek-flash"]');
    expect(dshModelIdFromOptionValue(value)).toBe("deepseek-flash");

    expect(dshProviderForModel("MiniMax-M3")).toBe(DSH_MINIMAX_PROVIDER_ID);
    const mmValue = dshModelOptionValue("MiniMax-M3");
    expect(mmValue).toBe('["minimax","MiniMax-M3"]');
    expect(dshModelIdFromOptionValue(mmValue)).toBe("MiniMax-M3");

    const mm27Value = dshModelOptionValue("MiniMax-M2.7");
    expect(mm27Value).toBe('["minimax","MiniMax-M2.7"]');
    expect(dshModelIdFromOptionValue(mm27Value)).toBe("MiniMax-M2.7");
  });

  it("rejects a foreign provider tuple", () => {
    expect(dshModelIdFromOptionValue(JSON.stringify(["other", "deepseek-v4-flash"]))).toBeNull();
  });
});

describe("version gate", () => {
  it("accepts 0.1.5-rc.1 and newer", () => {
    expect(dshVersionCompatibilityReason("0.1.5-rc.1")).toBeNull();
    expect(dshVersionCompatibilityReason("0.1.5-rc.2")).toBeNull();
  });

  it("rejects older stock dsh", () => {
    expect(dshVersionCompatibilityReason("0.1.4")).toMatch(/0\.1\.5-rc\.1/);
  });

  it("skips the gate for a custom wrapper", () => {
    expect(dshVersionCompatibilityReason("0.0.1", "dsh-acp.sh")).toBeNull();
  });
});

describe("classifyDshError", () => {
  it("maps auth, quota, outage, and catalog failures", () => {
    expect(classifyDshError(new Error("authentication required"))).toBe("invalid_credentials");
    expect(classifyDshError(new Error("inactive subscription"))).toBe("inactive_subscription");
    expect(classifyDshError(new Error("rate limit exceeded"))).toBe("quota_or_region_restriction");
    expect(classifyDshError(new Error("service unavailable"))).toBe("upstream_outage");
    expect(classifyDshError(new Error("model not found"))).toBe("model_catalog_outage");
    expect(classifyDshError(new Error("empty prompt"))).toBeUndefined();
  });
});

describe("dshSupport", () => {
  it("ships the current catalog and env contract", () => {
    expect(STATIC_DSH_MODELS.default).toBe("DeepSeek-V4.1-Flash");
    expect(STATIC_DSH_MODELS.options.map((option) => option.id)).toEqual([
      "DeepSeek-V4.1-Flash",
      "DeepSeek-V4.1-Pro",
      "MiniMax-M3",
      "MiniMax-M2.7-highspeed",
    ]);
    expect(DSH_MINIMUM_ACP_VERSION).toBe("0.1.5-rc.1");
    expect(dshSupport.driverKind).toBe("dshAgent");
    expect(dshSupport.credentialEnv).toContain("CLUTCH_RUNTIME_ROOT");
    expect(dshSupport.credentialEnv).toContain("CLUTCH_HOME");
    // Upstream-read (dsh-base cordis.patch.yml), so it keeps its name.
    expect(dshSupport.credentialEnv).toContain("DSH_PERMISSION_MODE");
    expect(dshSupport.mcpServers).toBe(true);
  });

  it("treats a bare set_config_option ACK as success", async () => {
    await expect(
      dshSupport.configureSession?.({
        request: async () => ({}),
        sessionId: "s1",
        turn: { text: "hi", effort: "high" },
      }),
    ).resolves.toBeUndefined();
  });

  it("throws when the engine reports a different effort", async () => {
    await expect(
      dshSupport.configureSession?.({
        request: async () => ({
          configOptions: [{ id: "reasoning_effort", currentValue: "max" }],
        }),
        sessionId: "s1",
        turn: { text: "hi", effort: "high" },
      }),
    ).rejects.toThrow(/still max/);
  });
});

describe("per-model effort levels", () => {
  type Call = { method: string; params: Record<string, unknown> };
  const recorder = (reply: (call: Call) => unknown = () => ({})) => {
    const calls: Call[] = [];
    const request = async (method: string, params: Record<string, unknown>) => {
      const call = { method, params };
      calls.push(call);
      return reply(call);
    };
    return { calls, request };
  };

  it("ships an empty per-model map now that the only entry (M3.1) is retired", () => {
    // BF-2494 (2026-10-18): MiniMax-M3.1-Flash-Preview was retired on the
    // MiniMax side and is gone from the static catalog.  The per-model
    // effort map is empty until a future model ships per-model effort.
    expect(DSH_PER_MODEL_EFFORT_LEVELS).toEqual({});
    expect(dshSupport.perModelEffortLevels).toBe(DSH_PER_MODEL_EFFORT_LEVELS);
  });

  it("only names rows the static catalog ships", () => {
    const ids = new Set(STATIC_DSH_MODELS.options.map((option) => option.id));
    for (const id of Object.keys(DSH_PER_MODEL_EFFORT_LEVELS)) expect(ids.has(id)).toBe(true);
  });

  it("keeps every other row on the engine-wide list", () => {
    expect(dshSupport.effortLevels).toEqual(["none", "high", "max"]);
    for (const id of ["DeepSeek-V4.1-Flash", "DeepSeek-V4.1-Pro", "MiniMax-M3", "MiniMax-M2.7-highspeed", "unknown"]) {
      expect(dshPerModelEffortLevels(id)).toBeUndefined();
      expect(dshEffortLevelsForModel(id)).toEqual(["none", "high", "max"]);
    }
    expect(dshPerModelEffortLevels(undefined)).toBeUndefined();
  });

  it("returns undefined for the retired M3.1 id (no per-model row to match)", () => {
    // Without a per-model row, the engine-wide list wins for any model id,
    // even one that used to have its own.  The case-insensitive lookup also
    // misses because the map is empty.
    expect(dshPerModelEffortLevels("MiniMax-M3.1-Flash-Preview")).toBeUndefined();
    expect(dshPerModelEffortLevels("minimax-m3.1-flash-preview")).toBeUndefined();
  });

  it("maps each turn to the reasoning_effort value it sends", () => {
    expect(dshReasoningEffortValue({ model: "DeepSeek-V4.1-Flash", effort: "none" })).toBe("off");
    expect(dshReasoningEffortValue({ model: "DeepSeek-V4.1-Flash" })).toBeUndefined();
    expect(dshReasoningEffortValue({ model: "MiniMax-M2.7-highspeed" })).toBeUndefined();
    expect(dshReasoningEffortValue({})).toBeUndefined();
    // The provider-default constant still clears a sticky level on a
    // resumed session for any model the engine eventually takes.
    expect(DSH_PROVIDER_DEFAULT_EFFORT).toBe("");
  });

  it("sends nothing for Default on a DeepSeek row", async () => {
    const { calls, request } = recorder();
    await dshSupport.configureSession?.({ request, sessionId: "s1", turn: { text: "hi", model: "DeepSeek-V4.1-Pro" } });
    expect(calls).toEqual([]);
  });

  it("treats a bare set_config_option ACK as success", async () => {
    await expect(
      dshSupport.configureSession?.({
        request: async () => ({}),
        sessionId: "s1",
        turn: { text: "hi", effort: "high" },
      }),
    ).resolves.toBeUndefined();
  });
});
