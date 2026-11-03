import type { IncomingMessage, ServerResponse } from "node:http";

import { handleInfisicalSettingsRequest } from "../../src/web/infisical-route.ts";
import type { ClutchSettings } from "../../src/shared/clutchSettings.ts";

const body = process.env.CLUTCH_ROUTE_TEST_BODY ?? "{}";
const payload = Buffer.from(body);
const req = {
  method: "PUT",
  headers: {},
  async *[Symbol.asyncIterator]() {
    yield payload;
  },
} as unknown as IncomingMessage;

let status = 0;
let raw = "";
const res = {
  writeHead(nextStatus: number) {
    status = nextStatus;
    return res;
  },
  end(nextBody?: string) {
    raw = nextBody ?? "";
    return res;
  },
} as unknown as ServerResponse;

const settings = {
  source: "infisical",
  client: undefined,
  get: () => "",
  has: () => false,
  getAll: () => ({}),
  set: async () => {},
  refresh: async () => {},
  stop: () => {},
} as unknown as ClutchSettings;

await handleInfisicalSettingsRequest(req, res, "/clutch/v1/infisical", {
  settings,
  env: process.env,
});

process.stdout.write(JSON.stringify({ status, body: raw ? JSON.parse(raw) : undefined }) + "\n");
