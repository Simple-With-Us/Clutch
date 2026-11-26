import { z } from "zod";

import type { DshHostClient } from "./dshHostClient.ts";
import { runDshHostTurn } from "./dshHostTurn.ts";

/**
 * Native crons over the dsh host's schedule service.
 *
 * The schedule service is agent-scoped: reminders live in the owning
 * session's event log, the host folds them into the `schedule` session
 * projection, and the only management surface upstream offers is the
 * engine's own `schedule_create` / `schedule_delete` tools inside a turn.
 * This adapter keeps that coupling in one server-side place, as C-82
 * recommended: listing reads the projection the host already publishes,
 * and creating or deleting asks the owning session's engine to call its
 * tool, then reads the projection back to prove what actually landed.
 * A create or delete the read-back cannot find is reported as failed,
 * never as done.
 */

const ScheduleRecordSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("after"),
    id: z.string().min(1),
    prompt: z.string(),
    afterSeconds: z.number(),
    scheduledAt: z.string(),
  }).passthrough(),
  z.object({
    kind: z.literal("at"),
    id: z.string().min(1),
    prompt: z.string(),
    scheduledAt: z.string(),
  }).passthrough(),
  z.object({
    kind: z.literal("every"),
    id: z.string().min(1),
    prompt: z.string(),
    everySeconds: z.number(),
    scheduledAt: z.string(),
  }).passthrough(),
]);

const CronListValueSchema = z
  .object({
    items: z
      .array(
        z
          .object({
            sessionId: z.string(),
            projections: z
              .object({
                values: z
                  .object({ schedule: z.array(ScheduleRecordSchema).optional() })
                  .passthrough()
                  .optional(),
              })
              .passthrough()
              .optional(),
          })
          .passthrough(),
      )
      .default([]),
  })
  .passthrough();

export interface CronView {
  readonly id: string;
  readonly sessionId: string;
  readonly kind: "after" | "at" | "every";
  readonly prompt: string;
  readonly scheduledAt: string;
  readonly afterSeconds?: number;
  readonly everySeconds?: number;
  readonly state: "scheduled" | "overdue";
  readonly deliveryMode: "session-local";
}

/** One reminder as the panel shows it, with its delivery state at `now`. */
export function cronView(sessionId: string, record: z.infer<typeof ScheduleRecordSchema>, now: Date): CronView {
  const base = {
    id: record.id,
    sessionId,
    kind: record.kind,
    prompt: record.prompt,
    scheduledAt: record.scheduledAt,
    state: (Date.parse(record.scheduledAt) > now.getTime() ? "scheduled" : "overdue") as CronView["state"],
    deliveryMode: "session-local" as const,
  };
  if (record.kind === "after") return { ...base, afterSeconds: record.afterSeconds };
  if (record.kind === "every") return { ...base, everySeconds: record.everySeconds };
  return base;
}

/** Every active reminder on the host, newest target first. */
export async function listCrons(client: DshHostClient, now: Date = new Date()): Promise<CronView[]> {
  const value = await client.call("session/list", { _request: {} }, CronListValueSchema);
  const out: CronView[] = [];
  for (const item of value.items) {
    for (const record of item.projections?.values?.schedule ?? []) {
      out.push(cronView(item.sessionId, record, now));
    }
  }
  return out.sort((a, b) => Date.parse(b.scheduledAt) - Date.parse(a.scheduledAt));
}

export type CronRule =
  | { readonly kind: "after"; readonly afterSeconds: number }
  | { readonly kind: "at"; readonly at: string }
  | { readonly kind: "every"; readonly everySeconds: number };

/** The rule as the engine's tool is asked to apply it. */
export function describeRule(rule: CronRule): string {
  if (rule.kind === "after") return `after ${rule.afterSeconds} seconds`;
  if (rule.kind === "at") return `at ${rule.at}`;
  return `every ${rule.everySeconds} seconds`;
}

/**
 * Create one reminder in the session that will deliver it.
 *
 * Delivery is session-local by upstream design, so the session must be
 * the live thread the owner means.  The turn is verified against the
 * projection afterwards: the record returned is the one the host holds,
 * not the one the engine said it made.
 */
export async function createCron(
  client: DshHostClient,
  options: { readonly sessionId: string; readonly prompt: string; readonly rule: CronRule },
): Promise<CronView> {
  const before = new Set((await listCrons(client)).filter((cron) => cron.sessionId === options.sessionId).map((cron) => cron.id));
  const instruction =
    `Use your schedule_create tool now to create exactly one reminder with prompt ${JSON.stringify(options.prompt)} ` +
    `and rule ${describeRule(options.rule)}. Do nothing else. When it is created, reply with only: created`;
  const turn = await runDshHostTurn(client, {
    sessionId: options.sessionId,
    prompt: instruction,
    onUpdate: () => undefined,
  });
  if (turn.stopReason === "cancelled") {
    throw new Error("the host ended the creation turn before the reminder was created");
  }
  const created = (await listCrons(client)).find(
    (cron) => cron.sessionId === options.sessionId && !before.has(cron.id) && cron.prompt === options.prompt,
  );
  if (!created) {
    throw new Error("the engine did not create the reminder: no matching record in the session's schedule");
  }
  return created;
}

/** Delete one reminder from its owning session, verified by read-back. */
export async function deleteCron(
  client: DshHostClient,
  options: { readonly sessionId: string; readonly id: string },
): Promise<void> {
  const instruction =
    `Use your schedule_delete tool now to delete exactly the reminder with id ${JSON.stringify(options.id)}. ` +
    `Do nothing else. When it is deleted, reply with only: deleted`;
  const turn = await runDshHostTurn(client, {
    sessionId: options.sessionId,
    prompt: instruction,
    onUpdate: () => undefined,
  });
  if (turn.stopReason === "cancelled") {
    throw new Error("the host ended the deletion turn before the reminder was deleted");
  }
  const stillThere = (await listCrons(client)).some(
    (cron) => cron.sessionId === options.sessionId && cron.id === options.id,
  );
  if (stillThere) {
    throw new Error("the engine did not delete the reminder: it is still in the session's schedule");
  }
}
