import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

/** The macOS shell is a single Swift file compiled straight to a binary by
 *  `scripts/install-dock-app.sh`, so there is no XCTest target and nothing to
 *  import.  The house convention (see `harness-picker.test.ts`) is to read the
 *  Swift source and assert on it.  These tests pin the regression where
 *  re-activating the app re-navigated the WKWebView and threw away the open
 *  settings screen. */

const SWIFT = readFileSync(
  join(__dirname, "..", "src", "web", "dock-app", "HarnessWindow.swift"),
  "utf8",
);

function swiftBody(signature: string): string {
  const start = SWIFT.indexOf(signature);
  if (start === -1) throw new Error(`${signature} not found in HarnessWindow.swift`);
  let depth = 0;
  for (let i = SWIFT.indexOf("{", start); i < SWIFT.length; i++) {
    const ch = SWIFT[i];
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return SWIFT.slice(start, i + 1);
    }
  }
  throw new Error(`${signature}: unbalanced braces`);
}

describe("HarnessWindow foreground does not reload the page", () => {
  const showWindow = swiftBody("private func showWindow()");

  it("loads only when there is no live page to preserve", () => {
    // The regression: `loadHarness()` ran on every foreground switch, so the
    // dsh web UI lost its open panel, scroll position, and half-typed settings
    // form values.  A load is now strictly guarded so that an active page is never
    // re-navigated or pinged on foreground switches.
    expect(showWindow).toMatch(/guard !hasLoadedPage \|\| loadFailed else \{ return \}/);
  });

  it("pings asynchronously, and only for a missing or failed page", () => {
    // The liveness check must never block the main thread, but it must
    // not run for a healthy loaded page either (false-negative pings
    // restart healthy servers).  The strict guard comes first, the
    // awaited ping runs past it.
    const guardIndex = showWindow.indexOf("guard !hasLoadedPage || loadFailed else { return }");
    const pingIndex = showWindow.indexOf("await pingHarness()");
    expect(guardIndex).toBeGreaterThanOrEqual(0);
    expect(pingIndex).toBeGreaterThan(guardIndex);
    expect(showWindow).toMatch(/Task \{ \[weak self\] in/);
  });

  it("keeps the server liveness path off the main thread", () => {
    expect(swiftBody("private func pingHarness()")).toMatch(/async -> Bool/);
    expect(swiftBody("private func ensureServer()")).toMatch(/\(\) async/);
    // No blocking primitives anywhere in the shell.
    expect(SWIFT).not.toMatch(/DispatchSemaphore/);
    expect(SWIFT).not.toMatch(/Thread\.sleep/);
    expect(SWIFT).not.toMatch(/\.waitUntilExit\(\)/);
  });

  it("recovers gracefully from WebKit web process termination", () => {
    expect(SWIFT).toMatch(/func webViewWebContentProcessDidTerminate\(_ webView: WKWebView\)/);
  });

  it("still brings the window forward on every re-activation", () => {
    expect(showWindow).toMatch(/window\.makeKeyAndOrderFront\(nil\)/);
    expect(showWindow).toMatch(/NSApp\.activate\(ignoringOtherApps: true\)/);
  });

  it("reopen routes through the guarded path rather than loading directly", () => {
    const reopen = swiftBody("func applicationShouldHandleReopen");
    expect(reopen).toMatch(/showWindow\(\)/);
    // The unguarded `webView.load` must not appear in the reopen path itself.
    expect(reopen).not.toMatch(/loadHarness/);
  });

  it("tracks load state through the navigation delegate", () => {
    // Without a didFinish signal there is no way to tell "already showing the
    // harness" from "never navigated", and the guard would either never fire or
    // always fire.
    expect(SWIFT).toMatch(/func webView\(_ webView: WKWebView, didFinish navigation: WKNavigation!\)/);
    expect(SWIFT).toMatch(/func webView\(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error\)/);
    expect(SWIFT).toMatch(
      /func webView\(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error\)/,
    );
  });

  it("starts closed and clears the failure flag when a load is attempted", () => {
    // A fresh web view must reload on the first foreground; defaulting the
    // state to "loaded" would leave the user staring at a blank window.
    expect(SWIFT).toMatch(/private var hasLoadedPage = false/);
    expect(SWIFT).toMatch(/private var loadFailed = false/);
    expect(swiftBody("private func loadHarness()")).toMatch(/loadFailed = false/);
  });
});
