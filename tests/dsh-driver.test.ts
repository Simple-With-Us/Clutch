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
      "MiniMax-M3.1-Flash-Preview",
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
  const M31 = "MiniMax-M3.1-Flash-Preview";

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

  it("publishes low through max, with xhigh and without none, for MiniMax M3.1", () => {
    expect(DSH_PER_MODEL_EFFORT_LEVELS[M31]).toEqual(["low", "medium", "high", "xhigh", "max"]);
    expect(dshSupport.perModelEffortLevels).toBe(DSH_PER_MODEL_EFFORT_LEVELS);
    expect(dshSupport.perModelEffortLevels?.[M31]).not.toContain("none");
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

  it("matches a per-model row ignoring case", () => {
    expect(dshEffortLevelsForModel("minimax-m3.1-flash-preview")).toEqual(DSH_PER_MODEL_EFFORT_LEVELS[M31]);
  });

  it("maps each turn to the reasoning_effort value it sends", () => {
    expect(dshReasoningEffortValue({ model: M31, effort: "xhigh" })).toBe("xhigh");
    expect(dshReasoningEffortValue({ model: M31, effort: "max" })).toBe("max");
    expect(dshReasoningEffortValue({ model: M31 })).toBe(DSH_PROVIDER_DEFAULT_EFFORT);
    expect(DSH_PROVIDER_DEFAULT_EFFORT).toBe("");
    expect(dshReasoningEffortValue({ model: "DeepSeek-V4.1-Flash", effort: "none" })).toBe("off");
    expect(dshReasoningEffortValue({ model: "DeepSeek-V4.1-Flash" })).toBeUndefined();
    expect(dshReasoningEffortValue({ model: "MiniMax-M2.7-highspeed" })).toBeUndefined();
    expect(dshReasoningEffortValue({})).toBeUndefined();
  });

  it("sends xhigh to dsh for MiniMax M3.1", async () => {
    const { calls, request } = recorder(() => ({
      configOptions: [{ id: "reasoning_effort", currentValue: "xhigh" }],
    }));
    await dshSupport.configureSession?.({ request, sessionId: "s1", turn: { text: "hi", model: M31, effort: "xhigh" } });
    expect(calls).toEqual([
      { method: "session/set_config_option", params: { sessionId: "s1", configId: "reasoning_effort", value: "xhigh" } },
    ]);
  });

  it("clears a sticky level to the provider default when an M3.1 turn picks Default", async () => {
    const { calls, request } = recorder(() => ({
      configOptions: [{ id: "reasoning_effort", currentValue: "" }],
    }));
    await dshSupport.configureSession?.({ request, sessionId: "s1", turn: { text: "hi", model: M31 } });
    expect(calls).toEqual([
      { method: "session/set_config_option", params: { sessionId: "s1", configId: "reasoning_effort", value: "" } },
    ]);
  });

  it("never fails a turn when the engine refuses the provider default", async () => {
    const { calls, request } = recorder(() => {
      throw new Error("unknown reasoning effort for minimax/MiniMax-M3.1-Flash-Preview: ");
    });
    await expect(
      dshSupport.configureSession?.({ request, sessionId: "s1", turn: { text: "hi", model: M31 } }),
    ).resolves.toBeUndefined();
    expect(calls).toHaveLength(1);
  });

  it("still sends nothing for Default on a DeepSeek row", async () => {
    const { calls, request } = recorder();
    await dshSupport.configureSession?.({ request, sessionId: "s1", turn: { text: "hi", model: "DeepSeek-V4.1-Pro" } });
    expect(calls).toEqual([]);
  });

  it("still fails when an explicit M3.1 level does not take", async () => {
    const { request } = recorder(() => ({
      configOptions: [{ id: "reasoning_effort", currentValue: "high" }],
    }));
    await expect(
      dshSupport.configureSession?.({ request, sessionId: "s1", turn: { text: "hi", model: M31, effort: "max" } }),
    ).rejects.toThrow(/still high/);
  });
});
