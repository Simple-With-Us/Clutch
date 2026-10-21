import { defineConfig, devices } from "@playwright/test";
import { join } from "node:path";
import base from "./playwright.config";

/**
 * Mac-runner Playwright variant (owner request 2026-10-20).
 *
 * Same server boot, auth setup, and browser pinning as
 * `playwright.config.ts`, but the visual project also runs
 * `e2e/mac-visual.spec.ts` and every screenshot baseline lands with the
 * `-chromium-darwin` platform suffix.  PR CI selects projects through
 * `playwright.config.ts` on ubuntu, so nothing here changes CI signals.
 */

const CONFIG_DIR = import.meta.dirname;
const AUTH_STATE = join(CONFIG_DIR, "e2e", ".auth-state.json");

export default defineConfig({
  ...base,
  projects: [
    { name: "setup", testMatch: /.*\.setup\.ts/ },
    {
      name: "chromium",
      testMatch: /(web-visual|mac-visual)\.spec\.ts/,
      dependencies: ["setup"],
      use: {
        ...devices["Desktop Chrome"],
        storageState: AUTH_STATE,
      },
    },
  ],
});
