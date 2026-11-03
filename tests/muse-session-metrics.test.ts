import { describe, expect, it } from "vitest";
import { parseMuseSessionLog } from "../src/web/muse-session-log.ts";
import { museSessionUsage, withMuseContext } from "../src/web/muse-session-metrics.ts";
import { contextUsedPercent } from "../src/web/session-usage.ts";

const sessionId = "8ec48d4a-e48d-4a49-ae87-f710d028e20c";
const record = (payload_type: string, payload: unknown): string => JSON.stringify({ record_type: "event", payload_type, payload });

describe("Muse session metrics", () => {
  it("keeps absent usage unknown while exposing recorded model and provider", () => {
    const usage = museSessionUsage(parseMuseSessionLog(record("runtime.session.metadata", {
      record: { model_id: "muse-spark-1.3-contributor", provider_id: "muse" },
    }), sessionId));
    expect(usage).toMatchObject({ model: "muse-spark-1.3-contributor", provider: "muse",
      basis: "session-totals", inputTokensReported: false, outputTokensReported: false });
    expect(usage?.cachedTokens).toBeUndefined();
    expect(contextUsedPercent(usage!)).toBeUndefined();
  });

  it("preserves reported zero and separates cumulative counts from real occupancy", () => {
    const usage = museSessionUsage(parseMuseSessionLog(record("runtime.session", {
      event: { kind: "goal_usage_attribution", record: { usage_id: "unique-usage", usage_family: "provider",
        quantity: { unit: "tokens", reported: true, input_tokens: 0, output_tokens: 12, cached_tokens: 0 } } },
    }), sessionId));
    expect(usage).toMatchObject({ inputTokens: 0, outputTokens: 12, cachedTokens: 0 });
    expect(usage?.inputTokensReported).not.toBe(false);
    expect(contextUsedPercent(usage!)).toBeUndefined();
    const measured = withMuseContext(usage, { contextUsedTokens: 125, contextWindow: 100 });
    expect(measured).toMatchObject({ inputTokens: 0, outputTokens: 12, contextUsedTokens: 125, contextWindow: 100 });
    expect(contextUsedPercent(measured!)).toBe(125);
  });

  it("allows context-only zero without inventing provider usage and rejects malformed context", () => {
    const usage = withMuseContext(null, { contextUsedTokens: 0, contextWindow: 100 });
    expect(usage).toMatchObject({ contextUsedTokens: 0, inputTokensReported: false, outputTokensReported: false });
    expect(contextUsedPercent(usage!)).toBe(0);
    expect(withMuseContext(null, { contextUsedTokens: 12 })).toBeNull();
    expect(withMuseContext(null, { contextUsedTokens: -1, contextWindow: 100 })).toBeNull();
    expect(withMuseContext(null, { contextUsedTokens: 1, contextWindow: 0 })).toBeNull();
  });
});
