export type MuseErrorCategory = "auth" | "session-in-use" | "timeout" | "process" | "rate-limit" | "internal";

export interface MuseErrorDiagnostics {
  code: number | null;
  category: MuseErrorCategory;
}

/** Return only allowlisted diagnostic metadata; never include provider text or identifiers. */
export function museErrorDiagnostics(error: unknown): MuseErrorDiagnostics {
  if (!error || typeof error !== "object") return { code: null, category: "internal" };

  const row = error as { message?: unknown; code?: unknown; name?: unknown };
  const code = typeof row.code === "number" && Number.isSafeInteger(row.code) ? row.code : null;
  const message = typeof row.message === "string" ? row.message : "";
  const errorCode = typeof row.code === "string" ? row.code : "";
  const name = typeof row.name === "string" ? row.name : "";

  let category: MuseErrorCategory = "internal";
  if (/log in to muse|not logged in|login required|not authenticated/i.test(message)) {
    category = "auth";
  } else if (/(?:this\s+)?session (?:is )?(?:already being opened|already open|already in use|open in another process)|session (?:is )?open in another process|this muse thread is open in another process/i.test(message)) {
    category = "session-in-use";
  } else if (/timeout|timed out|etimedout/i.test(`${name} ${errorCode} ${message}`)) {
    category = "timeout";
  } else if (/rate limit|too many requests|quota exceeded|\b429\b/i.test(message)) {
    category = "rate-limit";
  } else if (name === "BridgeProcessError" || /^(?:EPIPE|ECONNRESET|ERR_CHILD_PROCESS)/i.test(errorCode)) {
    category = "process";
  }

  return { code, category };
}
