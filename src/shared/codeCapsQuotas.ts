import { constants } from "node:fs";
import { open, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export const MAX_QUOTA_BYTES = 1024 * 1024;
export const MAX_QUOTA_AGE_MS = 30 * 60 * 1000;
const windowStrings = ["id", "provider", "providerKey", "providerLabel", "via", "sourceApp", "producerInstanceId", "machine", "modelId", "modelType", "label", "quotaUnit", "planName", "resetAt", "window", "status", "skipReason", "occurredAt", "source"] as const;
const planStrings = ["detectedPlanName", "userPlanName", "userCostUsd", "userRenewalDateText", "userSubtitle"] as const;
type Scalar = string | number | boolean;
export type QuotaWindow = Record<string, Scalar | Record<string, Scalar>>;
export type CodeCapsQuotas = { available: boolean; source: "CodeCaps"; reason?: string; generatedAt?: string; producer?: string; windows: QuotaWindow[] };
const unavailable = (reason: string): CodeCapsQuotas => ({ available: false, source: "CodeCaps", reason, windows: [] });
function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}
function copyStrings(input: Record<string, unknown>, keys: readonly string[], output: Record<string, Scalar>, max = 512): void {
  for (const key of keys) {
    const value = input[key];
    if (typeof value === "string" && (value.length <= max || [...value].length <= max)) output[key] = value;
  }
}
/** Relay only the versioned public fields, with bounded scalar values. */
export function parseCodeCapsQuotas(value: unknown, now = Date.now()): CodeCapsQuotas {
  const payload = record(value);
  if (!payload || payload.format !== "usage-monitor-local-quotas" || payload.version !== 1 || !Array.isArray(payload.windows) || payload.windows.length > 512) return unavailable("invalid snapshot");
  const generatedAt = typeof payload.generatedAt === "string" ? payload.generatedAt : "";
  const stamp = Date.parse(generatedAt);
  if (generatedAt.length > 64 || !Number.isFinite(stamp) || stamp > now + 60_000 || now - stamp > MAX_QUOTA_AGE_MS) return unavailable("stale snapshot");
  const windows: QuotaWindow[] = [];
  for (const raw of payload.windows) {
    const input = record(raw);
    if (!input || typeof input.id !== "string" || !input.id || input.id.length > 512 || typeof input.provider !== "string" || input.provider.length > 512 || typeof input.label !== "string" || input.label.length > 512) return unavailable("invalid window");
    const output: Record<string, Scalar> = {};
    copyStrings(input, windowStrings, output);
    for (const key of ["remainingUnknown", "isExhausted", "skip"]) if (typeof input[key] === "boolean") output[key] = input[key];
    for (const key of ["remainingPercent", "absoluteRemaining", "absoluteLimit"]) {
      const n = input[key];
      if (typeof n === "number" && Number.isFinite(n) && n >= 0 && (key !== "remainingPercent" || n <= 100)) output[key] = n;
    }
    if (input.remainingUnknown !== undefined && input.remainingUnknown !== false) delete output.remainingPercent;
    const window: QuotaWindow = output;
    const metadata = record(input.planMetadata);
    if (metadata) {
      const plan: Record<string, Scalar> = {};
      for (const key of planStrings) {
        const limit = key === "userSubtitle" ? 1024 : key === "userRenewalDateText" ? 512 : key === "userCostUsd" ? 128 : 256;
        copyStrings(metadata, [key], plan, limit);
      }
      for (const key of ["showCostAndRenewal", "hasMismatch"]) if (typeof metadata[key] === "boolean") plan[key] = metadata[key];
      window.planMetadata = plan;
    }
    windows.push(window);
  }
  return { available: true, source: "CodeCaps", generatedAt, ...(typeof payload.producer === "string" && payload.producer.length <= 256 ? { producer: payload.producer } : {}), windows };
}
/** Read one descriptor so atomic producer replacement cannot change the file mid-read. */
export async function readCodeCapsQuotas(home = homedir(), now = Date.now()): Promise<CodeCapsQuotas> {
  let file;
  try {
    const root = join(await realpath(home), "Library/Application Support/Usage Monitor");
    if (await realpath(root) !== root) return unavailable("invalid snapshot directory");
    file = await open(join(root, "quota-windows.json"), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const handle = file;
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > MAX_QUOTA_BYTES) return unavailable("invalid snapshot file");
    const readAll = async (bytes: number): Promise<{ buffer: Buffer; size: number }> => {
      const buffer = Buffer.alloc(Math.min(bytes, MAX_QUOTA_BYTES) + 1);
      let read = 0;
      while (read < buffer.length) {
        const result = await handle.read(buffer, read, buffer.length - read, read);
        if (!result.bytesRead) break;
        read += result.bytesRead;
      }
      return { buffer, size: read };
    };
    let { buffer, size } = await readAll(stat.size);
    if (size === buffer.length) {
      const grown = await handle.stat();
      if (grown.size > size) ({ buffer, size } = await readAll(grown.size));
    }
    if (size > MAX_QUOTA_BYTES) return unavailable("snapshot too large");
    return parseCodeCapsQuotas(JSON.parse(buffer.subarray(0, size).toString("utf8")), now);
  } catch {
    return unavailable("snapshot unavailable");
  } finally {
    try { await file?.close(); } catch { /* close errors must not reject the read */ }
  }
}
