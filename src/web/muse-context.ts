import { z } from "zod";

const TOKEN_LIMIT = 1_000_000_000;

export const ContextUsageSchema = z.object({
  used: z.number().int().nonnegative().max(TOKEN_LIMIT),
  size: z.number().int().positive().max(TOKEN_LIMIT),
});

const UsageUpdateSchema = z.object({
  sessionUpdate: z.literal("usage_update"),
}).extend(ContextUsageSchema.shape);

const SafeCommandNameSchema = z.string().min(1).max(64).regex(/^[A-Za-z][A-Za-z0-9:_-]*$/);
const AvailableCommandSchema = z.object({ name: SafeCommandNameSchema });
const AvailableCommandsUpdateSchema = z.object({
  sessionUpdate: z.literal("available_commands_update"),
  availableCommands: z.array(AvailableCommandSchema).max(256),
});

const CompactionUpdateSchema = z.object({
  sessionUpdate: z.literal("compaction_update"),
  compactionId: z.string().min(1).max(256),
  status: z.string().min(1).max(64),
});

export const ContextPolicySchema = z.object({
  autoCompact: z.boolean(),
  thresholdPercent: z.number().int().min(50).max(95),
}).strict();

export type ContextUsage = z.infer<typeof ContextUsageSchema>;
export type ContextPolicy = z.infer<typeof ContextPolicySchema>;
export type ContextRevision = string | number;

/** Read only validated occupancy counters from one ACP usage update */
export function contextUsageFromUpdate(update: unknown): ContextUsage | null {
  const parsed = UsageUpdateSchema.safeParse(update);
  if (!parsed.success) return null;
  return { used: parsed.data.used, size: parsed.data.size };
}

/** Whether a well-formed command advertisement includes the manual compact command */
export function compactAvailabilityFromUpdate(update: unknown): boolean | null {
  const parsed = AvailableCommandsUpdateSchema.safeParse(update);
  if (!parsed.success) return null;
  return parsed.data.availableCommands.some((command) => command.name === "compact");
}

/** Extract lifecycle identity and status while deliberately ignoring summary and error text */
export function compactionStatusFromUpdate(update: unknown): { compactionId: string; status: string } | null {
  const parsed = CompactionUpdateSchema.safeParse(update);
  if (!parsed.success) return null;
  return { compactionId: parsed.data.compactionId, status: parsed.data.status };
}

export function shouldCompactEarly(input: {
  policy: unknown;
  context: unknown;
  compactAvailable: boolean | null;
  lastCompactedRevision: ContextRevision | null;
  currentRevision: ContextRevision | null;
}): boolean {
  const policy = ContextPolicySchema.safeParse(input.policy);
  const context = ContextUsageSchema.safeParse(input.context);
  if (!policy.success || !context.success || !policy.data.autoCompact || input.compactAvailable !== true) return false;
  if (!validRevision(input.currentRevision)) return false;
  if (input.lastCompactedRevision !== null && input.currentRevision === input.lastCompactedRevision) return false;
  return (context.data.used / context.data.size) * 100 >= policy.data.thresholdPercent;
}

function validRevision(value: ContextRevision | null): value is ContextRevision {
  if (typeof value === "string") return value.length > 0 && value.length <= 256;
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}
