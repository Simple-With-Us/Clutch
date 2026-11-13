import { describe, it, expect } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { createHash, randomBytes } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

import { DSH_HOST_MUX_PATH } from "../src/shared/dshHostContract";

// =============================================================================
// dsh-host-live — conformance against the dsh host Clutch actually runs.
//
// `scripts/start-web.sh` execs `clutch.sh web`, so the dsh host is already
// listening on $CLUTCH_WEB_PORT on this Mac.  These tests speak to it the way
// a native client would, so the Swift client in
// ios/App/Services/DshHostClient.swift is written against a contract that
// has been observed working, not one read from a source tree.
//
// Two tiers, on purpose:
//
//   * The default tier is read-only.  It never exchanges the launch token,
//     so it cannot disturb the signed cookie the Dock app already holds.
//   * The authenticated tier exchanges the launch token once and asserts the
//     mux upgrade is admitted.  It is opt-in through CLUTCH_LIVE_DSH_HOST=1
//     because it touches the host's credential exchange.
//
// Nothing here prints the launch token or the cookie.  The launch URL is a
// credential: it is read from a 0600 file, used, and discarded.
// =============================================================================

const HOST = process.env.CLUTCH_WEB_HOST ?? "127.0.0.1";
const PORT = process.env.CLUTCH_WEB_PORT ?? "3180";
const AUTHENTICATED = process.env.CLUTCH_LIVE_DSH_HOST === "1";

function launchURLFile(): string {
  const home = process.env.CLUTCH_HOME ?? join(homedir(), ".clutch");
  return process.env.CLUTCH_LAUNCH_URL_FILE ?? join(home, "web-launch-url");
}

function readLaunchURL(): string | null {
  const file = launchURLFile();
  if (!existsSync(file)) return null;
  const text = readFileSync(file, "utf8").trim();
  return text.length > 0 ? text : null;
}

/** Plain GET; resolves the status and the raw `set-cookie` headers. */
function get(
  url: string,
  headers: Record<string, string>,
): Promise<{ status: number; setCookie: string[] }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(url, { method: "GET", headers }, (res) => {
      res.resume();
      res.on("end", () =>
        resolve({ status: res.statusCode ?? 0, setCookie: res.headers["set-cookie"] ?? [] }),
      );
    });
    req.on("error", reject);
    req.end();
  });
}

/** Raw WebSocket upgrade; resolves the status and whether it was admitted. */
function upgrade(
  host: string,
  port: number,
  path: string,
  headers: Record<string, string>,
): Promise<{ status: number; admitted: boolean }> {
  return new Promise((resolve, reject) => {
    const key = randomBytes(16).toString("base64");
    const req = httpRequest({
      host,
      port,
      path,
      headers: {
        ...headers,
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Key": key,
        "Sec-WebSocket-Version": "13",
      },
    });
    req.on("upgrade", (_res, socket) => {
      socket.destroy();
      resolve({ status: 101, admitted: true });
    });
    req.on("response", (res) => {
      res.resume();
      resolve({ status: res.statusCode ?? 0, admitted: false });
    });
    req.on("error", reject);
    req.end();
  });
}

/** The cookie value for a named cookie, from a raw `set-cookie` header list. */
function cookieValue(setCookie: string[], name: string): string | null {
  for (const header of setCookie) {
    const pair = header.split(";")[0] ?? "";
    const eq = pair.indexOf("=");
    if (eq === -1) continue;
    if (pair.slice(0, eq).trim() === name) return pair.slice(eq + 1).trim();
  }
  return null;
}

describe("dsh host live — read-only tier", () => {
  it("answers on the web port with an auth wall, not a dead socket", async () => {
    const url = `http://${HOST}:${PORT}/`;
    let status = 0;
    try {
      status = (await get(url, { Host: `${HOST}:${PORT}` })).status;
    } catch {
      // The host is not running on this machine; nothing to assert.
      return;
    }
    expect([200, 301, 302, 401, 403]).toContain(status);
  });

  it("refuses an unauthenticated mux upgrade", async () => {
    let result: { status: number; admitted: boolean };
    try {
      result = await upgrade(HOST, Number(PORT), DSH_HOST_MUX_PATH, { Host: `${HOST}:${PORT}` });
    } catch {
      return;
    }
    expect(result.admitted).toBe(false);
    expect(result.status).not.toBe(101);
  });
});

describe.runIf(AUTHENTICATED)("dsh host live — authenticated tier", () => {
  it("admits an authenticated mux upgrade", async () => {
    const launchURL = readLaunchURL();
    expect(launchURL).not.toBeNull();
    if (!launchURL) return;

    const exchanged = await get(launchURL, {});
    expect([200, 302]).toContain(exchanged.status);

    const cookie = exchanged.setCookie.map((header) => header.split(";")[0] ?? "").find(Boolean);
    expect(cookie).toBeTruthy();
    if (!cookie) return;

    const result = await upgrade(HOST, Number(PORT), DSH_HOST_MUX_PATH, {
      Host: `${HOST}:${PORT}`,
      Cookie: cookie,
    });
    expect(result.status).toBe(101);
    expect(result.admitted).toBe(true);
  });
});
