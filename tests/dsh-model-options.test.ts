import { describe, expect, it } from "vitest";

import {
  DshModelNotOfferedError,
  STATIC_DSH_MODELS,
  classifyDshError,
  dshModelIdFromOptionValue,
  dshModelOptionValue,
  dshSameModel,
  dshSupport,
  matchAdvertisedDshModel,
  parseAdvertisedDshModels,
  resolveDshModelOption,
} from "../src/dsh/acp/driver.ts";

// The shape `@deepseek-ai/dsh-acp` 0.1.5-rc.2 returns from session/new and
// session/resume: one `model` select whose options are grouped by provider,
// every value an opaque `JSON.stringify([provider, modelId])`.
function route(provider: string, id: string): string {
  return JSON.stringify([provider, id]);
}

function advertise(
  groups: Record<string, Array<[id: string, name: string]>>,
  current?: string,
): unknown[] {
  const options = Object.entries(groups).map(([provider, models]) => ({
    group: provider,
    name: provider,
    options: models.map(([id, name]) => ({ value: route(provider, id), name })),
  }));
  return [
    {
      id: "model",
      name: "Model",
      category: "model",
      type: "select",
      currentValue: current ?? options[0]?.options[0]?.value,
      options,
    },
    { id: "reasoning_effort", name: "Reasoning effort", type: "select", currentValue: "high", options: [] },
  ];
}

/** dsh's own lookup: an exact-string hit in the set it advertised, else
 *  `unknown model option`.  The whole failure this lane fixes is a value that
 *  misses this set, so the tests hold every answer to it. */
function dshAccepts(advertised: unknown[], value: string): boolean {
  return (parseAdvertisedDshModels(advertised) ?? []).some((entry) => entry.value === value);
}

/** A stock dsh 0.1.5-rc.2 catalog: `dsh-llm-deepseek`'s DEFAULT_MODELS. */
const STOCK = advertise({
  "deepseek-official": [
    ["deepseek-flash", "DeepSeek-V4.1-Flash"],
    ["deepseek-v4-pro", "DeepSeek-V4.1-Pro"],
  ],
  minimax: [
    ["MiniMax-M2.7", "MiniMax-M2.7"],
    ["MiniMax-M2.7-highspeed", "MiniMax-M2.7-Highspeed"],
    ["MiniMax-M3", "MiniMax-M3"],
  ],
});

/** The owner's Mac: `llm-deepseek.models` in settings.yaml replaces the stock
 *  list outright with these two. */
const OWNER_OVERRIDE = advertise({
  "deepseek-official": [
    ["deepseek-v4-pro", "deepseek-v4-pro-0813"],
    ["deepseek-v4.1-flash", "Deepseek-v4.1-flash"],
  ],
  minimax: [
    ["MiniMax-M2.7", "MiniMax-M2.7"],
    ["MiniMax-M2.7-highspeed", "MiniMax-M2.7-Highspeed"],
    ["MiniMax-M3", "MiniMax-M3"],
  ],
});

describe("the bug: a value built from the picker id is not one dsh advertised", () => {
  it("misses on the stock catalog, where the picker id is only a display name", () => {
    for (const id of ["DeepSeek-V4.1-Flash", "DeepSeek-V4.1-Pro"]) {
      const built = JSON.stringify(["deepseek-official", id]);
      expect(dshAccepts(STOCK, built), `${id} built`).toBe(false);
    }
  });

  it("misses on the owner's override catalog too", () => {
    for (const id of ["DeepSeek-V4.1-Flash", "DeepSeek-V4.1-Pro", "deepseek-v4-flash"]) {
      const built = JSON.stringify(["deepseek-official", id]);
      expect(dshAccepts(OWNER_OVERRIDE, built), `${id} built`).toBe(false);
    }
  });
});

describe("dshModelOptionValue resolves against what the session advertised", () => {
  it("sends the declared id on a stock catalog", () => {
    expect(dshModelOptionValue("DeepSeek-V4.1-Flash", STOCK)).toBe(route("deepseek-official", "deepseek-flash"));
    expect(dshModelOptionValue("DeepSeek-V4.1-Pro", STOCK)).toBe(route("deepseek-official", "deepseek-v4-pro"));
  });

  it("sends the declared id on the owner's override catalog", () => {
    expect(dshModelOptionValue("DeepSeek-V4.1-Flash", OWNER_OVERRIDE)).toBe(
      route("deepseek-official", "deepseek-v4.1-flash"),
    );
    // Neither the id nor the name of the override's Pro is the V4.1 spelling.
    expect(dshModelOptionValue("DeepSeek-V4.1-Pro", OWNER_OVERRIDE)).toBe(
      route("deepseek-official", "deepseek-v4-pro"),
    );
  });

  it("keeps saved pre-rename selections working on both catalogs", () => {
    // `deepseek-v4-flash` is declared by no current catalog; it must land on
    // whichever Flash the install declares.  `deepseek-v4-pro` is still a live
    // id and must not be treated as retired.
    expect(dshModelOptionValue("deepseek-v4-flash", STOCK)).toBe(route("deepseek-official", "deepseek-flash"));
    expect(dshModelOptionValue("deepseek-v4-flash", OWNER_OVERRIDE)).toBe(
      route("deepseek-official", "deepseek-v4.1-flash"),
    );
    expect(dshModelOptionValue("deepseek-v4-pro", STOCK)).toBe(route("deepseek-official", "deepseek-v4-pro"));
    expect(dshModelOptionValue("deepseek-v4-pro", OWNER_OVERRIDE)).toBe(route("deepseek-official", "deepseek-v4-pro"));
  });

  it("answers every catalog row that the install serves with a value dsh accepts", () => {
    const served = ["DeepSeek-V4.1-Flash", "DeepSeek-V4.1-Pro", "MiniMax-M3", "MiniMax-M2.7-highspeed"];
    for (const catalog of [STOCK, OWNER_OVERRIDE]) {
      for (const id of served) {
        expect(dshAccepts(catalog, dshModelOptionValue(id, catalog)), id).toBe(true);
      }
    }
  });

  it("matches a declared id ignoring case", () => {
    const catalog = advertise({ "deepseek-official": [["DeepSeek-V4.1-Flash", "Flash"]] });
    expect(resolveDshModelOption("deepseek-v4.1-flash", "deepseek-official", catalog)?.match).toBe("id");
  });

  it("prefers the exact declared value over a looser match", () => {
    const catalog = advertise({
      "deepseek-official": [
        ["deepseek-v4.1-flash", "DeepSeek-V4.1-Flash"],
        ["DeepSeek-V4.1-Flash", "Other"],
      ],
    });
    const resolved = resolveDshModelOption("DeepSeek-V4.1-Flash", "deepseek-official", catalog);
    expect(resolved?.match).toBe("exact");
    expect(resolved?.id).toBe("DeepSeek-V4.1-Flash");
  });

  it("reports how each id matched", () => {
    const how = (model: string, catalog: unknown[]) =>
      resolveDshModelOption(model, "deepseek-official", catalog)?.match;
    expect(how("deepseek-v4-pro", STOCK)).toBe("exact");
    expect(how("DeepSeek-V4.1-Flash", OWNER_OVERRIDE)).toBe("id");
    expect(how("DeepSeek-V4.1-Flash", STOCK)).toBe("name");
    expect(how("deepseek-v4-flash", STOCK)).toBe("alias");
  });

  it("accepts an ungrouped option list", () => {
    const flat = [
      {
        id: "model",
        type: "select",
        options: [
          { value: route("deepseek-official", "deepseek-flash"), name: "DeepSeek-V4.1-Flash" },
          { value: route("minimax", "MiniMax-M3"), name: "MiniMax-M3" },
        ],
      },
    ];
    expect(dshModelOptionValue("DeepSeek-V4.1-Flash", flat)).toBe(route("deepseek-official", "deepseek-flash"));
    expect(dshModelOptionValue("MiniMax-M3", flat)).toBe(route("minimax", "MiniMax-M3"));
  });

  it("tolerates human spellings of a DeepSeek model", () => {
    for (const spelling of ["DeepSeek V4.1 Flash", "DeepSeek-V41-Flash", "deepseek flash"]) {
      expect(dshModelOptionValue(spelling, STOCK), spelling).toBe(route("deepseek-official", "deepseek-flash"));
    }
  });
});

describe("provider namespaces stay separate", () => {
  it("never resolves a MiniMax id into the DeepSeek group", () => {
    const catalog = advertise({ "deepseek-official": [["MiniMax-M3", "MiniMax-M3"]] });
    expect(() => dshModelOptionValue("MiniMax-M3", catalog)).toThrow(DshModelNotOfferedError);
  });

  it("never resolves a DeepSeek id into the MiniMax group", () => {
    const catalog = advertise({
      minimax: [["deepseek-flash", "DeepSeek-V4.1-Flash"]],
      "deepseek-official": [["deepseek-v4-pro", "DeepSeek-V4.1-Pro"]],
    });
    expect(() => dshModelOptionValue("DeepSeek-V4.1-Flash", catalog)).toThrow(DshModelNotOfferedError);
  });
});

describe("a model the session does not offer", () => {
  it("fails before the switch and names what is offered", () => {
    let error: unknown;
    try {
      dshModelOptionValue("MiniMax-M3.1-Flash-Preview", OWNER_OVERRIDE);
    } catch (caught) {
      error = caught;
    }
    expect(error).toBeInstanceOf(DshModelNotOfferedError);
    const message = (error as Error).message;
    expect(message).toContain("MiniMax-M3.1-Flash-Preview");
    expect(message).toContain("MiniMax-M3");
    expect(message).toContain("deepseek-v4.1-flash");
    expect((error as DshModelNotOfferedError).offered).toHaveLength(5);
  });

  it("lists each offered model with its provider route", () => {
    let error: unknown;
    try {
      dshModelOptionValue("MiniMax-M3.1-Flash-Preview", OWNER_OVERRIDE);
    } catch (caught) {
      error = caught;
    }
    const offered = (error as DshModelNotOfferedError).offered;
    expect(offered).toContain("deepseek-official/deepseek-v4.1-flash (Deepseek-v4.1-flash)");
    expect(offered).toContain("minimax/MiniMax-M2.7-highspeed (MiniMax-M2.7-Highspeed)");
    // Id and name agree: no redundant parenthetical.
    expect(offered).toContain("minimax/MiniMax-M3");
    // Declared nowhere else, so there is no route hint.
    expect((error as DshModelNotOfferedError).elsewhere).toEqual([]);
    expect((error as Error).message).not.toContain("declared only under");
  });

  it("names the route when another provider declares the model", () => {
    // MiniMax-M3 exists, but only under a provider this bot does not route
    // through.  Sending it there would use another route's credentials and
    // billing, so it stays refused; the message must not read as a
    // contradiction next to a list that seems to contain it.
    const catalog = advertise({
      "deepseek-official": [["deepseek-flash", "DeepSeek-V4.1-Flash"]],
      "minimax-cn": [["MiniMax-M3", "MiniMax-M3"]],
    });
    let error: unknown;
    try {
      dshModelOptionValue("MiniMax-M3", catalog);
    } catch (caught) {
      error = caught;
    }
    expect(error).toBeInstanceOf(DshModelNotOfferedError);
    const typed = error as DshModelNotOfferedError;
    expect(typed.elsewhere).toEqual(["minimax-cn"]);
    expect(typed.offered).toContain("minimax-cn/MiniMax-M3");
    expect(typed.message).toContain("MiniMax-M3 is declared only under minimax-cn");
    expect(classifyDshError(typed)).toBe("model_catalog_outage");
  });

  it("lists every other provider once, matching on id or display name", () => {
    const catalog = advertise({
      "deepseek-official": [["deepseek-flash", "DeepSeek-V4.1-Flash"]],
      openrouter: [["glm-5", "GLM-5"], ["glm-5:free", "glm-5"]],
      zai: [["glm-5", "GLM-5"]],
    });
    let error: unknown;
    try {
      dshModelOptionValue("GLM-5", catalog);
    } catch (caught) {
      error = caught;
    }
    expect((error as DshModelNotOfferedError).elsewhere).toEqual(["openrouter", "zai"]);
  });

  it("classifies as a model-catalog outage so the fallback chain moves on", () => {
    const error = new DshModelNotOfferedError("x", ["a"]);
    expect(classifyDshError(error)).toBe("model_catalog_outage");
    // Also by message, for a caller that only kept the text.
    expect(classifyDshError(new Error(error.message))).toBe("model_catalog_outage");
  });

  it("classifies by type even when an offered id reads like a quota or auth word", () => {
    const error = new DshModelNotOfferedError("gone", ["model-429", "rate-limit-x", "auth-missing"]);
    expect(classifyDshError(error)).toBe("model_catalog_outage");
    // The text alone is read by the pattern classifier, which sees "auth ...
    // missing" in an offered id and calls this a credentials failure.
    expect(classifyDshError(new Error(error.message))).toBe("invalid_credentials");
  });
});

describe("nothing advertised to resolve against", () => {
  const legacy = (model: string) => JSON.stringify([model.startsWith("MiniMax") ? "minimax" : "deepseek-official", model]);

  it("builds the value from the picker id as before", () => {
    expect(dshModelOptionValue("deepseek-v4-flash")).toBe('["deepseek-official","deepseek-v4-flash"]');
    expect(dshModelOptionValue("MiniMax-M3")).toBe('["minimax","MiniMax-M3"]');
    expect(dshModelOptionValue("DeepSeek-V4.1-Flash", undefined)).toBe(legacy("DeepSeek-V4.1-Flash"));
  });

  it("does the same when the reply carries no model option", () => {
    const noModel = [{ id: "reasoning_effort", currentValue: "high" }];
    for (const advertised of [noModel, [], null, {}, "x", 7]) {
      expect(dshModelOptionValue("DeepSeek-V4.1-Flash", advertised)).toBe(legacy("DeepSeek-V4.1-Flash"));
    }
  });

  it("does the same when the model option lists no model", () => {
    const empty = [{ id: "model", type: "select", currentValue: "", options: [] }];
    expect(parseAdvertisedDshModels(empty)).toEqual([]);
    expect(dshModelOptionValue("DeepSeek-V4.1-Flash", empty)).toBe(legacy("DeepSeek-V4.1-Flash"));
  });

  it("ignores malformed entries instead of throwing", () => {
    const junk = [
      null,
      "x",
      {
        id: "model",
        options: [
          null,
          42,
          { value: 5, name: "n" },
          { value: "", name: "n" },
          { group: "deepseek-official", options: "nope" },
          { value: route("deepseek-official", "deepseek-flash") },
        ],
      },
    ];
    expect(parseAdvertisedDshModels(junk)).toEqual([
      {
        value: route("deepseek-official", "deepseek-flash"),
        provider: "deepseek-official",
        id: "deepseek-flash",
        name: "deepseek-flash",
      },
    ]);
  });
});

describe("parseAdvertisedDshModels", () => {
  it("decodes provider, id and display name in advertised order", () => {
    expect(parseAdvertisedDshModels(STOCK)?.map((entry) => [entry.provider, entry.id, entry.name])).toEqual([
      ["deepseek-official", "deepseek-flash", "DeepSeek-V4.1-Flash"],
      ["deepseek-official", "deepseek-v4-pro", "DeepSeek-V4.1-Pro"],
      ["minimax", "MiniMax-M2.7", "MiniMax-M2.7"],
      ["minimax", "MiniMax-M2.7-highspeed", "MiniMax-M2.7-Highspeed"],
      ["minimax", "MiniMax-M3", "MiniMax-M3"],
    ]);
  });

  it("treats a non-tuple value as an id under its group", () => {
    const plain = [{ id: "model", options: [{ group: "custom", options: [{ value: "some-model", name: "Some" }] }] }];
    expect(parseAdvertisedDshModels(plain)).toEqual([
      { value: "some-model", provider: "custom", id: "some-model", name: "Some" },
    ]);
  });
});

describe("matchAdvertisedDshModel", () => {
  it("scopes by provider but lets a provider-less option match any namespace", () => {
    const entries = [{ value: "some-model", provider: "", id: "some-model", name: "some-model" }];
    expect(matchAdvertisedDshModel("Some-Model", "deepseek-official", entries)?.value).toBe("some-model");
    expect(matchAdvertisedDshModel("Some-Model", "minimax", entries)?.value).toBe("some-model");
  });
});

describe("dshSameModel", () => {
  it("folds one DeepSeek model's spellings together", () => {
    expect(dshSameModel("deepseek-v4.1-flash", "DeepSeek-V4.1-Flash")).toBe(true);
    expect(dshSameModel("deepseek-flash", "DeepSeek-V4.1-Flash")).toBe(true);
    expect(dshSameModel("deepseek-v4-flash", "deepseek-flash")).toBe(true);
    expect(dshSameModel("deepseek-v4-pro", "DeepSeek-V4.1-Pro")).toBe(true);
    expect(dshSameModel("MiniMax-M3", "minimax-m3")).toBe(true);
  });

  it("keeps different models apart", () => {
    expect(dshSameModel("deepseek-v4-pro", "deepseek-v4-flash")).toBe(false);
    expect(dshSameModel("DeepSeek-V4.1-Flash", "DeepSeek-V4.1-Pro")).toBe(false);
    expect(dshSameModel("MiniMax-M3", "MiniMax-M3.1-Flash-Preview")).toBe(false);
  });
});

describe("dshSupport.selectModel", () => {
  it("hands the session's advertised options to the resolver", () => {
    const select = dshSupport.selectModel;
    expect(select?.configId).toBe("model");
    expect(select?.valueForModel("DeepSeek-V4.1-Flash", OWNER_OVERRIDE)).toBe(
      route("deepseek-official", "deepseek-v4.1-flash"),
    );
    expect(select?.valueForModel("DeepSeek-V4.1-Flash")).toBe(route("deepseek-official", "DeepSeek-V4.1-Flash"));
  });

  it("still decodes a confirmed value back to a model id", () => {
    expect(dshSupport.selectModel?.modelForValue(route("deepseek-official", "deepseek-flash"))).toBe("deepseek-flash");
  });

  it("keeps the catalog ids stable: only the wire value is translated", () => {
    // Saved selections (Deployer's DeepSeek-V4.1-Flash among them) keep their
    // id; rewriting the catalog to an install's spelling would orphan them.
    expect(STATIC_DSH_MODELS.default).toBe("DeepSeek-V4.1-Flash");
    expect(STATIC_DSH_MODELS.options.map((option) => option.id)).toContain("DeepSeek-V4.1-Pro");
  });
});
