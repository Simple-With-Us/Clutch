import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * Visual regression checks for the Harness web UI (the upstream dsh web
 * app served through `bash scripts/harness.sh web`).
 *
 * The `chromium` project runs with the `storageState` minted by
 * `e2e/auth.setup.ts`, so every page here loads authenticated.  Server
 * state is isolated to `e2e/.dsh-home`, so the app starts from a clean
 * slate on CI: empty session list, default settings.
 *
 * A fresh `DSH_HOME` shows two first-run modals (the internal-testing
 * notice and the API-key prompt).  Both are dismissed before asserting;
 * the guards make the tests idempotent against a warm `DSH_HOME` on
 * local re-runs.  Selectors are role-based — the app's CSS class names
 * are hashed and must not be used.
 *
 * Flaky regions (timestamps, availability dots, provider status) are
 * masked rather than asserted.  If a screen cannot be made
 * deterministic, the test is skipped instead of shipped flaky.
 */

async function dismissIfPresent(button: Locator, timeoutMs = 10_000): Promise<void> {
  const visible = await button
    .waitFor({ state: "visible", timeout: timeoutMs })
    .then(
      () => true,
      () => false,
    );
  if (visible) await button.click();
}

async function dismissOnboarding(page: Page): Promise<void> {
  // `exact` matters: the API-key prompt has a disabled "Save and
  // continue" button that a loose "Continue" match would hit instead
  // of the notice's own Continue button.
  await dismissIfPresent(page.getByRole("button", { name: "Continue", exact: true }));
  await dismissIfPresent(page.getByRole("button", { name: "Configure later", exact: true }));
  await expect(page.getByText("Into the Unknown")).toBeVisible();
}

test.describe("Harness web UI", () => {
  // Cold boots (server start + browser launch on a busy CI runner) can
  // exceed the 30s default; the assertions below still fail fast on
  // real regressions.
  test.setTimeout(90_000);

  test("home renders the session sidebar and workspace composer", async ({ page }) => {
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await dismissOnboarding(page);
    await expect(page).toHaveScreenshot("web-home.png", {
      animations: "disabled",
      maxDiffPixelRatio: 0.01,
      timeout: 20_000,
    });
  });

  test("settings panel renders the General tab", async ({ page }) => {
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await dismissOnboarding(page);
    await page.getByRole("button", { name: "Settings" }).click();
    await expect(page.getByText("Appearance")).toBeVisible();
    await expect(page).toHaveScreenshot("web-settings.png", {
      animations: "disabled",
      maxDiffPixelRatio: 0.01,
      timeout: 20_000,
    });
  });
});
