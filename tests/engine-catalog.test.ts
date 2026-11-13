import { afterEach, describe, expect, it, vi } from "vitest";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { execPath } from "node:process";
import { join } from "node:path";

import {
  buildEngineCatalog,
  engineCatalog,
  effortsFromConfigOptions,
  mergeMuseModels,
  modelsFromConfigOptions,
  probeEngineOptions,
  readMuseProviderCatalog,
  resetEngineCatalogCache,
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

afterEach(() => {
  vi.restoreAllMocks();
  resetEngineCatalogCache();
});

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

describe("probeEngineOptions", () => {
  it("does not treat a failed session/new as an initialized capability probe", async () => {
    const dir = mkdtempSync(join(tmpdir(), "clutch-acp-probe-"));
    const stub = join(dir, "probe-error.mjs");
    writeFileSync(stub, `#!/usr/bin/env node
import readline from "node:readline";
const lines = readline.createInterface({ input: process.stdin });
lines.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.id === 1) {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: 1, result: { agentCapabilities: { loadSession: true, sessionCapabilities: { list: {} } } } }) + "\\n");
  } else if (message.id === 2) {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: 2, error: { code: -32000, message: "session unavailable" } }) + "\\n");
  }
});
`);
    chmodSync(stub, 0o755);

    const result = await probeEngineOptions(stub, [], dir, "reasoningEffort", 2_000);
    expect(result).toEqual({ models: [], efforts: [], supportsThreads: false, initialized: false });
  });
});

describe("mergeMuseModels", () => {
  it("keeps the advertised models first and adds the provider ones after", () => {
    const merged = mergeMuseModels(
      [{ id: "muse-spark-1.3-contributor", label: "Muse Spark 1.3 Contributor", value: "muse-spark-1.3-contributor" }],
      [
        { id: "muse-wonder-1.0-contributor", label: "Muse Wonder 1.0 Contributor", value: "muse-wonder-1.0-contributor" },
        { id: "muse-spark-1.3-contributor", label: "Muse Spark 1.3 Contributor", value: "muse-spark-1.3-contributor" },
      ],
    );
    expect(merged.map((model) => model.id)).toEqual([
      "muse-spark-1.3-contributor",
      "muse-wonder-1.0-contributor",
    ]);
  });

  it("deduplicates by model id while preserving the advertised wire value and a distinct provider alternate", () => {
    const merged = mergeMuseModels(
      [{ id: "muse-spark-1.3-contributor", label: "Spark from ACP", value: 'muse-model:["meta","tbh","muse-spark-1.3-contributor"]' }],
      [{
        id: "muse-spark-1.3-contributor",
        label: "Muse Spark 1.3 Contributor",
        value: "muse-spark-1.3-contributor",
        altValue: 'muse-model:["meta","tbh","muse-spark-1.3-contributor"]',
      }],
    );

    expect(merged).toEqual([{
      id: "muse-spark-1.3-contributor",
      label: "Spark from ACP",
      value: 'muse-model:["meta","tbh","muse-spark-1.3-contributor"]',
      altValue: "muse-spark-1.3-contributor",
    }]);

    const multipleAdvertisedForms = mergeMuseModels(
      [
        { id: "muse-wonder-full-1.0-contributor", label: "Muse Wonder Full 1.0 Contributor", value: "muse-wonder-full-1.0-contributor" },
        { id: "muse-wonder-full-1.0-contributor", label: "Alternate form", value: 'muse-model:["meta","tbh","muse-wonder-full-1.0-contributor"]' },
      ],
      [],
    );
    expect(multipleAdvertisedForms).toEqual([{
      id: "muse-wonder-full-1.0-contributor",
      label: "Muse Wonder Full 1.0 Contributor",
      value: "muse-wonder-full-1.0-contributor",
      altValue: 'muse-model:["meta","tbh","muse-wonder-full-1.0-contributor"]',
    }]);

    const withProviderAlternate = mergeMuseModels(
      [{ id: "muse-wonder-1.0-contributor", label: "Wonder", value: "muse-wonder-1.0-contributor" }],
      [{
        id: "muse-wonder-1.0-contributor",
        label: "Muse Wonder 1.0 Contributor",
        value: "muse-wonder-1.0-contributor",
        altValue: 'muse-model:["meta","tbh","muse-wonder-1.0-contributor"]',
      }],
    );
    expect(withProviderAlternate).toHaveLength(1);
    expect(withProviderAlternate[0]).toMatchObject({
      value: "muse-wonder-1.0-contributor",
      altValue: 'muse-model:["meta","tbh","muse-wonder-1.0-contributor"]',
    });
  });
});

describe("readMuseProviderCatalog", () => {
  it("reads nothing when the catalog directory is absent", () => {
    expect(readMuseProviderCatalog("/nonexistent/home")).toEqual([]);
  });

  it("exposes only the supported contributor models with friendly labels and exact wire fallbacks", () => {
    const home = mkdtempSync(join(tmpdir(), "clutch-muse-provider-catalog-"));
    const directory = join(home, ".local", "share", "muse", "model-catalog");
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, "catalog.json"), JSON.stringify({ rows: [
      { model_id: "muse-wonder-full-1.0", display_label: "muse-wonder-full-1.0", provider_id: "meta", profile_id: "tbh", visibility: "visible" },
      { model_id: "muse-wonder-1.0", display_label: "muse-wonder-1.0", provider_id: "meta", profile_id: "tbh", visibility: "visible" },
      { model_id: "muse-spark-1.3", display_label: "muse-spark-1.3", provider_id: "meta", profile_id: "tbh", visibility: "visible" },
      { model_id: "muse-spark-1.3-contributor", display_label: "muse-spark-1.3-contributor", provider_id: "meta", profile_id: "tbh", visibility: "hidden" },
      { model_id: "muse-wonder-1.0-contributor", display_label: "muse-wonder-1.0-contributor", provider_id: "meta", profile_id: "tbh", visibility: "hidden" },
      { model_id: "muse-wonder-full-1.0-contributor", display_label: "muse-wonder-1.0-contributor", provider_id: "meta", profile_id: "tbh", visibility: "hidden" },
      { model_id: "muse-image-1.0", display_label: "Muse Image", visibility: "hidden" },
    ] }));

    try {
      const models = readMuseProviderCatalog(home);
      expect(models.map(({ id, label }) => [id, label])).toEqual([
        ["muse-spark-1.3-contributor", "Muse Spark 1.3 Contributor"],
        ["muse-wonder-1.0-contributor", "Muse Wonder 1.0 Contributor"],
        ["muse-wonder-full-1.0-contributor", "Muse Wonder Full 1.0 Contributor"],
      ]);
      expect(models.map(({ value }) => value)).toEqual(models.map(({ id }) => id));
      expect(models.map(({ altValue }) => altValue)).toEqual([
        'muse-model:["meta","tbh","muse-spark-1.3-contributor"]',
        'muse-model:["meta","tbh","muse-wonder-1.0-contributor"]',
        'muse-model:["meta","tbh","muse-wonder-full-1.0-contributor"]',
      ]);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
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
        zcode: { command: "zcode", args: ["acp"] },
      },
      // No probe runs here: the launchers are not executable in the test.
      available: { deepseek: true, minimax: true, mcode: false, muse: false, zcode: false },
      probeCwd: "/tmp",
      readMuseCatalog: () => [],
    });
    expect(catalog.engines.map((engine) => engine.id)).toEqual(["deepseek", "minimax", "mcode", "muse", "zcode"]);
    const deepseek = catalog.engines[0];
    expect(deepseek.available).toBe(true);
    expect(deepseek.models.map((model) => model.id)).toContain("DeepSeek-V4.1-Pro");
    expect(deepseek.effortConfigId).toBe("reasoning_effort");
    const muse = catalog.engines[3];
    expect(muse.available).toBe(false);
    expect(muse.effortConfigId).toBe("reasoningEffort");
    expect(muse.effortLevels).toEqual(["minimal", "low", "medium", "high", "xhigh"]);
  });

  it("never starts Muse on repeated catalog misses and exposes only the contributor allowlist", async () => {
    const dir = mkdtempSync(join(tmpdir(), "clutch-muse-catalog-passive-"));
    const marker = join(dir, "muse-started");
    const sentinel = join(dir, "muse");
    writeFileSync(sentinel, `#!${process.execPath}\nrequire("node:fs").writeFileSync(${JSON.stringify(marker)}, "started");\n`);
    chmodSync(sentinel, 0o755);
    const providerDirectory = join(dir, ".local", "share", "muse", "model-catalog");
    mkdirSync(providerDirectory, { recursive: true });
    writeFileSync(join(providerDirectory, "public-models.json"), JSON.stringify({ rows: [
      { model_id: "muse-local", display_label: "Local Muse Model", provider_id: "meta", profile_id: null },
      { model_id: "muse-hidden", visibility: "hidden" },
    ] }));
    const sources = {
      launchers: {
        deepseek: { command: "/unused", args: [] }, minimax: { command: "/unused", args: [] },
        mcode: { command: "/unused", args: [] }, muse: { command: sentinel, args: [] },
      },
      available: { deepseek: false, minimax: false, mcode: false, muse: true },
      probeCwd: dir,
      readMuseCatalog: () => readMuseProviderCatalog(dir),
    };
    try {
      for (let request = 0; request < 3; request += 1) {
        resetEngineCatalogCache();
        const catalog = await engineCatalog(sources);
        const muse = catalog.engines.find((entry) => entry.id === "muse")!;
        expect(muse.models.map((model) => model.id)).toEqual([
          "muse-spark-1.3-contributor",
          "muse-wonder-1.0-contributor",
          "muse-wonder-full-1.0-contributor",
        ]);
        expect(muse.models.some((model) => model.id === "muse-local" || model.id === "muse-hidden")).toBe(false);
        expect(muse.effortLevels).toEqual(["minimal", "low", "medium", "high", "xhigh"]);
      }
      expect(existsSync(marker)).toBe(false);
    } finally {
      resetEngineCatalogCache();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("offers only the exact known contributors with a base-only or empty provider catalog when Muse is available", async () => {
    const baseModels = [
      { id: "muse-spark-1.2", label: "Muse Spark 1.2", value: "muse-spark-1.2" },
      { id: "muse-wonder-1.0", label: "Muse Wonder 1.0", value: "muse-wonder-1.0" },
    ];
    const sources = (models: typeof baseModels) => ({
      launchers: {
        deepseek: { command: "/unused", args: [] }, minimax: { command: "/unused", args: [] },
        mcode: { command: "/unused", args: [] }, muse: { command: "/never-start-muse", args: [] },
      },
      available: { deepseek: false, minimax: false, mcode: false, muse: true },
      probeCwd: "/unused",
      readMuseCatalog: () => models,
      readMuseSessionOptions: () => null,
    });
    const contributorIds = [
      "muse-spark-1.3-contributor",
      "muse-wonder-1.0-contributor",
      "muse-wonder-full-1.0-contributor",
    ];

    const baseCatalog = await buildEngineCatalog(sources(baseModels));
    const baseMuse = baseCatalog.engines.find((engine) => engine.id === "muse")!;
    expect(baseMuse.models.map(({ id }) => id)).toEqual(contributorIds);
    expect(baseMuse.models.map(({ id, label, value }) => [id, label, value])).toEqual([
      ["muse-spark-1.3-contributor", "Muse Spark 1.3 Contributor", "muse-spark-1.3-contributor"],
      ["muse-wonder-1.0-contributor", "Muse Wonder 1.0 Contributor", "muse-wonder-1.0-contributor"],
      ["muse-wonder-full-1.0-contributor", "Muse Wonder Full 1.0 Contributor", "muse-wonder-full-1.0-contributor"],
    ]);

    resetEngineCatalogCache();
    const emptyCatalog = await buildEngineCatalog(sources([]));
    const emptyMuse = emptyCatalog.engines.find((engine) => engine.id === "muse")!;
    expect(emptyMuse.models.map(({ id }) => id)).toEqual(contributorIds);
    expect(emptyMuse.models.every(({ value, id }) => value === id)).toBe(true);
  });

  it("keeps advertised contributor wire values and provider alternates while dropping every base option", async () => {
    const options = [
      { id: "model", options: [
        { name: "Muse Spark 1.3 Contributor", value: 'muse-model:["meta","tbh","muse-spark-1.3-contributor"]' },
        { name: "Muse Wonder 1.0", value: "muse-wonder-1.0" },
        { name: "Muse Wonder 1.0 Contributor", value: "muse-wonder-1.0-contributor" },
      ] },
      { id: "reasoningEffort", options: [
        { value: "minimal" }, { value: "low" }, { value: "medium" }, { value: "high" },
        { value: "xhigh" }, { value: "max" },
      ] },
    ];
    const catalog = await buildEngineCatalog({
      launchers: {
        deepseek: { command: "/unused", args: [] }, minimax: { command: "/unused", args: [] },
        mcode: { command: "/unused", args: [] }, muse: { command: "/never-start-muse", args: [] },
      },
      available: { deepseek: false, minimax: false, mcode: false, muse: true },
      probeCwd: "/unused",
      readMuseCatalog: () => [
        { id: "muse-spark-1.3-contributor", label: "Spark provider", value: "muse-spark-1.3-contributor", altValue: 'muse-model:["meta","tbh","muse-spark-1.3-contributor"]' },
        { id: "muse-wonder-1.0-contributor", label: "Muse Wonder 1.0 Contributor", value: "muse-wonder-1.0-contributor", altValue: 'muse-model:["meta","tbh","muse-wonder-1.0-contributor"]' },
        { id: "muse-wonder-full-1.0-contributor", label: "Muse Wonder Full 1.0 Contributor", value: "muse-wonder-full-1.0-contributor", altValue: 'muse-model:["meta","tbh","muse-wonder-full-1.0-contributor"]' },
        { id: "muse-wonder-1.0", label: "Muse Wonder 1.0", value: "muse-wonder-1.0" },
      ],
      readMuseSessionOptions: () => options,
    });
    const muse = catalog.engines.find((engine) => engine.id === "muse")!;
    expect(muse.models.map(({ id }) => id)).toEqual([
      "muse-spark-1.3-contributor",
      "muse-wonder-1.0-contributor",
      "muse-wonder-full-1.0-contributor",
    ]);
    expect(muse.models[0]).toEqual({
      id: "muse-spark-1.3-contributor",
      label: "Muse Spark 1.3 Contributor",
      value: 'muse-model:["meta","tbh","muse-spark-1.3-contributor"]',
      altValue: "muse-spark-1.3-contributor",
    });
    expect(muse.models[1]).toMatchObject({
      value: "muse-wonder-1.0-contributor",
      altValue: 'muse-model:["meta","tbh","muse-wonder-1.0-contributor"]',
    });
    expect(muse.models[2]).toMatchObject({
      value: "muse-wonder-full-1.0-contributor",
      altValue: 'muse-model:["meta","tbh","muse-wonder-full-1.0-contributor"]',
    });
    expect(muse.effortConfigId).toBe("reasoningEffort");
    expect(muse.effortLevels).toEqual(["minimal", "low", "medium", "high", "xhigh"]);
  });

  it("publishes that every engine's threads can be listed and resumed", async () => {
    const catalog = await buildEngineCatalog({
      launchers: {
        deepseek: { command: "dsh", args: [] },
        minimax: { command: "minimax", args: [] },
        mcode: { command: "mcode", args: ["acp"] },
        muse: { command: "muse", args: [] },
        zcode: { command: "zcode", args: ["acp"] },
      },
      // An engine that is not installed here still lists its threads: the
      // capability belongs to the engine, not to this machine's copy of it.
      available: { deepseek: true, minimax: true, mcode: false, muse: false, zcode: false },
      probeCwd: "/tmp",
      readMuseCatalog: () => [],
    });
    expect(catalog.engines.map((engine) => engine.supportsThreads)).toEqual([true, true, true, true, true]);
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
    expect(mcode?.effortLevels).toEqual(["default", "low", "medium", "high", "xhigh", "max"]);
    expect(mcode?.supportsThreads).toBe(true);
  });
});

describe("engineCatalog provider caching", () => {
  it("keeps Muse passive while a cold probe is pending and shares full with mcode scope", async () => {
    const dir = mkdtempSync(join(tmpdir(), "clutch-catalog-scopes-"));
    const stub = join(dir, "slow-mcode.mjs");
    const marker = join(dir, "mcode-started");
    const count = join(dir, "mcode-count");
    const release = join(dir, "release-mcode-probe");
    writeFileSync(stub, `#!/usr/bin/env node
import readline from "node:readline";
import { appendFileSync, existsSync, writeFileSync } from "node:fs";
const lines = readline.createInterface({ input: process.stdin });
lines.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.id === 1) {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: 1, result: { agentCapabilities: { loadSession: true, sessionCapabilities: { list: {} } } } }) + "\\n");
  } else if (message.id === 2) {
    appendFileSync(${JSON.stringify(count)}, "probe\\n");
    writeFileSync(${JSON.stringify(marker)}, "started");
    const releaseProbe = setInterval(() => {
      if (!existsSync(${JSON.stringify(release)})) return;
      clearInterval(releaseProbe);
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: 2, result: { sessionId: "probe", configOptions: [
        { id: "model", options: [{ name: "M3.1", value: "m:minimax:MiniMax-M3.1:v:" }] },
        { id: "thinkingEffort", options: [{ value: "high" }] },
      ] } }) + "\\n");
    }, 10);
  } else if (message.id === 3) {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: 3, result: {} }) + "\\n");
  }
});
`);
    const sources = {
      launchers: {
        deepseek: { command: "/unused", args: [] }, minimax: { command: "/unused", args: [] },
        mcode: { command: execPath, args: [stub] }, muse: { command: "/never-start-muse", args: [] },
      },
      available: { deepseek: false, minimax: false, mcode: true, muse: true },
      probeCwd: dir,
    };
    let mcodeRequest: Promise<EngineCatalog> | undefined;
    let fullRequest: Promise<EngineCatalog> | undefined;
    try {
      let mcodeSettled = false;
      let fullSettled = false;
      const mcodeBuild = engineCatalog({ ...sources, probeScope: "mcode" }).finally(() => { mcodeSettled = true; });
      mcodeRequest = mcodeBuild;
      const deadline = Date.now() + 2_000;
      while (!existsSync(marker) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
      expect(existsSync(marker)).toBe(true);
      const fullBuild = engineCatalog(sources).finally(() => { fullSettled = true; });
      fullRequest = fullBuild;

      const passive = await engineCatalog({ ...sources, probeScope: "passive" });
      const muse = passive.engines.find((engine) => engine.id === "muse")!;
      expect(muse.models.map((model) => model.id).sort()).toEqual([
        "muse-spark-1.3-contributor", "muse-wonder-1.0-contributor", "muse-wonder-full-1.0-contributor",
      ].sort());
      expect(muse.effortLevels).toEqual(["minimal", "low", "medium", "high", "xhigh"]);
      expect(mcodeSettled).toBe(false);
      expect(fullSettled).toBe(false);

      writeFileSync(release, "continue");
      const [probed, full] = await Promise.all([mcodeBuild, fullBuild]);
      expect(probed.engines.find((engine) => engine.id === "mcode")?.models.map((model) => model.value))
        .toEqual(["m:minimax:MiniMax-M3.1:v:"]);
      expect(full.engines.find((engine) => engine.id === "mcode")?.models.map((model) => model.value))
        .toEqual(["m:minimax:MiniMax-M3.1:v:"]);
      expect((await engineCatalog({ ...sources, probeScope: "mcode" })).engines.find((engine) => engine.id === "mcode")?.models)
        .toEqual(probed.engines.find((engine) => engine.id === "mcode")?.models);
      await engineCatalog(sources);
      // The full and targeted scopes probe different engine sets, so each
      // builds its own entry once; later reads in either scope reuse it.
      expect(readFileSync(count, "utf8").trim().split("\n")).toHaveLength(2);
    } finally {
      writeFileSync(release, "continue");
      await Promise.allSettled([mcodeRequest, fullRequest].filter((request): request is Promise<EngineCatalog> => request !== undefined));
      resetEngineCatalogCache();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("keeps the full and targeted probe scopes in separate cache entries", async () => {
    resetEngineCatalogCache();
    const sources = {
      launchers: {
        deepseek: { command: "/unused", args: [] }, minimax: { command: "/unused", args: [] },
        mcode: { command: "/unused", args: [] }, muse: { command: "/never-start-muse", args: [] },
        zcode: { command: "/unused", args: ["acp"] },
      },
      available: { deepseek: false, minimax: false, mcode: false, muse: false, zcode: false },
      probeCwd: "/unused",
      readMuseCatalog: () => [],
    };
    try {
      const targeted = await engineCatalog({ ...sources, probeScope: "zcode", notes: { deepseek: "targeted build" } });
      const full = await engineCatalog({ ...sources, probeScope: "full", notes: { deepseek: "full build" } });
      expect(targeted.engines.find((engine) => engine.id === "deepseek")?.note).toBe("targeted build");
      expect(full.engines.find((engine) => engine.id === "deepseek")?.note).toBe("full build");
    } finally {
      resetEngineCatalogCache();
    }
  });

  it("reads provider data once per cache build while session options stay fresh across sequential and concurrent requests", async () => {
    let clock = 1_000;
    vi.spyOn(Date, "now").mockImplementation(() => clock);
    let provider = "muse-spark-1.3-contributor";
    let options: unknown = [
      { id: "model", options: [{ name: "muse-new", value: "wire-new" }] },
      { id: "reasoningEffort", options: [{ value: "high" }] },
    ];
    const readMuseCatalog = vi.fn(() => [{ id: provider, label: provider, value: provider }]);
    const sources = {
      launchers: {
        deepseek: { command: "/unused", args: [] }, minimax: { command: "/unused", args: [] },
        mcode: { command: "/unused", args: [] }, muse: { command: "/never-start-muse", args: [] },
      },
      available: { deepseek: false, minimax: false, mcode: false, muse: true },
      probeCwd: "/unused",
      readMuseCatalog,
      readMuseSessionOptions: () => options,
    };
    const muse = (catalog: EngineCatalog) => catalog.engines.find((engine) => engine.id === "muse")!;

    resetEngineCatalogCache();
    const cold = await Promise.all([engineCatalog(sources), engineCatalog(sources), engineCatalog(sources)]);
    expect(readMuseCatalog).toHaveBeenCalledTimes(1);
    for (const catalog of cold) {
      expect(muse(catalog).models.map((model) => model.id)).toEqual([
        "muse-spark-1.3-contributor",
        "muse-wonder-1.0-contributor",
        "muse-wonder-full-1.0-contributor",
      ]);
      expect(muse(catalog).effortLevels).toEqual(["minimal", "low", "medium", "high", "xhigh"]);
    }
    await engineCatalog(sources);
    expect(readMuseCatalog).toHaveBeenCalledTimes(1);

    options = [
      { id: "model", options: [{ name: "muse-loaded", value: "wire-loaded" }] },
      { id: "reasoningEffort", options: [{ value: "low" }] },
    ];
    sources.available.muse = false;
    provider = "muse-wonder-1.0-contributor";
    const cached = await Promise.all([engineCatalog(sources), engineCatalog(sources)]);
    expect(readMuseCatalog).toHaveBeenCalledTimes(1);
    for (const catalog of cached) {
      expect(muse(catalog).models.map((model) => model.id)).toEqual(["muse-spark-1.3-contributor"]);
      expect(muse(catalog).effortLevels).toEqual(["minimal", "low", "medium", "high", "xhigh"]);
      expect(muse(catalog).available).toBe(false);
    }

    clock += 5 * 60 * 1_000 + 1;
    const expired = await Promise.all([engineCatalog(sources), engineCatalog(sources)]);
    expect(readMuseCatalog).toHaveBeenCalledTimes(2);
    for (const catalog of expired) {
      expect(muse(catalog).models.map((model) => model.id)).toEqual(["muse-wonder-1.0-contributor"]);
    }

    resetEngineCatalogCache();
    provider = "muse-wonder-full-1.0-contributor";
    options = null;
    const reset = await engineCatalog(sources);
    expect(readMuseCatalog).toHaveBeenCalledTimes(3);
    expect(muse(reset).models.map((model) => model.id)).toEqual(["muse-wonder-full-1.0-contributor"]);
    expect(muse(reset).effortLevels).toEqual(["minimal", "low", "medium", "high", "xhigh"]);
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
          { id: "muse-wonder-1.0-contributor", label: "Muse Wonder 1.0 Contributor", value: "muse-wonder-1.0-contributor" },
          { id: "muse-spark-1.3-contributor", label: "Muse Spark 1.3 Contributor", value: "muse-model:[\"meta\",null,\"muse-spark-1.3-contributor\"]" },
        ],
        effortLevels: ["high"],
        effortConfigId: "reasoningEffort",
        modelConfigId: "model",
      },
    ],
  };

  it("maps a model id onto the exact wire value the engine wants", () => {
    expect(resolveModelValue(catalog, "muse", "muse-wonder-1.0-contributor")).toBe("muse-wonder-1.0-contributor");
    expect(resolveModelValue(catalog, "muse", "muse-spark-1.3-contributor")).toBe('muse-model:["meta",null,"muse-spark-1.3-contributor"]');
  });

  it("passes an unknown model through so a fresh model still works", () => {
    expect(resolveModelValue(catalog, "muse", "muse-brand-new")).toBe("muse-brand-new");
    expect(resolveModelValue(catalog, "muse", "  ")).toBe(null);
  });
});
