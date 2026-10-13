/**
 * Backfill deploy-path test: `clutch-infisical-env.sh` runs against a stub
 * Infisical server and must export the CometChat keys (plus the existing
 * managed set) without clobbering explicitly-set env. All values here are
 * invented sentinels — nothing real, nothing leaves the test process.
 */
import { execFile } from "node:child_process";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { join } from "node:path";

const SENTINELS: Record<string, string> = {
  COMETCHAT_APP_ID: "stub-app-123",
  COMETCHAT_REGION: "eu",
  COMETCHAT_AUTH_KEY: "stub-auth",
  COMETCHAT_REST_API_KEY: "stub-rest",
  COMETCHAT_AGENT_UID: "stub-agent",
  CLUTCH_WEB_PORT: "3999",
  UNMANAGED_KEY: "must-not-appear",
};

let server: Server;
let stubPort = 0;

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
  });
}

beforeAll(async () => {
  server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    await readBody(req);
    const url = new URL(req.url ?? "/", "http://x");
    if (url.pathname === "/api/v1/auth/universal-auth/login") {
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ accessToken: "stub-token" }));
      return;
    }
    if (url.pathname === "/api/v3/secrets/raw") {
      res.writeHead(200, { "content-type": "application/json" }).end(
        JSON.stringify({
          secrets: Object.entries(SENTINELS).map(([secretKey, secretValue]) => ({ secretKey, secretValue })),
        }),
      );
      return;
    }
    res.writeHead(404).end("{}");
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  stubPort = (server.address() as { port: number }).port;
});

afterAll(() => {
  server?.close();
});

function runBackfill(extraEnv: Record<string, string> = {}): Promise<{ stdout: string; stderr: string }> {
  const root = join(__dirname, "..");
  const script = `source "${join(root, "scripts", "lib", "clutch-infisical-env.sh")}"; ` +
    `printf 'APP_ID=%s\\nREGION=%s\\nREST=%s\\nAUTH=%s\\nAGENT=%s\\nPORT=%s\\nUNMANAGED=%s\\n' ` +
    `"$COMETCHAT_APP_ID" "$COMETCHAT_REGION" "$COMETCHAT_REST_API_KEY" "$COMETCHAT_AUTH_KEY" "$COMETCHAT_AGENT_UID" "$CLUTCH_WEB_PORT" "$UNMANAGED_KEY"`;
  return new Promise((resolve, reject) => {
    execFile(
      "bash",
      ["-c", script],
      {
        env: {
          ...process.env,
          INFISICAL_CLIENT_ID: "stub-id",
          INFISICAL_CLIENT_SECRET: "stub-secret",
          CLUTCH_INFISICAL_URL: `http://127.0.0.1:${stubPort}`,
          COMETCHAT_APP_ID: "",
          COMETCHAT_REGION: "",
          COMETCHAT_AUTH_KEY: "",
          COMETCHAT_REST_API_KEY: "",
          COMETCHAT_AGENT_UID: "",
          CLUTCH_WEB_PORT: "",
          UNMANAGED_KEY: "",
          ...extraEnv,
        },
        timeout: 30000,
      },
      (err, stdout, stderr) => {
        if (err) reject(err);
        else resolve({ stdout, stderr });
      },
    );
  });
}

describe("clutch-infisical-env backfill", () => {
  it("exports the CometChat keys from Infisical and skips unmanaged keys", async () => {
    const { stdout, stderr } = await runBackfill();
    for (const [key, value] of Object.entries(SENTINELS)) {
      if (key === "UNMANAGED_KEY") {
        expect(stdout).not.toContain(value);
        continue;
      }
      expect(stdout).toContain(value);
    }
    expect(stderr).toContain("COMETCHAT_APP_ID");
  });

  it("lets explicitly-set env win over Infisical", async () => {
    const { stdout } = await runBackfill({ COMETCHAT_REGION: "kept-local" });
    expect(stdout).toContain("REGION=kept-local");
    expect(stdout).toContain("APP_ID=stub-app-123");
  });
});
