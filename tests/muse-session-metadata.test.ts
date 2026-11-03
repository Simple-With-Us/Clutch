import { describe, expect, it } from "vitest";

import { modelMetadataFromMuseConfigOptions } from "../src/web/muse-session-metadata.ts";

describe("modelMetadataFromMuseConfigOptions", () => {
  it("uses the same raw and encoded selector decoder as contributor identity", () => {
    const model = "muse-wonder-full-1.0-contributor";
    const currentValue = `muse-model:${JSON.stringify(["meta%custom", "profile%custom", model])}`;
    expect(modelMetadataFromMuseConfigOptions([{ id: "model", currentValue }])).toEqual({ provider: "meta%custom", model });
    expect(modelMetadataFromMuseConfigOptions([{ id: "model", currentValue: `muse-model:${JSON.stringify([7, { profile: 42 }, model])}` }])).toEqual({ model });
  });
  it("reads the provider and model from Muse's qualified current value", () => {
    const currentValue = `muse-model:${encodeURIComponent(JSON.stringify(["meta", null, "muse-wonder-1.0"]))}`;
    expect(modelMetadataFromMuseConfigOptions([{ id: "model", currentValue }])).toEqual({
      provider: "meta",
      model: "muse-wonder-1.0",
    });
  });

  it("reports a bare model without inferring its provider", () => {
    expect(modelMetadataFromMuseConfigOptions([{ id: "model", currentValue: "muse-spark-1.3" }])).toEqual({
      model: "muse-spark-1.3",
    });
  });

  it("ignores missing, malformed, and unrelated options", () => {
    expect(modelMetadataFromMuseConfigOptions(null)).toBeNull();
    expect(modelMetadataFromMuseConfigOptions([{ id: "reasoningEffort", currentValue: "high" }])).toBeNull();
    expect(modelMetadataFromMuseConfigOptions([{ id: "model", currentValue: "muse-model:%5Bbroken" }])).toBeNull();
  });
});
