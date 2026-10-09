import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  enginePluginDirs,
  loadEnginePlugins,
  validateAcpSupport,
  validateEngineManifest,
  type EngineManifest,
} from "../src/shared/engines/index.ts";

const scratchDirs: string[] = [];

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), "clutch-engine-plugins-"));
  scratchDirs.push(dir);
  return dir;
}

function writePlugin(dir: string, name: string, contents: unknown): string {
  mkdirSync(dir, { recursive: true });
  const file = join(dir, name);
  writeFileSync(file, typeof contents === "string" ? contents : JSON.stringify(contents, null, 2));
  return file;
}

const VALID: EngineManifest = {
  $schema: "clutch.engine/v1",
  id: "acme",
  driverKind: "acmeAgent",
  displayName: "Acme",
  defaultCli: "acme-acp.sh",
  nativeSource: "acme.serve",
  models: { default: "acme-1", options: [{ id: "acme-1", label: "Acme 1" }] },
};

afterEach(() => {
  while (scratchDirs.length > 0) {
    rmSync(scratchDirs.pop() as string, { recursive: true, force: true });
  }
});

describe("manifest validation", () => {
  it("accepts a minimal well-formed manifest", () => {
    expect(validateEngineManifest(VALID)).toEqual([]);
  });

  it("names every required field", () => {
    const problems = validateEngineManifest({});
    expect(problems.join(" ")).toMatch(/id is required/);
    expect(problems.join(" ")).toMatch(/driverKind is required/);
    expect(problems.join(" ")).toMatch(/displayName is required/);
    expect(problems.join(" ")).toMatch(/defaultCli is required/);
    expect(problems.join(" ")).toMatch(/nativeSource is required/);
    expect(problems.join(" ")).toMatch(/models is required/);
  });

  it("rejects a default model that is not in the catalog", () => {
    // The classic silent bug: the picker cannot offer a model the engine would
    // then be sent by default.
    const problems = validateEngineManifest({ ...VALID, models: { default: "ghost", options: [{ id: "acme-1", label: "Acme 1" }] } });
    expect(problems.join(" ")).toMatch(/models\.default "ghost" is not in models\.options/);
  });

  it("rejects duplicate model ids and malformed ids", () => {
    expect(
      validateEngineManifest({ ...VALID, models: { default: "a", options: [{ id: "a", label: "A" }, { id: "a", label: "A again" }] } }).join(" "),
    ).toMatch(/repeats model id/);
    expect(validateEngineManifest({ ...VALID, id: "has space" }).join(" ")).toMatch(/must match/);
  });

  it("rejects an unknown schema instead of best-effort loading it", () => {
    expect(validateEngineManifest({ ...VALID, $schema: "clutch.engine/v99" }).join(" ")).toMatch(/\$schema is/);
  });

  it("rejects an invalid error rule pattern and an unknown code", () => {
    expect(validateEngineManifest({ ...VALID, errorRules: [{ pattern: "([", code: "upstream_outage" }] }).join(" ")).toMatch(
      /not a valid regular expression/,
    );
    expect(validateEngineManifest({ ...VALID, errorRules: [{ pattern: "x", code: "made_up" }] }).join(" ")).toMatch(
      /not a ProviderErrorCode/,
    );
  });

  it("rejects an effort level outside the shared contract", () => {
    // Muse offers `minimal` and `ultra`; Clutch's EffortLevel union has neither,
    // so a manifest claiming them is wrong rather than merely unfamiliar.
    expect(validateEngineManifest({ ...VALID, effortLevels: ["none", "ultra"] }).join(" ")).toMatch(/unknown effort level "ultra"/);
    expect(validateEngineManifest({ ...VALID, effortLevels: ["none", "xhigh"] })).toEqual([]);
  });

  it("rejects a selectModel that cannot produce a value", () => {
    expect(validateEngineManifest({ ...VALID, selectModel: { configId: "model" } }).join(" ")).toMatch(
      /needs one of advertised, values, or template/,
    );
  });

  it("reports non-objects without throwing", () => {
    expect(validateEngineManifest("nope")).toEqual(["manifest is not a JSON object"]);
    expect(validateEngineManifest(null)).toEqual(["manifest is not a JSON object"]);
    expect(validateEngineManifest([])).toEqual(["manifest is not a JSON object"]);
  });

  it("collects every problem at once rather than only the first", () => {
    const problems = validateEngineManifest({ id: "", models: { default: 1 } });
    expect(problems.length).toBeGreaterThan(2);
  });
});

describe("manifest to support mapping", () => {
  it("turns spawn args into a fresh array per call", async () => {
    const dir = scratch();
    writePlugin(dir, "acme.engine.json", { ...VALID, spawn: { args: ["--flag"] } });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const first = plugins[0]!.support.spawnArgs({ cli: "acme-acp.sh" }, {});
    first.push("mutated");
    expect(plugins[0]!.support.spawnArgs({ cli: "acme-acp.sh" }, {})).toEqual(["--flag"]);
  });

  it("omits optional keys the manifest does not declare", async () => {
    const dir = scratch();
    writePlugin(dir, "acme.engine.json", VALID);
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const { support } = plugins[0]!;
    expect(support.images).toBeUndefined();
    expect(support.mcpServers).toBeUndefined();
    expect(support.transformEnv).toBeUndefined();
    expect(support.classifyError).toBeUndefined();
    expect(support.selectModel).toBeUndefined();
  });

  it("prepends the system prompt unless the manifest says text only", async () => {
    const dir = scratch();
    writePlugin(dir, "joined.engine.json", { ...VALID, id: "joined" });
    writePlugin(dir, "plain.engine.json", { ...VALID, id: "plain", promptText: "text-only" });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const byId = new Map(plugins.map((plugin) => [plugin.id, plugin]));
    expect(byId.get("joined")!.support.buildPromptText!({ system: "sys", text: "hi" })).toBe("sys\n\nhi");
    expect(byId.get("plain")!.support.buildPromptText!({ system: "sys", text: "hi" })).toBe("hi");
  });

  it("omits transformEnv when the manifest sets no spawn env", async () => {
    const dir = scratch();
    writePlugin(dir, "envless.engine.json", { ...VALID, spawn: { args: [] } });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    expect(plugins[0]!.support.transformEnv).toBeUndefined();
  });

  it("applies spawn env through transformEnv, overriding the ambient value", async () => {
    const dir = scratch();
    writePlugin(dir, "envful.engine.json", { ...VALID, spawn: { env: { BACKEND: "sdk" } } });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const env: Record<string, string | undefined> = { BACKEND: "exec" };
    plugins[0]!.support.transformEnv!(env);
    expect(env.BACKEND).toBe("sdk");
  });

  it("leaves auth negotiation alone unless the manifest opts out", async () => {
    const dir = scratch();
    writePlugin(dir, "authy.engine.json", { ...VALID, id: "authy" });
    writePlugin(dir, "noauth.engine.json", { ...VALID, id: "noauth", noAuthNegotiation: true });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const byId = new Map(plugins.map((plugin) => [plugin.id, plugin]));
    expect(byId.get("authy")!.support.pickAuthMethod).toBeUndefined();
    expect(byId.get("noauth")!.support.pickAuthMethod!([{ id: "x" }])).toBeNull();
  });
});

describe("selectModel mapping", () => {
  it("sends the advertised value when asked", async () => {
    const dir = scratch();
    writePlugin(dir, "adv.engine.json", { ...VALID, selectModel: { configId: "model", advertised: true } });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const { selectModel } = plugins[0]!.support;
    expect(selectModel!.configId).toBe("model");
    expect(selectModel!.valueForModel("acme-1", "wire-value")).toBe("wire-value");
    // Nothing advertised means nothing to send, not the bare model id.
    expect(selectModel!.valueForModel("acme-1")).toBeNull();
  });

  it("maps exact values both ways", async () => {
    const dir = scratch();
    writePlugin(dir, "exact.engine.json", {
      ...VALID,
      selectModel: { configId: "model", values: { "acme-1": "wire:one" } },
    });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const { selectModel } = plugins[0]!.support;
    expect(selectModel!.valueForModel("acme-1")).toBe("wire:one");
    expect(selectModel!.modelForValue("wire:one")).toBe("acme-1");
    expect(selectModel!.modelForValue("unknown")).toBeNull();
  });

  it("applies a template and reverses it", async () => {
    const dir = scratch();
    writePlugin(dir, "tpl.engine.json", {
      ...VALID,
      selectModel: { configId: "model", template: "model/%model%" },
    });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const { selectModel } = plugins[0]!.support;
    expect(selectModel!.valueForModel("acme-1")).toBe("model/acme-1");
    expect(selectModel!.modelForValue("model/acme-1")).toBe("acme-1");
    expect(selectModel!.valueForModel("acme-2")).toBe("model/acme-2");
  });

  it("ignores non-string wire values", async () => {
    const dir = scratch();
    writePlugin(dir, "tpl2.engine.json", { ...VALID, selectModel: { configId: "model", template: "%model%" } });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    expect(plugins[0]!.support.selectModel!.modelForValue(42)).toBeNull();
  });

  it("reverses a template whose placeholder is the whole value", async () => {
    const dir = scratch();
    writePlugin(dir, "bare.engine.json", { ...VALID, selectModel: { configId: "model", template: "%model%" } });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const { selectModel } = plugins[0]!.support;
    expect(selectModel!.valueForModel("acme-1")).toBe("acme-1");
    expect(selectModel!.modelForValue("acme-1")).toBe("acme-1");
    expect(selectModel!.modelForValue("")).toBe("");
  });

  it("prefers the exact map when the host advertises nothing", async () => {
    const dir = scratch();
    writePlugin(dir, "both.engine.json", {
      ...VALID,
      selectModel: { configId: "model", advertised: true, values: { "acme-1": "wire:one" } },
    });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const { selectModel } = plugins[0]!.support;
    // No advertised value on a first turn must not silently drop the mapping.
    expect(selectModel!.valueForModel("acme-1")).toBe("wire:one");
    expect(selectModel!.valueForModel("acme-1", "host")).toBe("host");
  });
});

describe("error rule mapping", () => {
  it("classifies by message and code, first match winning", async () => {
    const dir = scratch();
    writePlugin(dir, "errs.engine.json", {
      ...VALID,
      errorRules: [
        { pattern: "unauthoriz", code: "invalid_credentials" },
        { pattern: "overloaded", code: "upstream_outage" },
      ],
    });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const { classifyError } = plugins[0]!.support;
    expect(classifyError!(new Error("401 Unauthorized"))).toBe("invalid_credentials");
    expect(classifyError!({ code: "overloaded_error" })).toBe("upstream_outage");
    expect(classifyError!(new Error("something else"))).toBeUndefined();
  });
});

describe("authenticatedWhen mapping", () => {
  it("treats any and all env names as written", async () => {
    const dir = scratch();
    writePlugin(dir, "anyenv.engine.json", { ...VALID, id: "anyenv", authenticatedWhen: { anyEnv: ["A", "B"] } });
    writePlugin(dir, "allenv.engine.json", { ...VALID, id: "allenv", authenticatedWhen: { allEnv: ["A", "B"] } });
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    const byId = new Map(plugins.map((plugin) => [plugin.id, plugin]));
    const any = byId.get("anyenv")!.support.isAuthenticated!;
    const all = byId.get("allenv")!.support.isAuthenticated!;
    expect(any({ A: "x" })).toBe(true);
    expect(any({})).toBe(false);
    expect(all({ A: "x", B: "" })).toBe(false);
    expect(all({ A: "x", B: "y" })).toBe(true);
  });

  it("is absent when nothing was declared", async () => {
    const dir = scratch();
    writePlugin(dir, "noauthenv.engine.json", VALID);
    const { plugins } = await loadEnginePlugins({ dirs: [dir] });
    expect(plugins[0]!.support.isAuthenticated).toBeUndefined();
  });
});

describe("discovery", () => {
  it("loads a manifest and reports no problems", async () => {
    const dir = scratch();
    writePlugin(dir, "acme.engine.json", VALID);
    const result = await loadEnginePlugins({ dirs: [dir] });
    expect(result.problems).toEqual([]);
    expect(result.plugins.map((plugin) => plugin.id)).toEqual(["acme"]);
    expect(result.plugins[0]!.kind).toBe("manifest");
  });

  it("lets a later directory override an earlier id and records the shadowed file", async () => {
    const bundled = scratch();
    const user = scratch();
    writePlugin(bundled, "acme.engine.json", { ...VALID, displayName: "Bundled" });
    writePlugin(user, "acme.engine.json", { ...VALID, displayName: "Local" });
    const result = await loadEnginePlugins({ dirs: [bundled, user] });
    expect(result.plugins).toHaveLength(1);
    expect(result.plugins[0]!.support.displayName).toBe("Local");
    expect(result.plugins[0]!.origin).toBe("user");
    expect(result.superseded).toEqual([join(bundled, "acme.engine.json")]);
  });

  it("treats a duplicate id inside one directory as a conflict, not an override", async () => {
    const dir = scratch();
    writePlugin(dir, "a-one.engine.json", { ...VALID, id: "dup", displayName: "First" });
    writePlugin(dir, "b-two.engine.json", { ...VALID, id: "dup", displayName: "Second" });
    const result = await loadEnginePlugins({ dirs: [dir] });
    expect(result.plugins).toHaveLength(1);
    expect(result.plugins[0]!.support.displayName).toBe("First");
    expect(result.problems).toHaveLength(1);
    expect(result.problems[0]!.problems.join(" ")).toMatch(/duplicate engine id "dup"/);
  });

  it("keeps loading the good plugins when one file is broken", async () => {
    const dir = scratch();
    writePlugin(dir, "a-good.engine.json", VALID);
    writePlugin(dir, "b-broken.engine.json", "{ not json");
    writePlugin(dir, "c-invalid.engine.json", { ...VALID, id: "invalid", models: { default: "ghost", options: [] } });
    const result = await loadEnginePlugins({ dirs: [dir] });
    expect(result.plugins.map((plugin) => plugin.id)).toEqual(["acme"]);
    expect(result.problems).toHaveLength(2);
    expect(result.problems.map((problem) => problem.id).sort()).toEqual(["b-broken", "invalid"]);
    expect(result.problems[0]!.problems.join(" ")).toMatch(/invalid JSON|cannot read file/);
  });

  it("ignores files that are not plugins", async () => {
    const dir = scratch();
    writePlugin(dir, "acme.engine.json", VALID);
    writeFileSync(join(dir, "README.md"), "# not a plugin\n");
    writeFileSync(join(dir, "notes.json"), "{}");
    const result = await loadEnginePlugins({ dirs: [dir] });
    expect(result.plugins.map((plugin) => plugin.id)).toEqual(["acme"]);
    expect(result.problems).toEqual([]);
  });

  it("does not throw on a missing or unreadable directory", async () => {
    const result = await loadEnginePlugins({ dirs: [join(scratch(), "does-not-exist")] });
    expect(result.plugins).toEqual([]);
    expect(result.problems).toEqual([]);
  });

  it("sorts plugins by id for a stable listing", async () => {
    const dir = scratch();
    writePlugin(dir, "zebra.engine.json", { ...VALID, id: "zebra" });
    writePlugin(dir, "alpha.engine.json", { ...VALID, id: "alpha" });
    const result = await loadEnginePlugins({ dirs: [dir] });
    expect(result.plugins.map((plugin) => plugin.id)).toEqual(["alpha", "zebra"]);
  });

  it("loads a module plugin and reads its declared id", async () => {
    const dir = scratch();
    writeFileSync(
      join(dir, "modular.engine.mjs"),
      `export default {
         id: "from-module",
         driverKind: "modularAgent",
         displayName: "Modular",
         defaultCli: "modular.sh",
         nativeSource: "modular.serve",
         models: { default: "m", options: [{ id: "m", label: "M" }] },
         spawnArgs: () => [],
       };\n`,
    );
    const result = await loadEnginePlugins({ dirs: [dir] });
    expect(result.problems).toEqual([]);
    expect(result.plugins[0]!.id).toBe("from-module");
    expect(result.plugins[0]!.kind).toBe("module");
  });

  it("accepts a named `support` export as well as default", async () => {
    const dir = scratch();
    writeFileSync(
      join(dir, "named.engine.mjs"),
      `export const support = {
         driverKind: "namedAgent",
         displayName: "Named",
         defaultCli: "named.sh",
         nativeSource: "named.serve",
         models: { default: "m", options: [{ id: "m", label: "M" }] },
         spawnArgs: () => [],
       };\n`,
    );
    const result = await loadEnginePlugins({ dirs: [dir] });
    expect(result.problems).toEqual([]);
    expect(result.plugins[0]!.support.driverKind).toBe("namedAgent");
  });

  it("reports a module that fails to import without taking down the rest", async () => {
    const dir = scratch();
    writePlugin(dir, "a-good.engine.json", VALID);
    writeFileSync(join(dir, "b-broken.engine.mjs"), "export default (;\n");
    const result = await loadEnginePlugins({ dirs: [dir] });
    expect(result.plugins.map((plugin) => plugin.id)).toEqual(["acme"]);
    expect(result.problems[0]!.problems.join(" ")).toMatch(/import failed/);
  });

  it("reports a module that exports the wrong shape", async () => {
    const dir = scratch();
    writeFileSync(join(dir, "empty.engine.mjs"), "export default { displayName: 'Incomplete' };\n");
    const result = await loadEnginePlugins({ dirs: [dir] });
    expect(result.plugins).toEqual([]);
    expect(result.problems[0]!.problems.join(" ")).toMatch(/driverKind is required/);
    expect(result.problems[0]!.problems.join(" ")).toMatch(/spawnArgs is required/);
  });
});

describe("validateAcpSupport", () => {
  it("requires the string fields, a catalog, and spawnArgs", () => {
    expect(validateAcpSupport(null)).toEqual(["module does not export an AcpSupport object"]);
    expect(validateAcpSupport({}).join(" ")).toMatch(/driverKind is required/);
    expect(validateAcpSupport({ driverKind: "a", displayName: "b", defaultCli: "c", nativeSource: "d" }).join(" ")).toMatch(
      /models is required/,
    );
    expect(
      validateAcpSupport({
        driverKind: "a",
        displayName: "b",
        defaultCli: "c",
        nativeSource: "d",
        models: { default: "m", options: [] },
      }).join(" "),
    ).toMatch(/spawnArgs is required/);
  });
});

describe("search path", () => {
  it("puts bundled plugins before per-machine drop-ins", () => {
    const dirs = enginePluginDirs({ CLUTCH_HOME: "/tmp/clutch-home-test" });
    expect(dirs).toHaveLength(2);
    expect(dirs[1]).toBe("/tmp/clutch-home-test/engines");
    expect(dirs[0]!.endsWith("engines")).toBe(true);
  });

  it("falls back to $HOME/.clutch when CLUTCH_HOME is unset", () => {
    expect(enginePluginDirs({ HOME: "/tmp/someone" })[1]).toBe("/tmp/someone/.clutch/engines");
  });
});