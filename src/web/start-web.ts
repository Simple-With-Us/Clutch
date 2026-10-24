#!/usr/bin/env node
/**
 * Clutch web UI — loopback bind + Tailscale Serve receiver.
 *
 * Same semantics as `scripts/start-web.sh`, which is what pm2 `clutch-web`
 * runs.  This TS entry is the npm bin (`clutch-web`).  Engine state lives in
 * $CLUTCH_HOME/dsh: `scripts/clutch.sh` forces DSH_HOME there, so this never
 * touches the vanilla ~/.dsh.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { httpStatusIsUp } from "../shared/http-up.ts";
import { clutchWebPort } from "../shared/ports.ts";
import { initClutchSettings, reloadSettingsOnSighup } from "../shared/clutchSettings.ts";
import { tailnetDnsName, trustedHostArgs } from "./pair-link.ts";
import { readTailnetStatus } from "./tailnet-status.ts";

// Load app settings from Infisical (sole source of truth) before any
// managed setting is read below.  Owned keys not already in process.env are
// backfilled from Infisical; explicitly-set env vars always win.
const clutchSettings = await initClutchSettings();
reloadSettingsOnSighup(clutchSettings);

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const CLUTCH_SH = join(ROOT, "scripts", "clutch.sh");
const HOST = process.env.CLUTCH_WEB_HOST ?? "127.0.0.1";
const PORT = clutchWebPort();
const SERVE_TAILSCALE = join(ROOT, "scripts", "serve-tailscale.sh");

function log(line: string): void {
  process.stderr.write(`clutch-web: ${line}\n`);
}

async function readCommand(pid: number): Promise<string | null> {
  return new Promise((resolvePromise) => {
    const child = spawn("/bin/ps", ["-o", "command=", "-p", String(pid)], { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    child.stdout.on("data", (chunk: Buffer) => {
      out += chunk.toString("utf8");
    });
    child.on("error", () => resolvePromise(null));
    child.on("exit", () => {
      const trimmed = out.trim();
      resolvePromise(trimmed.length > 0 ? trimmed : null);
    });
  });
}

async function holderOnPort(port: string): Promise<number | null> {
  return new Promise((resolvePromise) => {
    const child = spawn("/usr/sbin/lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-t"], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    let out = "";
    child.stdout.on("data", (chunk: Buffer) => {
      out += chunk.toString("utf8");
    });
    child.on("error", () => resolvePromise(null));
    child.on("exit", () => {
      const trimmed = out.trim();
      resolvePromise(trimmed.length > 0 ? Number(trimmed.split(/\s+/)[0]) : null);
    });
  });
}

async function probe(url: string): Promise<boolean> {
  return new Promise((resolvePromise) => {
    const child = spawn("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "8", url], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    let out = "";
    child.stdout.on("data", (chunk: Buffer) => {
      out += chunk.toString("utf8");
    });
    child.on("error", () => resolvePromise(false));
    child.on("exit", () => {
      const code = Number.parseInt(out.trim(), 10);
      resolvePromise(httpStatusIsUp(code));
    });
  });
}

/** Reclaim the port only from a Clutch process; anything else exits 3. */
async function reclaimPort(port: string): Promise<void> {
  const holder = await holderOnPort(port);
  if (holder === null) return;
  const cmd = await readCommand(holder);
  // Case-insensitive: a checkout named `Clutch` is still ours.
  if (cmd === null || !cmd.toLowerCase().includes("clutch")) {
    log(`:${port} held by pid ${holder} (${cmd ?? "unknown"}) — not clutch, refusing to reclaim`);
    process.exit(3);
  }
  if (await probe(`http://${HOST}:${PORT}/`)) {
    log(`:${port} already healthy (pid ${holder}), skipping reclaim`);
    process.exit(0);
  }
  log(`reclaiming pid ${holder} on :${port}`);
  try {
    process.kill(holder, "SIGTERM");
  } catch {
    /* already gone */
  }
  for (let i = 0; i < 8; i += 1) {
    await new Promise((r) => setTimeout(r, 500));
    if ((await holderOnPort(port)) === null) return;
  }
  try {
    process.kill(holder, "SIGKILL");
  } catch {
    /* already gone */
  }
  await new Promise((r) => setTimeout(r, 500));
}

/**
 * This Mac's MagicDNS name, so /api accepts the Host the iOS app sends over
 * Tailscale.  CLUTCH_TAILNET_HOST overrides the detected name.
 */
async function detectTailnetHost(): Promise<string | null> {
  const override = process.env.CLUTCH_TAILNET_HOST?.trim();
  if (override) return override;

  // macOS routinely starts Tailscale minutes after login, so a single read at
  // boot can come back empty and leave the server trusting loopback only, which
  // 403s every /api request from the iOS app until the next restart.  Retry for
  // a bounded window; scripts/lib/clutch-tailnet-host.sh reconciles the slower
  // case by restarting once the name actually appears.  Each read is itself
  // bounded (readTailnetStatus), so a wedged tailscaled counts as "not ready"
  // instead of hanging this wait for good.
  const waitSeconds = Number(process.env.CLUTCH_TAILNET_WAIT_SECONDS ?? 30);
  const deadline = Date.now() + (Number.isFinite(waitSeconds) ? waitSeconds : 30) * 1000;

  for (;;) {
    const host = await readTailnetHost();
    if (host) return host;
    if (Date.now() >= deadline) return null;
    await new Promise((r) => setTimeout(r, 1000));
  }
}

function readTailnetHost(): Promise<string | null> {
  // The read is bounded: `tailscale status` can block forever on a wedged
  // tailscaled, and this runs before the sidecar listens, so an unbounded call
  // would keep the server from ever starting.
  return readTailnetStatus().then((status) => tailnetDnsName(status));
}

async function main(): Promise<void> {
  if (!existsSync(CLUTCH_SH)) {
    log(`missing ${CLUTCH_SH}`);
    process.exit(127);
  }

  await reclaimPort(PORT);

  if (existsSync(SERVE_TAILSCALE)) {
    await new Promise<void>((resolvePromise) => {
      const child = spawn(SERVE_TAILSCALE, [], {
        stdio: "inherit",
        env: { ...process.env, CLUTCH_WEB_PORT: PORT, CLUTCH_RUNTIME_ROOT: ROOT },
      });
      child.on("exit", () => resolvePromise());
      child.on("error", () => resolvePromise());
    });
  }

  // Native-chat SSE sidecar (the iOS Chat tab's transport).  Detached: the
  // exec below replaces this process, so the bridge must outlive it.
  // Disable with CLUTCH_CHAT_BRIDGE=0.
  const CHAT_BRIDGE = join(ROOT, "scripts", "chat-bridge.sh");
  if (process.env.CLUTCH_CHAT_BRIDGE !== "0" && existsSync(CHAT_BRIDGE)) {
    const bridge = spawn(CHAT_BRIDGE, [], {
      stdio: "ignore",
      detached: true,
      env: { ...process.env, CLUTCH_WEB_PORT: PORT, CLUTCH_RUNTIME_ROOT: ROOT },
    });
    bridge.on("error", () => log("chat-bridge failed to start"));
    bridge.unref();
  }

  const extraHosts = (process.env.CLUTCH_TRUSTED_HOSTS ?? "").split(",");
  const tailnetHost = await detectTailnetHost();
  if (!tailnetHost && !process.env.CLUTCH_TAILNET_HOST?.trim()) {
    log("Tailscale not ready; /api will reject remote hosts (403) until it is");
  }
  const args = [
    "web",
    "--no-open",
    "--host",
    HOST,
    "--port",
    PORT,
    ...trustedHostArgs(["127.0.0.1", "localhost", tailnetHost, process.env.CLUTCH_TAILNET_IPV4, ...extraHosts], PORT),
  ];

  log(`exec clutch.sh web on ${HOST}:${PORT}`);
  const child = spawn(CLUTCH_SH, args, {
    stdio: "inherit",
    env: { ...process.env, CLUTCH_RUNTIME_ROOT: ROOT, CLUTCH_WEB_HOST: HOST, CLUTCH_WEB_PORT: PORT },
  });
  child.on("exit", (code) => process.exit(code ?? 0));
  process.on("SIGINT", () => child.kill("SIGINT"));
  process.on("SIGTERM", () => child.kill("SIGTERM"));
}

await main();
