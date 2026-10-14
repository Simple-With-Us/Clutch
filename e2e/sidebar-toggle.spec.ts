import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";

/**
 * The collapsed sidebar rail only reveals its expand icon on hover, so the
 * native apps inject a persistent expand button
 * (`[data-clutch-sidebar-toggle]`, script owned by
 * `ios/Mac/WebViewMac.swift`, mirrored in `ios/App/Views/ClutchWebView.swift`).
 * This spec runs that exact script against the real page and proves the
 * round trip: collapse → injected button appears → click → rail expands.
 *
 * The script source is extracted from the Swift file at test time, so the
 * test can never pass against a stale copy.  No CSS class names are
 * asserted (upstream hashes them); only the data attribute we own, plus
 * one DOM query to drive the upstream toggle itself.
 */

function sidebarToggleSource(): string {
  const swift = readFileSync(new URL("../ios/Mac/WebViewMac.swift", import.meta.url), "utf8");
  const match = /let sidebarToggle = """([\s\S]*?)"""/.exec(swift);
  if (!match?.[1]) throw new Error("sidebar toggle script missing from ios/Mac/WebViewMac.swift");
  return match[1];
}

async function dismissOnboarding(page: Page): Promise<void> {
  for (const name of ["Continue", "Configure later"] as const) {
    const button = page.getByRole("button", { name, exact: true });
    if (await button.waitFor({ state: "visible", timeout: 10_000 }).then(
      () => true,
      () => false,
    )) {
      await button.click();
    }
  }
  await expect(page.getByText("Into the Unknown")).toBeVisible();
}

test.describe("sidebar expand affordance", () => {
  test.setTimeout(90_000);

  test("collapsed rail gains a working expand button", async ({ page, context }) => {
    await context.addInitScript(sidebarToggleSource());
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await dismissOnboarding(page);

    const toggle = "button[class*='_toggle']";
    const injected = "[data-clutch-sidebar-toggle]";

    // No injected button while wide.
    await expect(page.locator(injected)).toHaveCount(0);

    // Collapse through the upstream toggle.
    await page.evaluate((sel) => {
      (document.querySelector(sel) as HTMLButtonElement | null)?.click();
    }, toggle);
    await expect(page.locator(injected)).toBeVisible();

    // The injected button expands through the upstream toggle.
    await page.locator(injected).click();
    await expect(page.locator(injected)).toHaveCount(0);
  });
});
