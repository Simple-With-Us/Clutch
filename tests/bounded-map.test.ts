import { describe, expect, it, vi } from "vitest";

import { mapWithConcurrency } from "../src/web/bounded-map.ts";

describe("mapWithConcurrency", () => {
  it("preserves input order and maps every item with at most four in flight", async () => {
    let inFlight = 0;
    let maximumInFlight = 0;
    const values = Array.from({ length: 19 }, (_, index) => index);
    const result = await mapWithConcurrency(values, 4, async (value) => {
      inFlight++;
      maximumInFlight = Math.max(maximumInFlight, inFlight);
      await new Promise((resolve) => setTimeout(resolve, (values.length - value) % 4));
      inFlight--;
      return value * 3;
    });

    expect(result).toEqual(values.map((value) => value * 3));
    expect(result).toHaveLength(values.length);
    expect(maximumInFlight).toBeLessThanOrEqual(4);
    expect(maximumInFlight).toBe(4);
  });

  it("returns an empty result without invoking the mapper", async () => {
    const mapper = vi.fn((value: number) => value);
    await expect(mapWithConcurrency([], 4, mapper)).resolves.toEqual([]);
    expect(mapper).not.toHaveBeenCalled();
  });

  it("propagates mapper rejection", async () => {
    await expect(mapWithConcurrency([1, 2, 3], 2, async (value) => {
      if (value === 2) throw new Error("synthetic failure");
      return value;
    })).rejects.toThrow("synthetic failure");
  });
});
