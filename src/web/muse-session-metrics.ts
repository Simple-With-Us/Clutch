import type { MuseSessionLog } from "./muse-session-log.ts";
import type { SessionUsage } from "./session-usage.ts";
import { ContextUsageSchema } from "./muse-context.ts";

/** Cumulative provider counters are snapshots, never context occupancy or fresh billable calls. */
export function museSessionUsage(log: MuseSessionLog): SessionUsage | null {
  const usage = log.usage;
  if (usage.attributionCount === 0 && usage.responseTokensPerSecond === null && !log.modelId && !log.providerId) return null;
  return {
    basis: "session-totals",
    totalsComplete: usage.totalsComplete,
    ...(log.modelId ? { model: log.modelId } : {}),
    ...(log.providerId ? { provider: log.providerId } : {}),
    inputTokens: usage.inputTokens ?? 0,
    outputTokens: usage.outputTokens ?? 0,
    ...(usage.inputTokens === undefined ? { inputTokensReported: false as const } : {}),
    ...(usage.outputTokens === undefined ? { outputTokensReported: false as const } : {}),
    // A required legacy field; consumers use basis to leave occupancy unknown.
    totalTokens: 0,
    ...(usage.cachedTokens !== undefined ? { cachedTokens: usage.cachedTokens } : {}),
    ...(usage.responseTokensPerSecond !== null ? { responseTokensPerSecond: usage.responseTokensPerSecond } : {}),
    ...(usage.completionDurationMs !== null ? { completionDurationMs: usage.completionDurationMs } : {}),
  };
}

export function withMuseContext(
  usage: SessionUsage | null,
  controls: { contextUsedTokens?: number; contextWindow?: number },
): SessionUsage | null {
  const context = ContextUsageSchema.safeParse({ used: controls.contextUsedTokens, size: controls.contextWindow });
  if (!context.success) return usage;
  return {
    ...(usage ?? { basis: "session-totals", inputTokens: 0, inputTokensReported: false,
      outputTokens: 0, outputTokensReported: false, totalTokens: 0 }),
    contextUsedTokens: context.data.used,
    contextWindow: context.data.size,
  };
}
