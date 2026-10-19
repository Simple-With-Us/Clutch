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
    // dsh-acp answers a value the route does not offer with invalid params,
    // and the ACP core copies the wire code onto the rejected Error.
    const { calls, request } = recorder(() => {
      throw Object.assign(new Error("Invalid params: unknown reasoning effort for minimax/MiniMax-M3.1-Flash-Preview: "), {
        code: -32602,
      });
    });
    await expect(
      dshSupport.configureSession?.({ request, sessionId: "s1", turn: { text: "hi", model: M31 } }),
    ).resolves.toBeUndefined();
    expect(calls).toEqual([
      { method: "session/set_config_option", params: { sessionId: "s1", configId: "reasoning_effort", value: "" } },
    ]);
  });

  it("surfaces any other failure of the provider-default request", async () => {
    // A timeout carries no wire code, and an internal error carries -32603:
    // neither is a refusal, so the turn must not run on a session in an unknown state.
    for (const failure of [
      new Error("session/set_config_option timed out after 20 s"),
      Object.assign(new Error("Internal error"), { code: -32603 }),
    ]) {
      const { request } = recorder(() => {
        throw failure;
      });
      await expect(
        dshSupport.configureSession?.({ request, sessionId: "s1", turn: { text: "hi", model: M31 } }),
      ).rejects.toBe(failure);
    }
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

  it("words the effort mismatch without naming an engine brand", async () => {
    const { request } = recorder(() => ({
      configOptions: [{ id: "reasoning_effort", currentValue: "high" }],
    }));
    await expect(
      dshSupport.configureSession?.({ request, sessionId: "s1", turn: { text: "hi", model: M31, effort: "max" } }),
    ).rejects.toThrow(/^Engine did not switch reasoning effort to max \(still high\)$/);
  });

  describe("installed levels", () => {
    const settingsWith = (entry: Record<string, unknown>, route = "minimax") => ({
      "llm-pi-ai": { providers: { [route]: { apiKeyEnv: "MINIMAX_API_KEY", models: [{ id: "MiniMax-M3", name: "MiniMax-M3" }, entry] } } },
    });
    const configured = {
      id: M31,
      name: M31,
      reasoningEfforts: { low: "low", medium: "medium", high: "high", xhigh: "xhigh", max: "max" },
      compat: { forceAdaptiveThinking: true },
    };

    it("offers every level an install's settings entry declares", () => {
      expect(dshInstalledEffortLevels(settingsWith(configured))).toEqual({ [M31]: ["low", "medium", "high", "xhigh", "max"] });
    });

    it("keeps only the declared levels, in picker order", () => {
      const partial = { ...configured, reasoningEfforts: { max: "max", low: "low" } };
      expect(dshInstalledEffortLevels(settingsWith(partial))[M31]).toEqual(["low", "max"]);
    });

    it("matches the entry ignoring case and accepts a top-level providers map", () => {
      const lower = { ...configured, id: M31.toLowerCase() };
      expect(dshInstalledEffortLevels({ providers: { minimax: { models: [lower] } } })[M31]).toEqual(DSH_PER_MODEL_EFFORT_LEVELS[M31]);
    });

    it("offers nothing unless the entry forces adaptive thinking", () => {
      // Without the flag pi-ai sends fixed token budgets, clamps xhigh and max to high,
      // and sends no output_config.effort, so the levels would not do what the picker says.
      const { compat: _compat, ...missing } = configured;
      expect(dshInstalledEffortLevels(settingsWith(missing))[M31]).toEqual([]);
      for (const compat of [
        { forceAdaptiveThinking: false },
        { forceAdaptiveThinking: "true" },
        { forceAdaptiveThinking: 1 },
        {},
        null,
        "forceAdaptiveThinking",
      ]) {
        expect(dshInstalledEffortLevels(settingsWith({ ...configured, compat }))[M31]).toEqual([]);
      }
      // Other compat keys do not stand in for it, and the flag still works beside them.
      expect(
        dshInstalledEffortLevels(settingsWith({ ...configured, compat: { forceAdaptiveThinking: true, other: false } }))[M31],
      ).toEqual(["low", "medium", "high", "xhigh", "max"]);
    });

    it("offers nothing when the install cannot take a level", () => {
      // The repo's minimax-headless profile declares M3.1 with reasoningEfforts: false.
      expect(dshInstalledEffortLevels(settingsWith({ id: M31, reasoningEfforts: false }))[M31]).toEqual([]);
      // An entry without reasoningEfforts is a non-reasoning model to dsh, since pi-ai does not catalog M3.1.
      expect(dshInstalledEffortLevels(settingsWith({ id: M31, name: M31 }))[M31]).toEqual([]);
      // Declared under another route: the driver sends ["minimax", id], which dsh refuses anyway.
      expect(dshInstalledEffortLevels(settingsWith(configured, "minimax-cn"))[M31]).toEqual([]);
      // Empty wire values are not levels.
      expect(dshInstalledEffortLevels(settingsWith({ id: M31, reasoningEfforts: { low: "", max: null } }))[M31]).toEqual([]);
      // No settings file, or a malformed one.
      for (const settings of [undefined, null, "text", [], { "llm-pi-ai": { providers: { minimax: { models: "x" } } } }]) {
        expect(dshInstalledEffortLevels(settings)).toEqual({ [M31]: [] });
      }
    });
  });
});
