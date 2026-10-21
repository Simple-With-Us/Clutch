import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * Mac-runner visual capture for the model picker and reasoning-effort UI
 * (owner request 2026-10-20: run Playwright for Clutch on a GitHub Mac
 * runner and save the screenshots).
 *
 * Runs only through `playwright.mac.config.ts` (see
 * `.github/workflows/e2e-mac-visual.yml`); PR CI keeps using the Linux
 * `chromium` project in `playwright.config.ts`, so these baselines land as
 * `*-chromium-darwin.png` and never collide with CI's Linux baselines.
 *
 * The picker is the upstream dsh model-selection plugin: trigger
 * `button[aria-label="Select model, current …"]`, menu `role=menu` labelled
 * "Model and reasoning effort", with "Model …" and "Effort …" pane openers.
 * The picker only mounts once a workspace is selected, so the test opens
 * the runner's home directory through the "Select Workspace Directory"
 * dialog first.  The model catalog is server-driven: when a fresh
 * credential-free engine home does not offer MiniMax-M3.1-Flash, the test
 * still captures the models pane as evidence instead of failing.
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
  await dismissIfPresent(page.getByRole("button", { name: "Continue", exact: true }));
  await dismissIfPresent(page.getByRole("button", { name: "Configure later", exact: true }));
  await expect(page.getByText("Into the Unknown")).toBeVisible();
}

async function openWorkspace(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Choose workspace" }).first().click();
  const dialog = page.getByRole("dialog", { name: "Select Workspace Directory" });
  await expect(dialog).toBeVisible();
  await dialog.getByRole("button", { name: "Open" }).click();
}

test.describe("Clutch web model picker (Mac capture)", () => {
  test.setTimeout(120_000);

  test("model picker, effort pane, and MiniMax-M3.1-Flash when offered", async ({ page }) => {
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await dismissOnboarding(page);
    await openWorkspace(page);

    const trigger = page.getByRole("button", { name: /Select model/ }).first();
    await expect(trigger).toBeVisible({ timeout: 30_000 });
    // Composer strip with the default model and effort in the trigger.
    await expect(trigger).toHaveScreenshot("model-trigger-default.png", {
      animations: "disabled",
      maxDiffPixelRatio: 0.01,
      timeout: 20_000,
    });

    await trigger.click();
    const menu = page.getByRole("menu", { name: "Model and reasoning effort" });
    await expect(menu).toBeVisible();

    // Models pane: every model the server catalog offers this engine home.
    await menu.getByRole("menuitem", { name: /^Model / }).click();
    await expect(page.getByRole("menuitemradio").first()).toBeVisible();
    await expect(page).toHaveScreenshot("model-picker-models-pane.png", {
      animations: "disabled",
      maxDiffPixelRatio: 0.02,
      timeout: 20_000,
    });

    const minimax = page.getByRole("menuitemradio", { name: /MiniMax[- ]M3\.1-Flash/ });
    const offered = (await minimax.count()) > 0;
    test.info().annotations.push({
      type: "minimax-m31-flash-offered",
      description: String(offered),
    });

    if (offered) {
      await minimax.first().click();
      await expect(trigger).toContainText(/MiniMax[- ]M3\.1-Flash/);
      await expect(trigger).toHaveScreenshot("model-trigger-minimax.png", {
        animations: "disabled",
        maxDiffPixelRatio: 0.01,
        timeout: 20_000,
      });
      await trigger.click();
      await expect(menu).toBeVisible();
    }

    // Effort pane: reasoning-effort choices for the active model.
    await menu.getByRole("menuitem", { name: /^Effort / }).click();
    await expect(page.getByRole("menuitemradio").first()).toBeVisible();
    await expect(page).toHaveScreenshot(offered ? "effort-pane-minimax.png" : "effort-pane-default.png", {
      animations: "disabled",
      maxDiffPixelRatio: 0.02,
      timeout: 20_000,
    });
  });
});
