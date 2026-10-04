#!/usr/bin/env node
/**
 * Idempotent recovery loop for Clutch web on CLUTCH_WEB_PORT (default 3180).
 *
 * Delegates to `scripts/ensure-web.sh` (pm2 `clutch-web`, 401 counts as up).
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { clutchWebPort } from "../shared/ports.ts";
import { initClutchSettings } from "../shared/clutchSettings.ts";

// Infisical is the sole source of truth for app settings (see INFISICAL.md).
await initClutchSettings();

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SCRIPT = resolve(ROOT, "scripts", "ensure-web.sh");

if (!existsSync(SCRIPT)) {
  process.stderr.write(`ensure-web: missing ${SCRIPT}\n`);
  process.exit(1);
}

const child = spawn(SCRIPT, [], {
  stdio: "inherit",
  env: { ...process.env, CLUTCH_RUNTIME_ROOT: ROOT, CLUTCH_WEB_PORT: clutchWebPort() },
});
child.on("exit", (code) => process.exit(code ?? 0));
