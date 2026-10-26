import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { TAILNET_STATUS_TIMEOUT_MS, readTailnetStatus } from "../src/web/tailnet-status.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

const fakeTailscale = (body: string): string => {
  const dir = mkdtempSync(join(tmpdir(), "fake-tailscale-"));
  const path = join(dir, "tailscale");
  writeFileSync(path, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return path;
};

describe("readTailnetStatus", () => {
  it("gives up on a CLI that never exits instead of holding startup", async () => {
    // A wedged tailscaled can leave `tailscale status` waiting forever, and
    // detection runs before the sidecar listens.
    const cli = fakeTailscale("exec sleep 30");
    const started = Date.now();
    await expect(readTailnetStatus(200, cli)).resolves.toBeNull();
    expect(Date.now() - started).toBeLessThan(5000);
  });

  it("bounds the read by default so a wedged tailscaled cannot hang startup", () => {
    expect(TAILNET_STATUS_TIMEOUT_MS).toBeGreaterThan(0);
    expect(TAILNET_STATUS_TIMEOUT_MS).toBeLessThanOrEqual(10_000);
  });

  it("treats a missing CLI as no tailnet", async () => {
    await expect(readTailnetStatus(5000, join(tmpdir(), "no-such-tailscale-cli"))).resolves.toBeNull();
  });

  it("parses the status JSON the CLI prints", async () => {
    const cli = fakeTailscale(`echo '{"Self":{"DNSName":"box.ts.net."}}'`);
    await expect(readTailnetStatus(5000, cli)).resolves.toEqual({ Self: { DNSName: "box.ts.net." } });
  });

  it("waits for the output stream to close, not just for the process to exit", async () => {
    // A background child keeps the pipe open after the shell itself is gone,
    // so a reader that settles on "exit" resolves before the output drained.
    const cli = fakeTailscale(`echo '{"Self":{"DNSName":"box.ts.net."}}'; (sleep 0.3) &`);
    const started = Date.now();
    await expect(readTailnetStatus(5000, cli)).resolves.toEqual({ Self: { DNSName: "box.ts.net." } });
    expect(Date.now() - started).toBeGreaterThanOrEqual(250);
  });
});

describe("web launcher tailnet wiring", () => {
  const ts = readFileSync(join(ROOT, "src", "web", "start-web.ts"), "utf8");

  // Regression: the launcher used to spawn `tailscale status` itself with no
  // timeout, so a wedged tailscaled kept the sidecar from ever listening.
  // It must go through the shared bounded reader instead.
  it("reads the tailnet host through the shared bounded reader", () => {
    expect(ts).not.toContain('spawn("tailscale"');
    expect(ts).toContain("readTailnetStatus(");
    expect(ts).toContain("readTailnetHost()");
  });

  it("still retries the tailnet read for a bounded window", () => {
    expect(ts).toContain("detectTailnetHost()");
    expect(ts).toMatch(/while|for \(;;\)/);
    expect(ts).toContain("CLUTCH_TAILNET_WAIT_SECONDS");
  });
});
