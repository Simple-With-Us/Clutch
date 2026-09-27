import { defineConfig, devices } from "@playwright/test";
import { join } from "node:path";

/**
 * Playwright config for Harness web UI verification.
 *
 * The web UI itself is served by the upstream `@deepseek-ai/dsh` CLI
 * through `bash scripts/dsh.sh web` (the same entry the `npm run web`
 * launcher uses, minus the Tailscale Serve sidecar).  The server binds
 * `http://127.0.0.1:3080` by default and is auth-walled: `/` answers 401
 * until a signed browser cookie is minted from the per-process launch
 * URL the server prints on stdout (`dsh web: <url>`).  The `setup`
 * project visits that launch URL once (see `e2e/auth.setup.ts`) and
 * persists the cookie to `e2e/.auth-state.json` for the visual project.
 *
 * Server state (profiles, credentials) lives in an isolated
 * `e2e/.dsh-home` so runs never touch the operator's real `~/.dsh`.
 */

const CONFIG_DIR = import.meta.dirname;
const PORT = Number.parseInt(process.env.HARNESS_E2E_PORT ?? "3080", 10);
const BASE_URL = `http://127.0.0.1:${PORT}`;
const AUTH_STATE = join(CONFIG_DIR, "e2e", ".auth-state.json");
const DSH_HOME = join(CONFIG_DIR, "e2e", ".dsh-home");
const LAUNCH_URL_FILE = join(CONFIG_DIR, "e2e", ".launch-url.txt");

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: BASE_URL,
    trace: "on-first-retry",
    // The server binds loopback.  Some Chromium builds enforce Local
    // Network Access checks on programmatic navigations to private
    // addresses; these flags keep the loopback navigation working
    // everywhere without changing what the tests assert.
    // `channel: "chromium"` pins the full Chromium build (not the
    // headless shell) so local runs and CI render identically.
    launchOptions: {
      channel: "chromium",
      args: [
        "--no-sandbox",
        "--disable-features=LocalNetworkAccessChecks,PrivateNetworkAccessSendPreflights,PrivateNetworkAccessRespectPreflightResults",
      ],
    },
  },
  projects: [
    { name: "setup", testMatch: /.*\.setup\.ts/ },
    {
      name: "smoke",
      testMatch: /smoke\.spec\.ts/,
    },
    {
      name: "chromium",
      testMatch: /web-visual\.spec\.ts/,
      dependencies: ["setup"],
      use: {
        ...devices["Desktop Chrome"],
        storageState: AUTH_STATE,
      },
    },
  ],
  webServer: {
    // Always boot a private server for the run: reusing a foreign
    // process would leave `e2e/.launch-url.txt` pointing at a token the
    // reused server does not know, and the auth setup could never mint
    // its cookie.  The stale URL file is removed first so a previous
    // run's token can never be mistaken for this run's.
    command: `rm -f ${LAUNCH_URL_FILE} && node scripts/capture-launch-url.cjs bash scripts/dsh.sh web --no-open --host 127.0.0.1 --port ${PORT}`,
    url: BASE_URL,
    timeout: 180_000,
    reuseExistingServer: false,
    env: {
      DSH_HOME,
      DSH_LAUNCH_URL_FILE: LAUNCH_URL_FILE,
      HARNESS_RUNTIME_ROOT: CONFIG_DIR,
    },
  },
});
