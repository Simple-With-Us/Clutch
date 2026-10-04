#!/usr/bin/env node
/**
 * clutch-pair-ios — pair the Clutch iOS app with this Mac's clutch web.
 *
 * Reads the current launch URL that `scripts/capture-launch-url.cjs` saves
 * (`~/.dsh/web-launch-url`), points it at this Mac's Tailscale name, and
 * hands it to the phone as a `clutch://pair?url=…` link:
 *
 *   clutch-pair-ios              copy the link to the clipboard (Universal
 *                                 Clipboard reaches the iPhone) and open a QR
 *                                 code to scan with the app
 *   clutch-pair-ios --simulator  open the link in the booted iOS Simulator,
 *                                 pointed at http://127.0.0.1:<port>
 *   clutch-pair-ios --print      print the link (it contains the launch token)
 *
 * The link stays valid until clutch web restarts; the cookie it mints on the
 * phone lasts 30 days.  The token is never printed unless --print is given.
 */
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { homedir, hostname, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { clutchWebPort } from "../shared/ports.ts";
import { initClutchSettings } from "../shared/clutchSettings.ts";
import { LEGACY_TAILNET_HOST, pairingLink, tailnetDnsName } from "./pair-link.ts";

// Infisical is the sole source of truth for app settings (see INFISICAL.md).
await initClutchSettings();

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const PORT = clutchWebPort();
const CLUTCH_HOME = process.env.CLUTCH_HOME ?? join(homedir(), ".clutch");
const LAUNCH_URL_FILE = process.env.CLUTCH_LAUNCH_URL_FILE ?? join(CLUTCH_HOME, "web-launch-url");

function log(line: string): void {
  process.stderr.write(`clutch-pair-ios: ${line}\n`);
}

function detectTailnetHost(): string {
  if (process.env.CLUTCH_TAILNET_HOST) return process.env.CLUTCH_TAILNET_HOST;
  const result = spawnSync("tailscale", ["status", "--self", "--json"], { encoding: "utf8", timeout: 30000 });
  if (result.status === 0) {
    try {
      const name = tailnetDnsName(JSON.parse(result.stdout));
      if (name) return name;
    } catch {
      /* fall through */
    }
  }
  log(`could not read this Mac's Tailscale name; falling back to ${LEGACY_TAILNET_HOST}`);
  return LEGACY_TAILNET_HOST;
}

function readLaunchUrl(): string {
  if (!existsSync(LAUNCH_URL_FILE)) {
    log(`${LAUNCH_URL_FILE} not found — start clutch web first (pm2 clutch-web).`);
    process.exit(2);
  }
  return readFileSync(LAUNCH_URL_FILE, "utf8").trim();
}

function run(cmd: string, args: string[], input?: string): boolean {
  const result = spawnSync(cmd, args, { input, stdio: [input === undefined ? "ignore" : "pipe", "ignore", "inherit"] });
  return result.status === 0;
}

function showQr(link: string): void {
  const dir = mkdtempSync(join(tmpdir(), "clutch-pair-"));
  const png = join(dir, "clutch-pairing-code.png");
  const script = join(ROOT, "scripts", "qr-png.swift");
  // The link goes over stdin, never argv, so the token stays out of the process table.
  if (!run("/usr/bin/swift", [script, png], link)) {
    log("could not render the QR code (needs Xcode command line tools); the link is still on the clipboard.");
    return;
  }
  spawn("/usr/bin/open", [png], { stdio: "ignore", detached: true }).unref();
  log(`opened the pairing code: ${png}`);
}

function main(): void {
  const args = new Set(process.argv.slice(2));
  if (args.has("-h") || args.has("--help")) {
    process.stdout.write(
      [
        "usage: clutch-pair-ios [--simulator | --print]",
        "  (default)    copy the pairing link to the clipboard and open a QR code for the Clutch iOS app",
        "  --simulator  open the pairing link in the booted iOS Simulator (http://127.0.0.1:<port>)",
        "  --print      print the pairing link (contains the launch token)",
        "",
      ].join("\n"),
    );
    return;
  }
  const launchUrl = readLaunchUrl();
  const simulator = args.has("--simulator");
  const origin = simulator ? `http://127.0.0.1:${PORT}` : `https://${detectTailnetHost()}:${PORT}`;
  const name = simulator ? "This Mac" : hostname().replace(/\.local$/, "");
  const link = pairingLink({ launchUrl, origin, name });

  if (args.has("--print")) {
    process.stdout.write(`${link}\n`);
    return;
  }
  if (simulator) {
    if (!run("xcrun", ["simctl", "openurl", "booted", link])) {
      log("no booted simulator accepted the link (is the Clutch app installed?).");
      process.exit(1);
    }
    log(`paired the booted simulator with ${origin}.`);
    return;
  }
  if (run("/usr/bin/pbcopy", [], link)) {
    log("copied the pairing link to the clipboard — on the iPhone, open Clutch and tap Paste Pairing Link.");
  }
  showQr(link);
  log(`the app will open ${origin} over Tailscale; the link works until clutch web restarts.`);
}

main();
