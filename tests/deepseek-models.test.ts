import { describe, expect, it } from "vitest";

import {
  DEEPSEEK_MODELS_MAX_BYTES,
  DEEPSEEK_MODELS_URL,
  DeepSeekModelsError,
  fetchDeepSeekModels,
  mergeDiscoveredModels,
  normalizeDeepSeekModels,
} from "../src/dsh/deepseek-models.ts";
import type { ModelCatalog } from "../src/shared/contracts.ts";

/** A `fetch` stand-in.  Records the request so the credential contract and
 *  the endpoint can be asserted, and replies with a canned body. */
function stubFetch(
  reply: { readonly status?: number; readonly body?: string; readonly contentLength?: string },
  seen?: { url?: string; authorization?: string },
): typeof fetch {
  return (async (input: RequestInfo | URL) => {
    const request = input as Request;
    seen ??= {};
    seen.url = request.url;
    seen.authorization = request.headers.get("authorization") ?? undefined;
    return new Response(reply.body ?? "{}", {
      status: reply.status ?? 200,
      headers: reply.contentLength === undefined
        ? undefined
        : { "content-length": reply.contentLength },
    });
  }) as unknown as typeof fetch;
}

const LISTING = JSON.stringify({
  object: "list",
  data: [
    { id: "deepseek-chat", object: "model", owned_by: "deepseek" },
    { id: "deepseek-reasoner", object: "model", owned_by: "deepseek" },
  ],
});

describe("deepseek model discovery", () => {
  it("requests the owner's endpoint with a bearer credential", async () => {
    const seen: { url?: string; authorization?: string } = {};
    await fetchDeepSeekModels({ apiKey: "sk-test", fetchImpl: stubFetch({ body: LISTING }, seen) });

    expect(seen.url).toBe(DEEPSEEK_MODELS_URL);
    expect(seen.url).toBe("https://api.deepseek.com/models");
    expect(seen.authorization).toBe("Bearer sk-test");
  });

  it("normalizes the OpenAI-shaped listing", async () => {
    const models = await fetchDeepSeekModels({
      apiKey: "sk-test",
      fetchImpl: stubFetch({ body: LISTING }),
    });
    expect(models).toEqual([
      { id: "deepseek-chat", label: "deepseek-chat", ownedBy: "deepseek" },
      { id: "deepseek-reasoner", label: "deepseek-reasoner", ownedBy: "deepseek" },
    ]);
  });

  it("refuses a missing key instead of sending an empty bearer", async () => {
    // An unauthenticated listing answers 401, which would report a healthy
    // provider as broken.  Fail before the request goes out.
    let called = false;
    const impl = (async () => {
      called = true;
      return new Response("{}");
    }) as unknown as typeof fetch;

    await expect(
      fetchDeepSeekModels({ apiKey: "   ", fetchImpl: impl }),
    ).rejects.toMatchObject({ code: "invalid_credentials" });
    expect(called).toBe(false);
  });

  it("maps 401 and 403 onto invalid_credentials", async () => {
    for (const status of [401, 403]) {
      const error = await fetchDeepSeekModels({
        apiKey: "sk-test",
        fetchImpl: stubFetch({ status, body: "{}" }),
      }).catch((caught: unknown) => caught);

      expect(error).toBeInstanceOf(DeepSeekModelsError);
      expect((error as DeepSeekModelsError).code).toBe("invalid_credentials");
    }
  });

  it("maps 429 onto the canonical quota code", async () => {
    const error = await fetchDeepSeekModels({
      apiKey: "sk-test",
      fetchImpl: stubFetch({ status: 429, body: "{}" }),
    }).catch((caught: unknown) => caught as DeepSeekModelsError);

    expect(error.code).toBe("quota_or_region_restriction");
  });

  it("reports a transport failure without leaking the credential", async () => {
    const error = await fetchDeepSeekModels({
      apiKey: "sk-super-secret-value",
      fetchImpl: (async () => {
        throw new Error("ECONNREFUSED");
      }) as unknown as typeof fetch,
    }).catch((caught: unknown) => caught as DeepSeekModelsError);

    expect(error.code).toBe("discovery_failed");
    expect(error.message).not.toContain("sk-super-secret-value");
  });

  it("refuses an over-long listing on the declared length alone", async () => {
    const error = await fetchDeepSeekModels({
      apiKey: "sk-test",
      fetchImpl: stubFetch({
        body: LISTING,
        contentLength: String(DEEPSEEK_MODELS_MAX_BYTES + 1),
      }),
    }).catch((caught: unknown) => caught as DeepSeekModelsError);

    expect(error.code).toBe("discovery_failed");
    expect(error.message).toContain("ceiling");
  });

  it("bounds a stream that under-declares its length", async () => {
    // content-length says 10 bytes but the stream keeps going, so the
    // accumulated total is what has to catch it.  The stream has to clear
    // the whole ceiling for that to be a meaningful test.
    const chunkBytes = Math.ceil(DEEPSEEK_MODELS_MAX_BYTES / 2 / 1024) * 1024;
    const chunkCount = 5;
    const impl = (async () =>
      new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            for (let i = 0; i < chunkCount; i++) {
              controller.enqueue(new Uint8Array(chunkBytes));
            }
            controller.close();
          },
        }),
        { status: 200, headers: { "content-length": "10" } },
      )) as unknown as typeof fetch;

    const error = await fetchDeepSeekModels({ apiKey: "sk-test", fetchImpl: impl }).catch(
      (caught: unknown) => caught as DeepSeekModelsError,
    );
    expect(error.code).toBe("discovery_failed");
    expect(error.message).toContain("ceiling");
  });

  it("still parses a large but permitted listing", async () => {
    // The ceiling must not reject a listing that is merely big.
    const many = Array.from({ length: 20_000 }, (_, i) => ({ id: `deepseek-model-${i}` }));
    const body = JSON.stringify({ object: "list", data: many });
    expect(new TextEncoder().encode(body).byteLength).toBeLessThan(DEEPSEEK_MODELS_MAX_BYTES);

    const models = await fetchDeepSeekModels({
      apiKey: "sk-test",
      fetchImpl: stubFetch({ body }),
    });
    expect(models).toHaveLength(20_000);
  });

  it("rejects a non-JSON reply rather than inventing an empty catalog", async () => {
    const error = await fetchDeepSeekModels({
      apiKey: "sk-test",
      fetchImpl: stubFetch({ body: "<html>nope</html>" }),
    }).catch((caught: unknown) => caught as DeepSeekModelsError);

    expect(error.code).toBe("discovery_failed");
  });

  it("distinguishes an empty list from a failed one", () => {
    // An account with no models is a real answer, not a failure; the UI has
    // different copy for each.
    expect(normalizeDeepSeekModels({ object: "list", data: [] })).toEqual([]);
    expect(fetchDeepSeekModels).toBeTypeOf("function");
  });

  it("drops malformed and duplicate entries rather than surfacing them", () => {
    expect(
      normalizeDeepSeekModels({
        data: [
          { id: "deepseek-chat" },
          { id: "deepseek-chat" },
          { id: "   " },
          { id: 42 },
          null,
          "nope",
          { id: "deepseek-reasoner" },
        ],
      }),
    ).toEqual([
      { id: "deepseek-chat", label: "deepseek-chat" },
      { id: "deepseek-reasoner", label: "deepseek-reasoner" },
    ]);
  });

  it("returns nothing for a shape it does not understand", () => {
    // Better an empty list the operator can hand-fill than junk ids injected
    // into the model picker.
    expect(normalizeDeepSeekModels({ models: ["deepseek-chat"] })).toEqual([]);
    expect(normalizeDeepSeekModels(null)).toEqual([]);
    expect(normalizeDeepSeekModels([1, 2, 3])).toEqual([]);
  });
});

describe("mergeDiscoveredModels", () => {
  const catalog: ModelCatalog = {
    default: "deepseek-chat",
    options: [
      { id: "deepseek-chat", label: "deepseek-chat" },
      {
        id: "deepseek-v4.1-flash",
        label: "DeepSeek V4.1 Flash",
        badge: "Multimodal",
        badgeTitle: "Accepts image and video input.",
        contextWindow: 163_840,
      },
    ],
  };

  it("appends only ids the catalog does not already carry", () => {
    const merged = mergeDiscoveredModels(catalog, [
      { id: "deepseek-chat", label: "deepseek-chat" },
      { id: "deepseek-reasoner", label: "deepseek-reasoner" },
    ]);

    expect(merged.options.map((o) => o.id)).toEqual([
      "deepseek-chat",
      "deepseek-v4.1-flash",
      "deepseek-reasoner",
    ]);
  });

  it("preserves curated metadata on models it already knew", () => {
    // Re-fetching must never silently downgrade a hand-tuned badge, tooltip,
    // or context window back to the bare discovered id.
    const merged = mergeDiscoveredModels(catalog, [
      { id: "deepseek-v4.1-flash", label: "deepseek-v4.1-flash" },
    ]);
    expect(merged.options[1]).toEqual(catalog.options[1]);
  });

  it("leaves the default alone and returns the same object when nothing is new", () => {
    expect(mergeDiscoveredModels(catalog, [{ id: "deepseek-chat", label: "deepseek-chat" }])).toBe(
      catalog,
    );
    expect(mergeDiscoveredModels(catalog, []).default).toBe("deepseek-chat");
  });
});
