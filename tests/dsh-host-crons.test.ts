import { describe, expect, it } from "vitest";

import { createCron, cronView, deleteCron, describeRule, listCrons, pickCreatedCron } from "../src/web/dshHostCrons.ts";

type Record_ = { kind: string; id: string; prompt: string; scheduledAt: string; afterSeconds?: number; everySeconds?: number };

class FakeHost {
  items: Array<{ sessionId: string; projections?: { values?: { schedule?: Record_[] } } }> = [];
  prompts: string[] = [];
  onPrompt: ((host: FakeHost) => void) | null = null;

  async call(endpoint: string, _args: unknown, schema?: { parse(value: unknown): unknown }): Promise<unknown> {
    if (endpoint === "session/list") {
      const value = { items: this.items };
      return schema ? schema.parse(value) : value;
    }
    if (endpoint === "session/prompt") {
      this.onPrompt?.(this);
      return {};
    }
    throw new Error(`unexpected endpoint ${endpoint}`);
  }

  async *stream(): AsyncGenerator<unknown, void, undefined> {
    yield { type: "snapshot", records: [] };
    yield { type: "event", event: { type: "turn/end", data: { reason: { kind: "completed" } } } };
  }
}

function hostWith(records: Record_[]): FakeHost {
  const host = new FakeHost();
  host.items = [{ sessionId: "sess-1", projections: { values: { schedule: records } } }];
  return host;
}

const NOW = new Date("2026-11-26T12:00:00.000Z");

describe("cronView", () => {
  it("marks past targets overdue and future ones scheduled", () => {
    const past = cronView("s", { kind: "at", id: "a", prompt: "p", scheduledAt: "2026-11-26T11:00:00.000Z" }, NOW);
    const future = cronView("s", { kind: "every", id: "b", prompt: "p", everySeconds: 3600, scheduledAt: "2026-11-26T13:00:00.000Z" }, NOW);
    expect(past.state).toBe("overdue");
    expect(future.state).toBe("scheduled");
    expect(future.everySeconds).toBe(3600);
  });
});

describe("describeRule", () => {
  it("names each rule for the engine instruction", () => {
    expect(describeRule({ kind: "after", afterSeconds: 600 })).toBe("after 600 seconds");
    expect(describeRule({ kind: "every", everySeconds: 300 })).toBe("every 300 seconds");
    expect(describeRule({ kind: "at", at: "2026-12-01T09:00:00.000Z" })).toBe("at 2026-12-01T09:00:00.000Z");
  });
});

describe("listCrons", () => {
  it("flattens schedule projections across sessions", async () => {
    const host = hostWith([
      { kind: "after", id: "a", prompt: "one", afterSeconds: 60, scheduledAt: "2026-11-26T13:00:00.000Z" },
    ]);
    host.items.push({ sessionId: "sess-2", projections: { values: { schedule: [
      { kind: "at", id: "b", prompt: "two", scheduledAt: "2026-11-26T14:00:00.000Z" },
    ] } } });
    const crons = await listCrons(host as never, NOW);
    expect(crons.map((cron) => cron.id)).toEqual(["b", "a"]);
    expect(crons[0]?.sessionId).toBe("sess-2");
  });

  it("skips one malformed record instead of failing the whole list", async () => {
    const host = hostWith([
      { kind: "after", id: "good", prompt: "p", afterSeconds: 60, scheduledAt: "2026-11-26T13:00:00.000Z" },
    ]);
    (host.items[0]!.projections!.values!.schedule as unknown[]).push({ kind: "someday", id: "bad" });
    const crons = await listCrons(host as never, NOW);
    expect(crons.map((cron) => cron.id)).toEqual(["good"]);
  });

  it("reads sessions without a schedule projection as empty", async () => {
    const host = new FakeHost();
    host.items = [{ sessionId: "sess-9" }];
    await expect(listCrons(host as never, NOW)).resolves.toEqual([]);
  });
});

describe("pickCreatedCron", () => {
  it("disambiguates same-prompt creations by predicted target", () => {
    const start = new Date("2026-11-26T12:00:00.000Z");
    const older = cronView("s", { kind: "after", id: "old", prompt: "p", afterSeconds: 600, scheduledAt: "2026-11-26T12:05:00.000Z" }, start);
    const mine = cronView("s", { kind: "after", id: "mine", prompt: "p", afterSeconds: 600, scheduledAt: "2026-11-26T12:10:00.000Z" }, start);
    expect(pickCreatedCron([older, mine], { kind: "after", afterSeconds: 600 }, start)?.id).toBe("mine");
    expect(pickCreatedCron([mine], { kind: "after", afterSeconds: 600 }, start)?.id).toBe("mine");
    expect(pickCreatedCron([], { kind: "after", afterSeconds: 600 }, start)).toBeUndefined();
  });
});

describe("createCron and deleteCron", () => {
  it("returns the record the read-back finds, not the engine's word", async () => {
    const host = hostWith([]);
    host.onPrompt = (fake) => {
      fake.items[0]!.projections!.values!.schedule = [
        { kind: "after", id: "new-1", prompt: "water plants", afterSeconds: 600, scheduledAt: "2026-11-26T12:10:00.000Z" },
      ];
    };
    const cron = await createCron(host as never, {
      sessionId: "sess-1",
      prompt: "water plants",
      rule: { kind: "after", afterSeconds: 600 },
    });
    expect(cron.id).toBe("new-1");
  });

  it("fails when the read-back finds no new record", async () => {
    const host = hostWith([]);
    await expect(createCron(host as never, {
      sessionId: "sess-1",
      prompt: "never made",
      rule: { kind: "after", afterSeconds: 600 },
    })).rejects.toThrow("did not create");
  });

  it("deletes only when the read-back agrees", async () => {
    const host = hostWith([
      { kind: "at", id: "gone", prompt: "p", scheduledAt: "2026-11-27T09:00:00.000Z" },
    ]);
    host.onPrompt = (fake) => {
      fake.items[0]!.projections!.values!.schedule = [];
    };
    await expect(deleteCron(host as never, { sessionId: "sess-1", id: "gone" })).resolves.toBeUndefined();
  });

  it("fails a delete the host still holds", async () => {
    const host = hostWith([
      { kind: "at", id: "stays", prompt: "p", scheduledAt: "2026-11-27T09:00:00.000Z" },
    ]);
    await expect(deleteCron(host as never, { sessionId: "sess-1", id: "stays" })).rejects.toThrow("did not delete");
  });
});
