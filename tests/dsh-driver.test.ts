import { describe, expect, it } from "vitest";

import {
  STATIC_DSH_MODELS,
  DSH_MINIMUM_ACP_VERSION,
  DSH_PROVIDER_ID,
  DSH_MINIMAX_PROVIDER_ID,
  classifyDshError,
  dshModelIdFromOptionValue,
  dshModelOptionValue,
  dshProviderForModel,
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
    expect(value).toBe('["deepseek-official","deepseek-v4-flash"]');
    expect(dshModelIdFromOptionValue(value)).toBe("deepseek-v4-flash");

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
    expect(dshSupport.credentialEnv).toContain("HARNESS_RUNTIME_ROOT");
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

  it("throws when the harness reports a different effort", async () => {
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
