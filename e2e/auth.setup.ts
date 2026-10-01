import { test as setup, expect } from "@playwright/test";
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

/**
 * Mints the signed browser cookie for the Clutch web UI.
 *
 * `dsh web` prints a per-process launch URL (`dsh web: <url>?token=...`)
 * on stdout; `scripts/capture-launch-url.cjs` (run as the Playwright
 * webServer) tees it to `e2e/.launch-url.txt`.  Visiting that URL once
 * mints the signed cookie, so subsequent requests to `/` are
 * authenticated.  The cookie lands in `e2e/.auth-state.json`, which the
 * `chromium` project loads via `storageState`.
 */

const LAUNCH_URL_FILE = join(import.meta.dirname, ".launch-url.txt");
const AUTH_STATE = join(import.meta.dirname, ".auth-state.json");

async function readLaunchUrl(deadlineMs: number): Promise<string> {
  const deadline = Date.now() + deadlineMs;
  while (Date.now() < deadline) {
    try {
      const raw = readFileSync(LAUNCH_URL_FILE, "utf8").trim();
      if (/^https?:\/\/\S+$/.test(raw)) return raw;
    } catch {
      // File not written yet; the webServer may still be booting.
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  return "";
}

setup("authenticate via the dsh web launch token", async ({ page }) => {
  const launchUrl = await readLaunchUrl(90_000);
  expect(launchUrl, "expected the webServer to capture a dsh web launch URL").not.toBe("");

  mkdirSync(dirname(AUTH_STATE), { recursive: true });
  const response = await page.goto(launchUrl);
  expect(response?.ok(), "launch URL should mint the auth cookie").toBe(true);
  await page.context().storageState({ path: AUTH_STATE });
});
