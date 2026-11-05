import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

const TOKEN = `engine-validation-test-${"x".repeat(48)}`;
const TSX = join(process.cwd(), "node_modules", ".bin", "tsx");
const BRIDGE = join(process.cwd(), "src", "web", "chat-bridge.ts");

let sidecar: ChildProcess | null = null;
let port = 0;
let tempDir = "";
let tokenFile = "";
/** Written when the sidecar actually starts an engine. */
let marker = "";

function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const value = typeof address === "object" && address ? address.port : 0;
      server.close(() => resolve(value));
    });
  });
}

async function waitFor(url: string, headers: Record<string, string>): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < 30_000) {
    try {
      const response = await fetch(url, { headers });
      if (response.status === 200) return;
    } catch {
      /* the sidecar is not listening yet */
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("sidecar did not start");
}

function url(path: string): string {
  return `http://127.0.0.1:${port}${path}`;
}

function headers(): Record<string, string> {
  return { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" };
}

beforeAll(async () => {
  tempDir = mkdtempSync(join(tmpdir(), "clutch-engine-validation-"));
  tokenFile = join(tempDir, "chat-token");
  marker = join(tempDir, "engine-started");
  writeFileSync(tokenFile, `${TOKEN}\n`, { mode: 0o600 });
  // A launcher that records that it ran, so the test can tell "the turn was
  // routed" from "the request was refused before routing".
  const launcher = join(tempDir, "deepseek-stub.sh");
  writeFileSync(launcher, `#!/bin/sh\ntouch ${JSON.stringify(marker)}\nexit 0\n`, { mode: 0o755 });
  port = await freePort();
  sidecar = spawn(TSX, [BRIDGE], {
    env: {
      ...process.env,
      HOME: tempDir,
      CLUTCH_HOME: tempDir,
      CLUTCH_CHAT_PORT: String(port),
      CLUTCH_CHAT_TOKEN_FILE: tokenFile,
      CLUTCH_SESSION_META_FILE: join(tempDir, "session-meta.json"),
      CLUTCH_DSH_HOME: join(tempDir, "absent-dsh-home"),
      CLUTCH_TAILNET_HOST: "loopback-test.ts.net",
      CLUTCH_CHAT_LAUNCHER_DEEPSEEK: launcher,
    },
    stdio: ["ignore", "ignore", "ignore"],
  });
  await waitFor(url("/clutch/v1/health"), headers());
}, 60_000);

afterAll(() => {
  sidecar?.kill("SIGKILL");
  rmSync(tempDir, { recursive: true, force: true });
});

describe("chat engine validation", () => {
  it("refuses an engine the sidecar does not know, before any turn starts", async () => {
    const response = await fetch(url("/clutch/v1/chat"), {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ prompt: "hello", engine: "minmax" }),
    });

    expect(response.status).toBe(400);
    const body = await response.json() as { error?: string; engine?: string; knownEngines?: string[] };
    expect(body.error).toBe("unknown engine");
    expect(body.engine).toBe("minmax");
    expect(body.knownEngines).toEqual(["deepseek", "minimax", "mcode", "muse"]);
    // The turn never started: a typo must not run on another provider.
    expect(existsSync(marker)).toBe(false);
  });

  it("still routes a request that names no engine", async () => {
    const response = await fetch(url("/clutch/v1/chat"), {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ prompt: "hello" }),
    });

    expect(response.status).toBe(200);
    await response.body?.cancel();
    await expect.poll(() => existsSync(marker), { timeout: 10_000, interval: 50 }).toBe(true);
  });

  it("refuses an engine name that is malformed, before any turn starts", async () => {
    // The marker is cleared first: the test above really did start a turn,
    // and this one has to show that no new one began.
    rmSync(marker, { force: true });

    // The name is validated by schema before it reaches the routing, so a
    // value that is not a short engine id never travels on to the provider.
    const oversized = await fetch(url("/clutch/v1/chat"), {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ prompt: "hello", engine: "e".repeat(200) }),
    });
    expect(oversized.status).toBe(400);
    const oversizedBody = await oversized.json() as { error?: string; engine?: string };
    expect(oversizedBody.error).toBe("unknown engine");
    expect(oversizedBody.engine).toHaveLength(40);

    const notAString = await fetch(url("/clutch/v1/chat"), {
      method: "POST",
      headers: headers(),
      body: JSON.stringify({ prompt: "hello", engine: 42 }),
    });
    expect(notAString.status).toBe(400);

    // The turn never started.
    expect(existsSync(marker)).toBe(false);
  });
});
