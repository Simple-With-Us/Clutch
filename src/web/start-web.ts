#!/usr/bin/env node
/**
 * Harness web UI — loopback bind + Tailscale Serve receiver.
 *
 * Same semantics as `scripts/start-web.sh`, which is what pm2 `harness-web`
 * actually runs today.  This TS entry is the npm bin (`harness-web`).
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { httpStatusIsUp } from "../shared/http-up.ts";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const HARNESS_SH = join(ROOT, "scripts", "harness.sh");
const HOST = process.env.DSH_WEB_HOST ?? "127.0.0.1";
const PORT = process.env.DSH_WEB_PORT ?? "3080";
const TAILNET_HOST = process.env.HARNESS_TAILNET_HOST ?? "macbook.boa-roygbiv.ts.net";
const TAILNET_IPV4 = process.env.HARNESS_TAILNET_IPV4 ?? "100.113.106.39";
const SERVE_TAILSCALE = join(ROOT, "scripts", "serve-tailscale.sh");

function log(line: string): void {
  process.stderr.write(`harness-web: ${line}\n`);
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

async function reclaimPort(port: string): Promise<void> {
  const holder = await holderOnPort(port);
  if (holder === null) return;
  const cmd = await readCommand(holder);
  if (cmd === null || (!cmd.includes("dsh") && !cmd.includes("harness"))) {
    log(`:${port} held by pid ${holder} (${cmd ?? "unknown"}) — not harness, refusing to reclaim`);
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

async function main(): Promise<void> {
  if (!existsSync(HARNESS_SH)) {
    log(`missing ${HARNESS_SH}`);
    process.exit(127);
  }

  await reclaimPort(PORT);

  if (existsSync(SERVE_TAILSCALE)) {
    await new Promise<void>((resolvePromise) => {
      const child = spawn(SERVE_TAILSCALE, [], {
        stdio: "inherit",
        env: {
          ...process.env,
          DSH_WEB_PORT: PORT,
          HARNESS_TAILNET_HOST: TAILNET_HOST,
          HARNESS_TAILNET_IPV4: TAILNET_IPV4,
          HARNESS_RUNTIME_ROOT: ROOT,
        },
      });
      child.on("exit", () => resolvePromise());
      child.on("error", () => resolvePromise());
    });
  }

  const args = [
    "web",
    "--no-open",
    "--host",
    HOST,
    "--port",
    PORT,
    "--trusted-host",
    "127.0.0.1",
    "--trusted-host",
    `127.0.0.1:${PORT}`,
    "--trusted-host",
    "localhost",
    "--trusted-host",
    `localhost:${PORT}`,
    "--trusted-host",
    TAILNET_HOST,
    "--trusted-host",
    `${TAILNET_HOST}:${PORT}`,
    "--trusted-host",
    TAILNET_IPV4,
    "--trusted-host",
    `${TAILNET_IPV4}:${PORT}`,
  ];

  log(`exec harness.sh web on ${HOST}:${PORT}`);
  const child = spawn(HARNESS_SH, args, {
    stdio: "inherit",
    env: { ...process.env, HARNESS_RUNTIME_ROOT: ROOT, DSH_HOME: process.env.DSH_HOME ?? `${process.env.HOME}/.dsh` },
  });
  child.on("exit", (code) => process.exit(code ?? 0));
  process.on("SIGINT", () => child.kill("SIGINT"));
  process.on("SIGTERM", () => child.kill("SIGTERM"));
}

await main();
