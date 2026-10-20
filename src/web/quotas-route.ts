import type { IncomingMessage, ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { readCodeCapsQuotas } from "../shared/codeCapsQuotas.ts";

/** Clutch-owned sidecar endpoint, separate from the upstream dsh contract. */
export async function handleQuotasRequest(req: IncomingMessage, res: ServerResponse, pathname: string, token: string, read = readCodeCapsQuotas): Promise<boolean> {
  if (pathname !== "/clutch/v1/quotas") return false;
  const supplied = Buffer.from(/^Bearer (.+)$/.exec((req.headers.authorization ?? "").trim())?.[1] ?? "");
  const expected = Buffer.from(token);
  let status = 200;
  let body: unknown;
  if (!expected.length || supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) { status = 401; body = { error: "unauthorized" }; }
  else if (req.method !== "GET") { status = 405; body = { error: "use GET" }; }
  else body = await read();
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify(body));
  return true;
}
