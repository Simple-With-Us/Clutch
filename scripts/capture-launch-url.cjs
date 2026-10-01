#!/usr/bin/env node
/*
 * capture-launch-url.cjs — run dsh web through a Node shim that tees the
 * launch URL to $CLUTCH_LAUNCH_URL_FILE (default: $CLUTCH_HOME/web-launch-url,
 * i.e. ~/.clutch/web-launch-url) while passing the rest of stdout straight
 * through to pm2 logs.
 *
 * Why: dsh web 0.1.5-rc.2+ mints a per-process launch token on startup and
 * prints it on the `dsh web: <URL>` line as part of the connection's
 * BrowserAuth handshake.  pm2 starts dsh with `--no-open` so the browser
 * doesn't open, but the print still goes to stdout.  Until something
 * reads that URL and visits it (once), the Dock app's WKWebView has no
 * signed cookie and gets a 401.  This shim is the something.
 *
 * Usage:
 *   node capture-launch-url.cjs <dsh-binary> [dsh-args...]
 *
 * Env:
 *   CLUTCH_LAUNCH_URL_FILE  override the destination path.
 *   CLUTCH_HOME             default file parent if CLUTCH_LAUNCH_URL_FILE unset.
 *
 * The `dsh web:` line format is the upstream engine's and stays as is.
 */

'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const launchURLFile =
  process.env.CLUTCH_LAUNCH_URL_FILE ||
  path.join(process.env.CLUTCH_HOME || path.join(process.env.HOME || '', '.clutch'), 'web-launch-url');

fs.mkdirSync(path.dirname(launchURLFile), { recursive: true });

const [, , cmd, ...args] = process.argv;
if (!cmd) {
  process.stderr.write('capture-launch-url: missing dsh command (usage: capture-launch-url.cjs <cmd> [args...])\n');
  process.exit(2);
}

const child = spawn(cmd, args, { stdio: ['inherit', 'pipe', 'inherit'] });

let buf = '';
const urlRe = /^dsh web: (https?:\/\/\S+)/m;

child.stdout.on('data', (chunk) => {
  process.stdout.write(chunk); // pass-through to pm2 logs
  buf += chunk.toString();
  let m;
  while ((m = urlRe.exec(buf)) !== null) {
    const url = m[1];
    try {
      // The URL carries a launch token, so keep it owner-only.
      fs.writeFileSync(launchURLFile, url + '\n', { mode: 0o600 });
      fs.chmodSync(launchURLFile, 0o600);
      process.stderr.write(`capture-launch-url: wrote ${url} to ${launchURLFile}\n`);
    } catch (err) {
      process.stderr.write(`capture-launch-url: failed to write ${launchURLFile}: ${err.message || err}\n`);
    }
    buf = buf.slice(m.index + m[0].length);
  }
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    if (!child.killed) child.kill(sig);
  });
}

child.on('exit', (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code || 0);
});
