#!/usr/bin/env node
/**
 * Re-assert the Tailscale Serve mapping for Clutch web.
 *
 * Same mapping as `scripts/serve-tailscale.sh`:
 * `tailscale serve --bg --https=PORT http://127.0.0.1:PORT`, with PORT from
 * CLUTCH_WEB_PORT (default 3180).  Idempotent.  Does not enable Funnel
 * (tailnet only).  A missing binary is non-fatal.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

import { clutchWebPort } from "../shared/ports.ts";
import { tailnetDnsName } from "./pair-link.ts";

const PORT = clutchWebPort();

const TAILSCALE_PATHS = [
  "/Applications/Tailscale.app/Contents/MacOS/tailscale",
  "/opt/homebrew/bin/tailscale",
  "/usr/local/bin/tailscale",
];

function findTailscale(): string | null {
  for (const candidate of TAILSCALE_PATHS) {
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

async function run(bin: string, args: string[]): Promise<number> {
  return new Promise((resolvePromise) => {
    const child = spawn(bin, args, { stdio: "inherit" });
    child.on("error", () => resolvePromise(-1));
    child.on("exit", (code) => resolvePromise(code ?? -1));
  });
}

/** This Mac's MagicDNS name, unless CLUTCH_TAILNET_HOST overrides it. */
async function tailnetHost(bin: string): Promise<string | null> {
  const override = process.env.CLUTCH_TAILNET_HOST?.trim();
  if (override) return override;
  return new Promise((resolvePromise) => {
    const child = spawn(bin, ["status", "--self", "--json"], { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    child.stdout.on("data", (chunk: Buffer) => {
      out += chunk.toString("utf8");
    });
    child.on("error", () => resolvePromise(null));
    child.on("exit", () => {
      try {
        resolvePromise(tailnetDnsName(JSON.parse(out)));
      } catch {
        resolvePromise(null);
      }
    });
  });
}

async function main(): Promise<void> {
  const bin = findTailscale();
  if (bin === null) {
    process.stderr.write(`serve-tailscale: tailscale binary not found at ${TAILSCALE_PATHS.join(", ")}\n`);
    process.exit(0);
  }

  const target = `http://127.0.0.1:${PORT}`;
  const host = (await tailnetHost(bin)) ?? "<this Mac's MagicDNS name>";
  const url = `https://${host}:${PORT}`;
  process.stderr.write(`serve-tailscale: mapping ${url} -> ${target}\n`);
  const code = await run(bin, ["serve", "--bg", `--https=${PORT}`, target]);
  if (code !== 0) {
    process.stderr.write(`serve-tailscale: set returned ${code}\n`);
    process.exit(code);
  }
  process.stderr.write(`serve-tailscale: ${url} -> ${target} (tailnet only)\n`);
}

await main();
