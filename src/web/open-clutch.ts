#!/usr/bin/env node
/**
 * Activate the Clutch Dock app window, or fall back to opening the URL.
 * On-disk name is `Clutch.app`; bundle id `codes.clutch.macos`.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { clutchWebPort } from "../shared/ports.ts";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SCRIPT = resolve(ROOT, "scripts", "open-clutch.sh");
const APP = join(homedir(), "Applications", "Clutch.app");

function log(line: string): void {
  process.stderr.write(`open-clutch: ${line}\n`);
}

if (existsSync(SCRIPT)) {
  const child = spawn(SCRIPT, [], {
    stdio: "inherit",
    env: { ...process.env, CLUTCH_RUNTIME_ROOT: ROOT },
  });
  child.on("exit", (code) => process.exit(code ?? 0));
} else if (existsSync(APP)) {
  const child = spawn("/usr/bin/open", ["-a", APP], { stdio: "ignore" });
  child.on("exit", (code) => {
    log(`activated ${APP}`);
    process.exit(code ?? 0);
  });
} else {
  const url = process.env.CLUTCH_WEB_URL ?? `http://127.0.0.1:${clutchWebPort()}/`;
  spawn("/usr/bin/open", [url], { stdio: "ignore" }).on("exit", () => process.exit(0));
}
