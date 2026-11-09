#!/usr/bin/env node
/**
 * Wrap ios-ship-testflight.sh so Actions can gate post-sync recheck on a real upload.
 * Skipped ships (rate/same-HEAD gate) must not look like uploaded == true.
 */
import { spawn } from "node:child_process";
import fs from "node:fs";

const TAIL_MAX = 8 * 1024;

// ship-testflight.sh log() prefixes every upload/skip marker with "[ios-ship] ".
// Require that prefix immediately before each marker (substring match, not ^ line
// anchor) so unrelated tool output cannot set uploaded=true.
const fleetPrefix = String.raw`\[ios-ship\] `;
const uploadedRe = new RegExp(
  `${fleetPrefix}upload path succeeded via xcodebuild export \\(destination=upload\\)|` +
    `${fleetPrefix}build .+ submitted for |` +
    `${fleetPrefix}upload submitted; watch TestFlight processing`,
);
const skippedRe = new RegExp(
  `${fleetPrefix}ship-gate: exiting 0 before any version is resolved \\(nothing consumed\\)`,
);

const cmd = process.argv.slice(2);
if (cmd.length === 0) {
  console.error("usage: ios-observe-ship.mjs <command> [args...]");
  process.exit(2);
}

const outputs = process.env.GITHUB_OUTPUT?.trim();

/** @type {{ stdout: { sawUploaded: boolean; sawSkipped: boolean; carry: string }; stderr: { sawUploaded: boolean; sawSkipped: boolean; carry: string } }} */
const streamState = {
  stdout: { sawUploaded: false, sawSkipped: false, carry: "" },
  stderr: { sawUploaded: false, sawSkipped: false, carry: "" },
};

/**
 * @param {string} line
 * @param {{ sawUploaded: boolean; sawSkipped: boolean }} state
 */
function scanLine(line, state) {
  if (uploadedRe.test(line)) {
    state.sawUploaded = true;
  }
  if (skippedRe.test(line)) {
    state.sawSkipped = true;
  }
}

/**
 * @param {Buffer | string} chunk
 * @param {{ sawUploaded: boolean; sawSkipped: boolean; carry: string }} state
 * @param {NodeJS.WritableStream} sink
 */
function feedStream(chunk, state, sink) {
  sink.write(chunk);
  state.carry += chunk.toString();
  let nl = state.carry.indexOf("\n");
  while (nl !== -1) {
    const line = state.carry.slice(0, nl);
    state.carry = state.carry.slice(nl + 1);
    scanLine(line, state);
    nl = state.carry.indexOf("\n");
  }
  if (state.carry.length > TAIL_MAX) {
    state.carry = state.carry.slice(-TAIL_MAX);
  }
}

function flushStream(state) {
  if (state.carry.length > 0) {
    scanLine(state.carry, state);
    state.carry = "";
  }
}

function classifyOutcome(exitCode) {
  const sawUploaded = streamState.stdout.sawUploaded || streamState.stderr.sawUploaded;
  const sawSkipped = streamState.stdout.sawSkipped || streamState.stderr.sawSkipped;
  if (sawUploaded) {
    return { uploaded: "true", observed: "uploaded", exitCode };
  }
  if (sawSkipped) {
    return { uploaded: "false", observed: "skipped", exitCode };
  }
  if (exitCode === 0) {
    return { uploaded: "unknown", observed: "unknown_success", exitCode };
  }
  return { uploaded: "false", observed: "none", exitCode };
}

let settled = false;

/**
 * @param {{ uploaded: string; observed: string; exitCode: number }} outcome
 */
function settle(outcome) {
  if (settled) {
    return;
  }
  settled = true;
  if (outputs) {
    fs.appendFileSync(outputs, `uploaded=${outcome.uploaded}\n`);
    fs.appendFileSync(outputs, `ship_observed=${outcome.observed}\n`);
  }
  process.exit(outcome.exitCode);
}

const child = spawn(cmd[0], cmd.slice(1), {
  stdio: ["inherit", "pipe", "pipe"],
  shell: false,
});

child.stdout.on("data", (chunk) => {
  feedStream(chunk, streamState.stdout, process.stdout);
});
child.stderr.on("data", (chunk) => {
  feedStream(chunk, streamState.stderr, process.stderr);
});

child.on("error", (err) => {
  console.error(err);
  settle({ uploaded: "false", observed: "spawn_error", exitCode: 1 });
});

child.on("close", (code, signal) => {
  flushStream(streamState.stdout);
  flushStream(streamState.stderr);
  const exitCode = code ?? (signal ? 1 : 0);
  settle(classifyOutcome(exitCode));
});
