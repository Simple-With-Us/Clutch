import { describe, expect, it } from "vitest";

import {
  compactAvailabilityFromUpdate,
  compactionStatusFromUpdate,
  contextUsageFromUpdate,
  shouldCompactEarly,
} from "../src/web/muse-context.ts";

describe("Muse ACP context updates", () => {
  it("accepts bounded nonnegative context usage and rejects malformed counters", () => {
    expect(contextUsageFromUpdate({ sessionUpdate: "usage_update", used: 90, size: 100 })).toEqual({ used: 90, size: 100 });
    expect(contextUsageFromUpdate({ sessionUpdate: "usage_update", used: 0, size: 1 })).toEqual({ used: 0, size: 1 });
    expect(contextUsageFromUpdate({ sessionUpdate: "usage_update", used: 125, size: 100 })).toEqual({ used: 125, size: 100 });
    expect(contextUsageFromUpdate({ sessionUpdate: "usage_update", used: 1, size: 0 })).toBeNull();
    expect(contextUsageFromUpdate({ sessionUpdate: "usage_update", used: -1, size: 100 })).toBeNull();
    expect(contextUsageFromUpdate({ sessionUpdate: "usage_update", used: 1.5, size: 100 })).toBeNull();
    expect(contextUsageFromUpdate({ sessionUpdate: "usage_update", used: 1_000_000_001, size: 1_000_000_001 })).toBeNull();
    expect(contextUsageFromUpdate({ sessionUpdate: "agent_message_chunk", used: 100, size: 100 })).toBeNull();
  });

  it("recognizes only a validated advertised compact command", () => {
    expect(compactAvailabilityFromUpdate({
      sessionUpdate: "available_commands_update",
      availableCommands: [{ name: "plan" }, { name: "compact" }],
    })).toBe(true);
    expect(compactAvailabilityFromUpdate({
      sessionUpdate: "available_commands_update",
      availableCommands: [{ name: "plan" }, { name: "Compact" }],
    })).toBe(false);
    expect(compactAvailabilityFromUpdate({ sessionUpdate: "available_commands_update", availableCommands: [] })).toBe(false);
    expect(compactAvailabilityFromUpdate({ sessionUpdate: "available_commands_update", availableCommands: [{ name: "../compact" }] })).toBeNull();
    expect(compactAvailabilityFromUpdate({ sessionUpdate: "available_commands_update", availableCommands: Array.from({ length: 257 }, () => ({ name: "compact" })) })).toBeNull();
    expect(compactAvailabilityFromUpdate({ sessionUpdate: "usage_update", availableCommands: [{ name: "compact" }] })).toBeNull();
  });

  it("extracts compaction status without returning summary or error text", () => {
    expect(compactionStatusFromUpdate({
      sessionUpdate: "compaction_update",
      compactionId: "compact-1",
      status: "in_progress",
      summary: [{ type: "text", text: "private conversation text" }],
      error: "private failure detail",
    })).toEqual({ compactionId: "compact-1", status: "in_progress" });
    expect(compactionStatusFromUpdate({ sessionUpdate: "compaction_update", compactionId: "", status: "failed" })).toBeNull();
    expect(compactionStatusFromUpdate({ sessionUpdate: "compaction_update", compactionId: "x", status: "x".repeat(65) })).toBeNull();
  });

  it("compacts only with enabled policy, valid reported occupancy, and an advertised command", () => {
    const base = {
      policy: { autoCompact: true, thresholdPercent: 80 },
      context: { used: 80, size: 100 },
      compactAvailable: true as boolean | null,
      lastCompactedRevision: null as string | number | null,
      currentRevision: 1 as string | number | null,
    };
    expect(shouldCompactEarly(base)).toBe(true);
    expect(shouldCompactEarly({ ...base, context: { used: 125, size: 100 } })).toBe(true);
    expect(shouldCompactEarly({ ...base, context: { used: 79, size: 100 } })).toBe(false);
    expect(shouldCompactEarly({ ...base, policy: { autoCompact: false, thresholdPercent: 80 } })).toBe(false);
    expect(shouldCompactEarly({ ...base, compactAvailable: false })).toBe(false);
    expect(shouldCompactEarly({ ...base, compactAvailable: null })).toBe(false);
    expect(shouldCompactEarly({ ...base, context: null })).toBe(false);
    expect(shouldCompactEarly({ ...base, policy: { autoCompact: true, thresholdPercent: 49 } })).toBe(false);
  });

  it("does not repeat compaction for a revision already compacted", () => {
    const base = {
      policy: { autoCompact: true, thresholdPercent: 80 },
      context: { used: 90, size: 100 },
      compactAvailable: true as boolean | null,
      lastCompactedRevision: "turn-4",
      currentRevision: "turn-4",
    };
    expect(shouldCompactEarly(base)).toBe(false);
    expect(shouldCompactEarly({ ...base, currentRevision: "turn-5" })).toBe(true);
    expect(shouldCompactEarly({ ...base, currentRevision: null })).toBe(false);
  });
});
