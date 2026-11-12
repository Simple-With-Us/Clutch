/**
 * Backfill deploy-path test: `clutch-infisical-env.sh` runs against a stub
 * Infisical server and must export the CometChat keys (plus the existing
 * managed set) without clobbering explicitly-set env. All values here are
 * invented sentinels — nothing real, nothing leaves the test process.
 */
import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { chmodSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
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
const fixtureToken = () => `st.${randomBytes(32).toString("hex")}`;
const expectedAuthorization = (token: string) => `Bearer ${token}`;
const EXPLICIT_READ_TOKEN = fixtureToken();
const FILE_READ_TOKEN = fixtureToken();
const FILE_WRITE_TOKEN = fixtureToken();
const PROJECT = "077fd6f3-9f9b-438e-9b6f-5c69076cf36c";
const VALID_METADATA = {
  projectId: PROJECT,
  workspace: PROJECT,
  scopes: [{ secretPath: "/", environment: "prod" }],
  permissions: ["read"],
};

let server: Server;
let stubPort = 0;
let seenAuthorization = "";
let seenWorkspaceId = "";
let seenSecretQuery: Record<string, string> = {};
let metadataFixture: Record<string, unknown> = VALID_METADATA;
let secretListRequests = 0;
let metadataRedirect = false;
let forwardedMetadataRedirectAuthorization = "";

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
    if (url.pathname === "/api/v2/service-token") {
      const authorization = String(req.headers.authorization ?? "");
      if (![EXPLICIT_READ_TOKEN, FILE_READ_TOKEN].some((token) => authorization === expectedAuthorization(token))) {
        res.writeHead(401).end("{}");
        return;
      }
      if (metadataRedirect) {
        res.writeHead(302, { location: "/capture-metadata-token" }).end();
        return;
      }
      const scopedMetadata = authorization === expectedAuthorization(FILE_READ_TOKEN)
        ? { ...metadataFixture, projectId: "fixture-file-project", workspace: "fixture-file-project" }
        : metadataFixture;
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(scopedMetadata));
      return;
    }
    if (url.pathname === "/capture-metadata-token") {
      forwardedMetadataRedirectAuthorization = String(req.headers.authorization ?? "");
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(metadataFixture));
      return;
    }
    if (url.pathname === "/api/v3/secrets/raw") {
      secretListRequests += 1;
      const authorization = String(req.headers.authorization ?? "");
      if (![expectedAuthorization(EXPLICIT_READ_TOKEN), expectedAuthorization(FILE_READ_TOKEN)].includes(authorization)) {
        res.writeHead(401).end("{}");
        return;
      }
      seenAuthorization = authorization;
      seenWorkspaceId = url.searchParams.get("workspaceId") ?? "";
      seenSecretQuery = Object.fromEntries(url.searchParams.entries());
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
    `"$COMETCHAT_APP_ID" "$COMETCHAT_REGION" "$COMETCHAT_REST_API_KEY" "$COMETCHAT_AUTH_KEY" "$COMETCHAT_AGENT_UID" "$CLUTCH_WEB_PORT" "$UNMANAGED_KEY"; ` +
    `printf 'READ_SET=%s\\nWRITE_SET=%s\\nPROJECT_SET=%s\\n' ` +
    `"\${INFISICAL_TOKEN:+yes}" "\${INFISICAL_WRITE_TOKEN:+yes}" "\${INFISICAL_PROJECT_ID:+yes}"`;
  return new Promise((resolve, reject) => {
    execFile(
      "bash",
      ["-c", script],
      {
        env: {
          ...process.env,
          INFISICAL_TOKEN: EXPLICIT_READ_TOKEN,
          INFISICAL_WRITE_TOKEN: "",
          INFISICAL_PROJECT_ID: "",
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

function runShellRoute(extraEnv: Record<string, string> = {}): Promise<{ stdout: string; stderr: string }> {
  const root = join(__dirname, "..");
  const script = `source "${join(root, "scripts", "lib", "clutch-infisical-env.sh")}"; ` +
    `"${join(root, "node_modules", ".bin", "tsx")}" "${join(root, "tests", "fixtures", "infisical-route-shell-seam.ts")}"`;
  return new Promise((resolve, reject) => {
    execFile(
      "bash",
      ["-c", script],
      {
        env: {
          ...process.env,
          INFISICAL_TOKEN: "",
          INFISICAL_WRITE_TOKEN: "",
          INFISICAL_PROJECT_ID: "",
          CLUTCH_INFISICAL_URL: `http://127.0.0.1:${stubPort}`,
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
    expect(seenSecretQuery).toMatchObject({ recursive: "false", include_imports: "false", expandSecretReferences: "false" });
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

  it("does not read secrets when service-token metadata has a broader or mismatched scope", async () => {
    const invalidMetadata: Array<Record<string, unknown>> = [
      { ...VALID_METADATA, projectId: "other-project", workspace: "other-project" },
      { ...VALID_METADATA, workspace: "other-project" },
      { ...VALID_METADATA, workspace: null },
      { ...VALID_METADATA, serviceTokenData: null },
      { ...VALID_METADATA, expiresAt: "2000-01-01T00:00:00.000Z" },
      { ...VALID_METADATA, expiresAt: "not-a-date" },
      { ...VALID_METADATA, scopes: [{ secretPath: "/", environment: "dev" }] },
      { ...VALID_METADATA, scopes: [{ secretPath: "/*", environment: "prod" }] },
      { ...VALID_METADATA, scopes: [{ secretPath: "/", environment: "prod" }, { secretPath: "/extra", environment: "prod" }] },
      { ...VALID_METADATA, permissions: ["read", "write"] },
    ];
    try {
      for (const metadata of invalidMetadata) {
        metadataFixture = metadata;
        secretListRequests = 0;
        const { stdout, stderr } = await runBackfill();
        expect(stderr).toContain("service token scope verification failed");
        expect(secretListRequests).toBe(0);
        expect(stdout).not.toContain("stub-app-123");
      }
    } finally {
      metadataFixture = VALID_METADATA;
    }
  });

  it("rejects metadata redirects without forwarding the token or reading secrets", async () => {
    metadataRedirect = true;
    forwardedMetadataRedirectAuthorization = "";
    secretListRequests = 0;
    try {
      const { stdout, stderr } = await runBackfill();
      expect(stderr).toContain("service token scope verification failed");
      expect(forwardedMetadataRedirectAuthorization).toBe("");
      expect(secretListRequests).toBe(0);
      expect(stdout).not.toContain("stub-app-123");
    } finally {
      metadataRedirect = false;
    }
  });

  it("uses file-backed tokens for backfill without exporting them to the launcher", async () => {
    metadataFixture = VALID_METADATA;
    const home = mkdtempSync(join(tmpdir(), "clutch-file-backed-token-"));
    writeFileSync(join(home, "infisical.json"), `${JSON.stringify({
      projectId: "fixture-file-project",
      serviceToken: FILE_READ_TOKEN,
      writeServiceToken: FILE_WRITE_TOKEN,
    })}\n`, { mode: 0o600 });
    try {
      const { stdout } = await runBackfill({
        CLUTCH_HOME: home,
        INFISICAL_TOKEN: "",
        INFISICAL_WRITE_TOKEN: "",
        INFISICAL_PROJECT_ID: "",
      });
      expect(stdout).toContain("APP_ID=stub-app-123");
      expect(stdout).toContain("READ_SET=\n");
      expect(stdout).toContain("WRITE_SET=\n");
      expect(stdout).toContain("PROJECT_SET=\n");
      expect(stdout).not.toContain(FILE_READ_TOKEN);
      expect(stdout).not.toContain(FILE_WRITE_TOKEN);
      expect(seenAuthorization).toBe(expectedAuthorization(FILE_READ_TOKEN));
      expect(seenWorkspaceId).toBe("fixture-file-project");
    } finally {
      metadataFixture = VALID_METADATA;
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("treats whitespace-only environment credentials as unset and falls back to the file tuple", async () => {
    metadataFixture = VALID_METADATA;
    const home = mkdtempSync(join(tmpdir(), "clutch-whitespace-env-token-"));
    writeFileSync(join(home, "infisical.json"), `${JSON.stringify({
      projectId: "fixture-file-project",
      serviceToken: FILE_READ_TOKEN,
      writeServiceToken: FILE_WRITE_TOKEN,
    })}\n`, { mode: 0o600 });
    try {
      for (const whitespace of ["  \t\n", "\u00a0"]) {
        seenAuthorization = "";
        seenWorkspaceId = "";
        secretListRequests = 0;
        await runBackfill({
          CLUTCH_HOME: home,
          INFISICAL_TOKEN: whitespace,
          INFISICAL_WRITE_TOKEN: whitespace,
          INFISICAL_PROJECT_ID: whitespace,
        });
        expect(seenAuthorization).toBe(expectedAuthorization(FILE_READ_TOKEN));
        expect(seenWorkspaceId).toBe("fixture-file-project");
        expect(secretListRequests).toBe(1);
      }
    } finally {
      metadataFixture = VALID_METADATA;
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("does not pair an explicit read token with a saved file project", async () => {
    metadataFixture = VALID_METADATA;
    seenAuthorization = "";
    seenWorkspaceId = "";
    secretListRequests = 0;
    const home = mkdtempSync(join(tmpdir(), "clutch-partial-env-token-"));
    writeFileSync(join(home, "infisical.json"), `${JSON.stringify({
      projectId: "fixture-file-project",
      serviceToken: FILE_READ_TOKEN,
      writeServiceToken: FILE_WRITE_TOKEN,
    })}\n`, { mode: 0o600 });
    try {
      const { stdout } = await runBackfill({
        CLUTCH_HOME: home,
        INFISICAL_TOKEN: EXPLICIT_READ_TOKEN,
        INFISICAL_WRITE_TOKEN: "",
        INFISICAL_PROJECT_ID: " \t\n",
      });
      expect(stdout).toContain("READ_SET=yes");
      expect(stdout).toContain("WRITE_SET=\n");
      expect(stdout).toContain("PROJECT_SET=yes");
      expect(stdout).not.toContain(FILE_WRITE_TOKEN);
      expect(seenAuthorization).toBe(expectedAuthorization(EXPLICIT_READ_TOKEN));
      expect(seenWorkspaceId).toBe(PROJECT);
      expect(secretListRequests).toBe(1);
    } finally {
      metadataFixture = VALID_METADATA;
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("uses an explicit project override with an explicit read token", async () => {
    const explicitProject = "fixture-explicit-project";
    metadataFixture = { ...VALID_METADATA, projectId: explicitProject, workspace: explicitProject };
    const home = mkdtempSync(join(tmpdir(), "clutch-explicit-project-"));
    writeFileSync(join(home, "infisical.json"), `${JSON.stringify({
      projectId: "fixture-file-project",
      serviceToken: FILE_READ_TOKEN,
    })}\n`, { mode: 0o600 });
    try {
      await runBackfill({
        CLUTCH_HOME: home,
        INFISICAL_TOKEN: EXPLICIT_READ_TOKEN,
        INFISICAL_WRITE_TOKEN: "",
        INFISICAL_PROJECT_ID: explicitProject,
      });
      expect(seenAuthorization).toBe(expectedAuthorization(EXPLICIT_READ_TOKEN));
      expect(seenWorkspaceId).toBe(explicitProject);
    } finally {
      metadataFixture = VALID_METADATA;
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("matches the strict Node credential schema and drops only a malformed optional writer", async () => {
    const home = mkdtempSync(join(tmpdir(), "clutch-strict-bootstrap-token-"));
    const credentialsPath = join(home, "infisical.json");
    const noEnvCredentials = {
      CLUTCH_HOME: home,
      INFISICAL_TOKEN: "",
      INFISICAL_WRITE_TOKEN: "",
      INFISICAL_PROJECT_ID: "",
    };
    try {
      const invalidFiles = [
        { projectId: "fixture-file-project", serviceToken: FILE_READ_TOKEN, legacyField: "unsupported" },
        { projectId: 42, serviceToken: FILE_READ_TOKEN },
        { projectId: "fixture-file-project" },
      ];
      for (const contents of invalidFiles) {
        writeFileSync(credentialsPath, `${JSON.stringify(contents)}\n`, { mode: 0o600 });
        secretListRequests = 0;
        const rejected = await runBackfill(noEnvCredentials);
        expect(rejected.stdout).toContain("APP_ID=\n");
        expect(rejected.stdout).not.toContain(FILE_READ_TOKEN);
        expect(secretListRequests).toBe(0);
      }

      writeFileSync(credentialsPath, `${JSON.stringify({
        projectId: "fixture-file-project",
        serviceToken: FILE_READ_TOKEN,
        writeServiceToken: 42,
      })}\n`, { mode: 0o600 });
      secretListRequests = 0;
      const retainedRead = await runBackfill(noEnvCredentials);
      expect(retainedRead.stdout).toContain("APP_ID=stub-app-123");
      expect(retainedRead.stdout).toContain("READ_SET=\nWRITE_SET=\nPROJECT_SET=\n");
      expect(retainedRead.stdout).not.toContain(FILE_READ_TOKEN);
      expect(retainedRead.stdout).not.toContain(FILE_WRITE_TOKEN);
      expect(seenAuthorization).toBe(expectedAuthorization(FILE_READ_TOKEN));
      expect(secretListRequests).toBe(1);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("keeps file-backed bootstrap credentials out of the actual Bash-to-settings-route environment", async () => {
    const home = mkdtempSync(join(tmpdir(), "clutch-shell-route-seam-"));
    writeFileSync(join(home, "infisical.json"), `${JSON.stringify({
      projectId: "fixture-file-project",
      serviceToken: FILE_READ_TOKEN,
      writeServiceToken: FILE_WRITE_TOKEN,
    })}\n`, { mode: 0o600 });
    try {
      const { stdout } = await runShellRoute({
        CLUTCH_HOME: home,
        CLUTCH_ROUTE_TEST_BODY: JSON.stringify({ credentials: { projectId: "fixture-updated-project" } }),
      });
      const result = JSON.parse(stdout);
      expect(result.status).toBe(200);
      expect(result.body.credentialsSaved).toBe(true);
      expect(result.body.credentials.readTokenFromEnv).toBe(false);
      expect(stdout).not.toContain(FILE_READ_TOKEN);
      expect(stdout).not.toContain(FILE_WRITE_TOKEN);
      expect(JSON.parse(readFileSync(join(home, "infisical.json"), "utf8"))).toEqual({
        projectId: "fixture-updated-project",
        serviceToken: FILE_READ_TOKEN,
        writeServiceToken: FILE_WRITE_TOKEN,
      });
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("rejects a redirect without forwarding the service token", async () => {
    let forwardedAuthorization = "";
    const destination = createServer((req, res) => {
      forwardedAuthorization = String(req.headers.authorization ?? "");
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ secrets: [] }));
    });
    await new Promise<void>((resolve) => destination.listen(0, "127.0.0.1", resolve));
    const destinationPort = (destination.address() as { port: number }).port;
    const redirector = createServer((_req, res) => {
      res.writeHead(302, { location: `http://127.0.0.1:${destinationPort}/collect` }).end();
    });
    await new Promise<void>((resolve) => redirector.listen(0, "127.0.0.1", resolve));
    const redirectPort = (redirector.address() as { port: number }).port;
    try {
      const { stdout, stderr } = await runBackfill({ CLUTCH_INFISICAL_URL: `http://127.0.0.1:${redirectPort}` });
      expect(stderr).toContain("service token scope verification failed");
      expect(forwardedAuthorization).toBe("");
      expect(stdout).toContain("APP_ID=");
      expect(stdout).not.toContain("stub-app-123");
    } finally {
      await Promise.all([
        new Promise<void>((resolve) => redirector.close(() => resolve())),
        new Promise<void>((resolve) => destination.close(() => resolve())),
      ]);
    }
  });

  it("rejects non-loopback HTTP and URL components that could redirect token handling", async () => {
    const unsafeUrls = [
      "http://infisical.example",
      "https://user:password@127.0.0.1",
      "https://127.0.0.1/base",
      "https://127.0.0.1/?target=other",
    ];
    for (const CLUTCH_INFISICAL_URL of unsafeUrls) {
      const { stderr } = await runBackfill({ CLUTCH_INFISICAL_URL });
      expect(stderr).toContain("Infisical URL is invalid or unsafe");
    }
  });

  it("does not load service tokens from broad-permission or symlinked credential files", async () => {
    const home = mkdtempSync(join(tmpdir(), "clutch-unsafe-token-file-"));
    const path = join(home, "infisical.json");
    const body = JSON.stringify({ projectId: "fixture", serviceToken: FILE_READ_TOKEN });
    try {
      writeFileSync(path, body, { mode: 0o644 });
      chmodSync(path, 0o644);
      for (const kind of ["permissions", "symlink"]) {
        if (kind === "symlink") {
          rmSync(path);
          const target = join(home, "private.json");
          writeFileSync(target, body, { mode: 0o600 });
          symlinkSync(target, path);
        }
        const { stdout, stderr } = await runBackfill({
          CLUTCH_HOME: home,
          INFISICAL_TOKEN: "",
          CLUTCH_INFISICAL_URL: `http://127.0.0.1:${stubPort}`,
        });
        expect(stderr).not.toContain("backfilled from Infisical");
        expect(stdout).toContain("APP_ID=");
        expect(stdout).not.toContain("stub-app-123");
      }
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});
