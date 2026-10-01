#!/usr/bin/env node
/**
 * Build ~/Applications/Harness.app.  The production installer is
 * `scripts/install-dock-app.sh` (bundle id `com.simplewithus.harness.mac` so
 * existing Dock pins survive).  This TS entry execs that script.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SCRIPT = resolve(ROOT, "scripts", "install-dock-app.sh");

if (!existsSync(SCRIPT)) {
  process.stderr.write(`install-dock-app: missing ${SCRIPT}\n`);
  process.exit(1);
}

const child = spawn(SCRIPT, [], {
  stdio: "inherit",
  env: { ...process.env, CLUTCH_RUNTIME_ROOT: ROOT },
});
child.on("exit", (code) => process.exit(code ?? 0));
