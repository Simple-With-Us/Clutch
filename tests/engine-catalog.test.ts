import { describe, expect, it } from "vitest";

import {
  buildEngineCatalog,
  effortsFromConfigOptions,
  mergeMuseModels,
  modelsFromConfigOptions,
  readMuseProviderCatalog,
  resolveModelValue,
  threadSupportFromInitialize,
  type EngineCatalog,
} from "../src/web/engine-catalog.ts";

const MCPRODE_OPTIONS = [
  {
    id: "permissionMode",
    type: "select",
    currentValue: "bypassPermissions",
    options: [{ value: "default", name: "Ask" }],
  },
  {
    id: "model",
    type: "select",
    currentValue: "m:minimax:MiniMax-M3.1-Flash:v:thinking",
    options: [
      { value: "m:minimax:MiniMax-M3.1-Flash:v:", name: "M3.1-Flash (Free)" },
      { value: "m:minimax:MiniMax-M3:v:", name: "M3" },
    ],
  },
  {
    id: "thinkingEffort",
    type: "select",
    currentValue: "default",
    options: [
      { value: "default", name: "Default" },
      { value: "high", name: "High" },
    ],
  },
];

describe("modelsFromConfigOptions", () => {
  it("reads the engine's own model choices in its order", () => {
    const models = modelsFromConfigOptions(MCPRODE_OPTIONS);
    expect(models.map((model) => model.id)).toEqual(["M3.1-Flash (Free)", "M3"]);
    expect(models[0].value).toBe("m:minimax:MiniMax-M3.1-Flash:v:");
  });

  it("returns nothing when the option is absent or malformed", () => {
    expect(modelsFromConfigOptions(undefined)).toEqual([]);
    expect(modelsFromConfigOptions([])).toEqual([]);
    expect(modelsFromConfigOptions([{ id: "model" }])).toEqual([]);
  });
});

describe("effortsFromConfigOptions", () => {
  it("reads the effort levels the engine accepts", () => {
    expect(effortsFromConfigOptions(MCPRODE_OPTIONS, "thinkingEffort")).toEqual(["default", "high"]);
    expect(effortsFromConfigOptions(MCPRODE_OPTIONS, "reasoning_effort")).toEqual([]);
  });
});

describe("threadSupportFromInitialize", () => {
  it("requires both ACP session listing and loading", () => {
    expect(threadSupportFromInitialize({
      agentCapabilities: { loadSession: true, sessionCapabilities: { list: {} } },
    })).toBe(true);
    expect(threadSupportFromInitialize({
      agentCapabilities: { loadSession: false, sessionCapabilities: { list: {} } },
    })).toBe(false);
    expect(threadSupportFromInitialize({
      agentCapabilities: { loadSession: true, sessionCapabilities: { additionalDirectories: {} } },
    })).toBe(false);
  });
});

describe("mergeMuseModels", () => {
  it("keeps the advertised models first and adds the provider ones after", () => {
    const merged = mergeMuseModels(
      [{ id: "muse-spark-1.2", label: "muse-spark-1.2", value: "muse-spark-1.2" }],
      [
        { id: "muse-wonder-1.0", label: "muse-wonder-1.0", value: "muse-wonder-1.0" },
        { id: "muse-spark-1.2", label: "muse-spark-1.2", value: "muse-spark-1.2" },
      ],
    );
    expect(merged.map((model) => model.id)).toEqual(["muse-spark-1.2", "muse-wonder-1.0"]);
  });
});

describe("readMuseProviderCatalog", () => {
  it("reads nothing when the catalog directory is absent", () => {
    expect(readMuseProviderCatalog("/nonexistent/home")).toEqual([]);
  });
});

describe("buildEngineCatalog", () => {
  it("lists every engine with its models and effort levels", async () => {
    const catalog = await buildEngineCatalog({
      launchers: {
        deepseek: { command: "dsh", args: [] },
        minimax: { command: "minimax", args: [] },
        mcode: { command: "mcode", args: ["acp"] },
        muse: { command: "muse", args: [] },
      },
      // No probe runs here: the launchers are not executable in the test.
      available: { deepseek: true, minimax: true, mcode: false, muse: false },
      probeCwd: "/tmp",
      readMuseCatalog: () => [],
    });
    expect(catalog.engines.map((engine) => engine.id)).toEqual(["deepseek", "minimax", "mcode", "muse"]);
    const deepseek = catalog.engines[0];
    expect(deepseek.available).toBe(true);
    expect(deepseek.models.map((model) => model.id)).toContain("DeepSeek-V4.1-Pro");
    expect(deepseek.effortConfigId).toBe("reasoning_effort");
    const muse = catalog.engines[3];
    expect(muse.available).toBe(false);
    expect(muse.effortConfigId).toBe("reasoningEffort");
    expect(muse.effortLevels).toContain("ultra");
  });

  it("publishes that every engine's threads can be listed and resumed", async () => {
    const catalog = await buildEngineCatalog({
      launchers: {
        deepseek: { command: "dsh", args: [] },
        minimax: { command: "minimax", args: [] },
        mcode: { command: "mcode", args: ["acp"] },
        muse: { command: "muse", args: [] },
      },
      // An engine that is not installed here still lists its threads: the
      // capability belongs to the engine, not to this machine's copy of it.
      available: { deepseek: true, minimax: true, mcode: false, muse: false },
      probeCwd: "/tmp",
      readMuseCatalog: () => [],
    });
    expect(catalog.engines.map((engine) => engine.supportsThreads)).toEqual([true, true, true, true]);
  });

  it("notes when an engine advertised nothing", async () => {
    const catalog = await buildEngineCatalog({
      // A launcher that does not exist here, so the probe answers nothing no
      // matter which engines this machine really has installed.
      launchers: {
        deepseek: { command: "dsh", args: [] },
        minimax: { command: "minimax", args: [] },
        mcode: { command: "/nonexistent/mcode", args: ["acp"] },
        muse: { command: "muse", args: [] },
      },
      available: { deepseek: true, minimax: true, mcode: true, muse: false },
      probeCwd: "/tmp",
      readMuseCatalog: () => [],
    });
    const mcode = catalog.engines.find((engine) => engine.id === "mcode");
    expect(mcode?.models).toEqual([]);
    expect(mcode?.note).toContain("did not advertise");
  });
});

describe("resolveModelValue", () => {
  const catalog: EngineCatalog = {
    engines: [
      {
        id: "muse",
        label: "Muse Code",
        available: true,
        supportsThreads: true,
        models: [
          { id: "muse-wonder-1.0", label: "muse-wonder-1.0", value: "muse-wonder-1.0" },
          { id: "muse-spark-1.2", label: "muse-spark-1.2", value: "muse-model:[\"meta\",null,\"muse-spark-1.2\"]" },
        ],
        effortLevels: ["high"],
        effortConfigId: "reasoningEffort",
        modelConfigId: "model",
      },
    ],
  };

  it("maps a model id onto the exact wire value the engine wants", () => {
    expect(resolveModelValue(catalog, "muse", "muse-wonder-1.0")).toBe("muse-wonder-1.0");
    expect(resolveModelValue(catalog, "muse", "muse-spark-1.2")).toBe('muse-model:["meta",null,"muse-spark-1.2"]');
  });

  it("passes an unknown model through so a fresh model still works", () => {
    expect(resolveModelValue(catalog, "muse", "muse-brand-new")).toBe("muse-brand-new");
    expect(resolveModelValue(catalog, "muse", "  ")).toBe(null);
  });
});
