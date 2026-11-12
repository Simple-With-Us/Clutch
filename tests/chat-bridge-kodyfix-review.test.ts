/**
 * The review findings on the sidecar's engine catalog and its trust
 * boundary.
 *
 * Six things are checked here, one per finding:
 *
 *   1. The Muse login files do not count as a sign-in for the spawned host.
 *   2. A MiniMax Code credential that somebody else can read is refused.
 *   3. A reachable dsh host satisfies the hosted engines.
 *   4. A cached descriptor carries the current note, not a stale one.
 *   5. The availability answers are reused instead of probed again.
 *   6. The inbound headers are parsed before anything believes them.
 *
 * The unit checks drive the exported functions with a fixture host, so every
 * fact they read is a file.  The end-to-end checks run the real sidecar,
 * because the catalog and the trust boundary only meet in the request path.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  cachedAnswer,
  engineAvailability,
  parseInboundHeaders,
  withCurrentNotes,
  type EngineAvailabilityContext,
} from "../src/web/chat-bridge.ts";
import type { EngineCatalog, EngineDescriptor } from "../src/web/engine-catalog.ts";
import type { Engine } from "../src/shared/engine-types.ts";

const TOKEN = `kodyfix-review-${"x".repeat(48)}`;
const TSX = join(process.cwd(), "node_modules", ".bin", "tsx");
const BRIDGE = join(process.cwd(), "src", "web", "chat-bridge.ts");

const temps: string[] = [];

afterEach(() => {
  while (temps.length > 0) rmSync(temps.pop()!, { recursive: true, force: true });
});

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "clutch-kodyfix-"));
  temps.push(dir);
  return dir;
}

/** A file a launcher could run: present and executable. */
function executable(path: string, body = "#!/bin/sh\nexit 0\n"): string {
  writeFileSync(path, body);
  chmodSync(path, 0o755);
  return path;
}

interface Fixture {
  context: EngineAvailabilityContext;
  home: string;
  credentialFile: string;
}

/**
 * A host with the launchers and the interpreter the engines need.
 *
 * Every fact the check reads is a file, so the check can be exercised
 * without touching the machine the test runs on.
 */
function fixture(options: { python?: boolean } = {}): Fixture {
  const root = tempDir();
  const home = join(root, "home");
  const bin = join(root, "bin");
  mkdirSync(home, { recursive: true });
  mkdirSync(bin, { recursive: true });
  executable(join(bin, "muse"));
  executable(join(bin, "mcode"));
  if (options.python !== false) executable(join(bin, "python3"));
  const credentialFile = join(home, ".clutch", "dsh", ".credentials.yaml");
  return {
    home,
    credentialFile,
    context: {
      env: { PATH: bin, HOME: home },
      launchers: {
        deepseek: { command: process.execPath, args: [] },
        minimax: { command: process.execPath, args: [] },
        mcode: { command: "mcode", args: ["acp"] },
        muse: { command: process.execPath, args: [] },
      },
      credentialFile,
    },
  };
}

describe("the Muse sign-in the spawned host can use", () => {
  it("does not count the login files as a sign-in", async () => {
    const host = fixture();

    // The CLI login file and the provider catalog are both on disk.  The
    // spawned host reads neither: the login names a keychain entry a
    // background session cannot open, and the catalog only says which
    // models an account may use.
    mkdirSync(join(host.home, ".config", "muse"), { recursive: true });
    writeFileSync(join(host.home, ".config", "muse", "auth.json"), "{}\n");
    mkdirSync(join(host.home, ".local", "share", "muse", "model-catalog"), { recursive: true });
    writeFileSync(join(host.home, ".local", "share", "muse", "model-catalog", "catalog.json"), "{}\n");

    const muse = await engineAvailability("muse", host.context);

    // The engine stays in the picker, because the sign-in lives behind
    // selecting it: dropping it would take the owner's only way to sign
    // in.
    expect(muse.available).toBe(true);
    expect(muse.note).toContain("muse login");
    // The note points at the desktop helper, which is the route that uses
    // the saved login, and at the key the spawned host reads.
    expect(muse.note).toContain("desktop helper");
    expect(muse.note).toContain("META_API_KEY");
  });

  it("counts the key the spawned host reads as a sign-in", async () => {
    const host = fixture();
    const withKey = {
      ...host.context,
      settings: { get: (key: string) => (key === "META_API_KEY" ? "fixture" : "") },
    };

    await expect(engineAvailability("muse", withKey)).resolves.toMatchObject({ available: true });
    const muse = await engineAvailability("muse", withKey);
    expect(muse.note).toBeUndefined();
  });
});

describe("the MiniMax Code credential", () => {
  it("refuses a credential that somebody else can read", async () => {
    const host = fixture();
    const store = join(host.home, ".minimax", "auth", "prod", "en", "mcode-public");
    mkdirSync(store, { recursive: true });
    const credential = join(store, "auth.json");
    writeFileSync(credential, "{}\n");
    // The mode is set explicitly: the umask of the test run would decide
    // it otherwise, and the check is about the mode.
    chmodSync(credential, 0o660);

    const mcode = await engineAvailability("mcode", host.context);
    expect(mcode.available).toBe(false);
    expect(mcode.note).toContain("chmod 600");
    expect(mcode.note).toContain(credential);

    // The same file, private: MiniMax Code uses it and the turn runs.
    chmodSync(credential, 0o600);
    await expect(engineAvailability("mcode", host.context)).resolves.toMatchObject({ available: true });
  });

  it("still asks for a sign-in when there is no credential at all", async () => {
    const host = fixture();

    const mcode = await engineAvailability("mcode", host.context);
    expect(mcode.available).toBe(false);
    expect(mcode.note).toContain("mcode login");
  });
});

describe("the hosted engines and the host that runs them", () => {
  it("keeps them in the picker when a reachable host can run them", async () => {
    const host = fixture({ python: false });
    const withKey = {
      ...host.context,
      env: { ...host.context.env, DEEPSEEK_API_KEY: "fixture", MINIMAX_API_KEY: "fixture" },
    };

    // Without a host the bridge is the only path, and the bridge needs an
    // interpreter.
    const fallback = await engineAvailability("deepseek", withKey);
    expect(fallback.available).toBe(false);
    expect(fallback.note).toContain("Python 3");

    // A host that answers runs the turn itself, so the interpreter for the
    // fallback bridge is not what the engine needs.
    const hosted = await engineAvailability("deepseek", { ...withKey, hostReachable: true });
    expect(hosted.available).toBe(true);
    expect(hosted.note).toBeUndefined();

    const hostedMinimax = await engineAvailability("minimax", { ...withKey, hostReachable: true });
    expect(hostedMinimax.available).toBe(true);
    expect(hostedMinimax.note).toBeUndefined();
  });
});

/** One descriptor, as the catalog publishes it. */
function descriptor(engine: Engine, note?: string): EngineDescriptor {
  return {
    id: engine,
    label: engine,
    available: true,
    supportsThreads: true,
    models: [],
    effortLevels: [],
    effortConfigId: "reasoning_effort",
    modelConfigId: "model",
    ...(note ? { note } : {}),
  };
}

describe("the notes on a cached descriptor", () => {
  const stale = "DeepSeek needs an API key.\u00A0 Add DEEPSEEK_API_KEY in Clutch settings.";
  const current = "DeepSeek needs Python 3 to run its bridge.";

  it("publishes the current note and drops a stale one", () => {
    const catalog: EngineCatalog = {
      engines: [
        descriptor("deepseek", stale),
        descriptor("muse", "Includes models from the local Muse provider catalog."),
      ],
    };
    const published = new Map<Engine, Set<string>>([["deepseek", new Set([stale])]]);

    // The owner signed in: the current note replaces the one the cached
    // descriptor was built with.
    const withNote = withCurrentNotes(catalog, { deepseek: current }, published);
    expect(withNote.engines.find((entry) => entry.id === "deepseek")?.note).toBe(current);

    // The note is gone: the stale one is dropped rather than left behind.
    const withoutNote = withCurrentNotes(catalog, {}, published);
    expect(withoutNote.engines.find((entry) => entry.id === "deepseek")?.note).toBeUndefined();

    // A note the catalog wrote itself is not the sidecar's, so it stays.
    expect(withoutNote.engines.find((entry) => entry.id === "muse")?.note)
      .toBe("Includes models from the local Muse provider catalog.");
  });
});

describe("the availability answers", () => {
  it("reuses an answer until it expires", () => {
    const value = { deepseek: { available: true } };

    expect(cachedAnswer(null, 1000, 0)).toBeNull();
    expect(cachedAnswer({ at: 0, value }, 1000, 999)).toBe(value);
    expect(cachedAnswer({ at: 0, value }, 1000, 1000)).toBeNull();
    expect(cachedAnswer({ at: 0, value }, 1000, 5000)).toBeNull();
  });
});

describe("the inbound headers", () => {
  it("refuses a header value that is not a string", () => {
    const parsed = parseInboundHeaders({ host: "127.0.0.1", authorization: ["Bearer one", "Bearer two"] });

    expect(parsed).toEqual({ ok: false, error: "malformed request headers" });
  });

  it("keeps the three headers it reads and strips the rest", () => {
    const parsed = parseInboundHeaders({
      host: "127.0.0.1",
      authorization: "Bearer fixture",
      cookie: "a=1",
      "x-forwarded-for": "10.0.0.1",
    });

    expect(parsed).toEqual({
      ok: true,
      headers: { host: "127.0.0.1", authorization: "Bearer fixture", cookie: "a=1" },
    });
  });

  it("accepts a request that carries no headers at all", () => {
    expect(parseInboundHeaders({})).toEqual({ ok: true, headers: {} });
  });
});

/* ---------------------------------------------------------------------- */
/* The sidecar itself: the catalog and the trust boundary only meet there. */
/* ---------------------------------------------------------------------- */

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
  throw new Error("the sidecar did not start");
}

interface Sidecar {
  port: number;
  /** The home directory the sidecar runs with. */
  home: string;
  stop(): void;
}

/** Run the sidecar the way it runs in production, on a port of its own. */
async function startSidecar(env: Record<string, string>): Promise<Sidecar> {
  const home = tempDir();
  const tokenFile = join(home, "chat-token");
  writeFileSync(tokenFile, `${TOKEN}\n`, { mode: 0o600 });
  const port = await freePort();
  let stderr = "";
  const child: ChildProcess = spawn(TSX, [BRIDGE], {
    env: {
      ...process.env,
      HOME: home,
      CLUTCH_HOME: join(home, ".clutch"),
      CLUTCH_CHAT_PORT: String(port),
      CLUTCH_CHAT_TOKEN_FILE: tokenFile,
      CLUTCH_SESSION_META_FILE: join(home, "session-meta.json"),
      CLUTCH_DSH_HOME: join(home, ".clutch", "dsh"),
      CLUTCH_TAILNET_HOST: "loopback-test.ts.net",
      ...env,
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  child.stderr?.on("data", (chunk: Buffer) => {
    stderr += String(chunk);
  });
  try {
    await waitFor(`http://127.0.0.1:${port}/clutch/v1/health`, { Authorization: `Bearer ${TOKEN}` });
  } catch (err) {
    child.kill("SIGKILL");
    throw new Error(`the sidecar did not start: ${stderr.slice(0, 400)}`);
  }
  return {
    port,
    home,
    stop: () => {
      child.kill("SIGKILL");
    },
  };
}

/** The catalog the sidecar publishes. */
async function readCatalog(port: number, query = ""): Promise<EngineCatalog> {
  const response = await fetch(`http://127.0.0.1:${port}/clutch/v1/engines${query}`, {
    headers: { Authorization: `Bearer ${TOKEN}` },
  });
  if (response.status !== 200) throw new Error(`the catalog answered ${response.status}`);
  return (await response.json()) as EngineCatalog;
}

/**
 * A PATH the sidecar runs with.
 *
 * Node is on it because the launcher script needs it, and the interpreter
 * is there only when the test wants the bridge path to be possible.
 */
function sidecarBin(options: { python?: boolean } = {}): string {
  const bin = join(tempDir(), "bin");
  mkdirSync(bin, { recursive: true });
  symlinkSync(process.execPath, join(bin, "node"));
  if (options.python !== false) executable(join(bin, "python3"));
  return bin;
}

describe("the sidecar's catalog", () => {
  it("reuses the availability answers instead of probing again for a warm catalog", async () => {
    const bin = sidecarBin();
    const sidecar = await startSidecar({ PATH: bin });
    try {
      const first = await readCatalog(sidecar.port, "?engine=deepseek");
      const deepseek = first.engines.find((entry) => entry.id === "deepseek");
      expect(deepseek?.available).toBe(false);
      expect(deepseek?.note).toContain("DEEPSEEK_API_KEY");

      // The credential store appears: the dsh bridge would find the key
      // now.  The answer is reused for as long as the catalog is cached,
      // so the probes are not repeated for a catalog that is about to be
      // reused anyway.
      const store = join(sidecar.home, ".clutch", "dsh");
      mkdirSync(store, { recursive: true });
      writeFileSync(join(store, ".credentials.yaml"), "# a credential store lives here\n");

      const second = await readCatalog(sidecar.port);
      const afterCredential = second.engines.find((entry) => entry.id === "deepseek");
      expect(afterCredential?.available).toBe(false);
      expect(afterCredential?.note).toContain("DEEPSEEK_API_KEY");
    } finally {
      sidecar.stop();
    }
  }, 60_000);

  it("keeps the hosted engines when the dsh host answers", async () => {
    // A host that answers the launch handshake, the way the dsh host does.
    let hits = 0;
    const host = createServer((_req, res) => {
      hits += 1;
      res.writeHead(200, { "content-type": "text/plain", "set-cookie": "sid=fixture" });
      res.end("ok");
    });
    const hostPort = await freePort();
    await new Promise<void>((resolve) => host.listen(hostPort, "127.0.0.1", () => resolve()));
    const launchUrlFile = join(tempDir(), "web-launch-url");
    writeFileSync(launchUrlFile, `http://127.0.0.1:${hostPort}/launch?token=fixture\n`);

    // No interpreter on PATH: the bridge could not run a turn, so only the
    // host can.
    const bin = sidecarBin({ python: false });
    const sidecar = await startSidecar({
      PATH: bin,
      CLUTCH_LAUNCH_URL_FILE: launchUrlFile,
      DEEPSEEK_API_KEY: "fixture",
    });
    try {
      const catalog = await readCatalog(sidecar.port);
      const deepseek = catalog.engines.find((entry) => entry.id === "deepseek");
      expect(deepseek?.available).toBe(true);
      expect(deepseek?.note).toBeUndefined();
      // The sidecar asked the host, so it knows the host can run the turn.
      expect(hits).toBeGreaterThan(0);
    } finally {
      sidecar.stop();
      host.close();
    }
  }, 60_000);
});
