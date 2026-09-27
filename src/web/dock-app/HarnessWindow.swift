import Cocoa
import WebKit

/// Tiny WKWebView shell so the Dock icon owns a real window.
/// Second Dock click focuses this window (GitHub.app pattern), instead of
/// spawning another Chrome --app instance.
///
/// URL resolution order:
///   1. `DSH_WEB_URL` env var — explicit override (also lets tests point at
///      a non-local server).
///   2. `~/.dsh/web-launch-url` — written by `scripts/capture-launch-url.cjs`
///      on every dsh-web start.  Contains the per-process `?token=...` URL
///      that mints the signed browser cookie.  Visiting it once mints the
///      cookie; subsequent `/` requests use the cookie, not the launch
///      token, so the cookie persists across dsh-web restarts (the signing
///      secret at `$DSH_HOME/credentials` is reused).
///   3. Bare `http://127.0.0.1:3080/` — last resort; gets 401 until the
///      user runs `bash ~/apps/harness-runtime/scripts/start-web.sh`
///      interactively (which prints the launch URL to stdout) and visits
///      it once in any browser.
private var harnessURLString: String {
    if let envURL = ProcessInfo.processInfo.environment["DSH_WEB_URL"],
       !envURL.isEmpty {
        return envURL
    }
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let launchURLPath = (home as NSString).appendingPathComponent(".dsh/web-launch-url")
    if let content = try? String(contentsOfFile: launchURLPath, encoding: .utf8) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return "http://127.0.0.1:3080/"
}

/// Escape a Swift string into a JavaScript-safe single-quoted string literal.
/// Used to embed the CSS payload inside a `<script>` bootstrap that WKWebView
/// will execute at document start; we want the raw CSS to land in a JS string
/// without `</script>`-style early termination or stray backtick issues.
private func cssSwiftLiteral(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "`", with: "\\`")
        .replacingOccurrences(of: "$", with: "\\$")
    return "`" + escaped + "`"
}

/// Resolve a bundled asset.  `install-dock-app.sh` copies assets into the live
/// runtime tree, so that is the primary location; `HARNESS_ASSETS_ROOT` lets a
/// dev/test run point at a checkout instead.
private func harnessAssetPath(_ name: String) -> String? {
    let fm = FileManager.default
    let home = NSHomeDirectory()
    var candidates: [String] = []
    if let root = ProcessInfo.processInfo.environment["HARNESS_ASSETS_ROOT"], !root.isEmpty {
        candidates.append("\(root)/\(name)")
    }
    candidates.append("\(home)/apps/harness-runtime/assets/\(name)")
    return candidates.first { fm.fileExists(atPath: $0) }
}

/// Base64 data URL for an asset.  The injected JS cannot fetch `file://`
/// subresources from the `http://127.0.0.1:3080/` page, so the bytes ride
/// along in the user script.
private func harnessAssetDataURL(_ name: String, mime: String) -> String {
    guard let path = harnessAssetPath(name),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "" }
    return "data:\(mime);base64," + data.base64EncodedString()
}

private func pingHarness() -> Bool {
    guard let url = URL(string: harnessURLString) else { return false }
    // 8s: a 2s ping under CPU load false-negatives, then ensure-web.sh
    // pm2-restarts a healthy dsh-web and WebKit reports "Load failed".
    var req = URLRequest(url: url, timeoutInterval: 8)
    req.httpMethod = "GET"
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        if let http = resp as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
            ok = true
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 8.5)
    return ok
}

private func ensureServer() {
    if pingHarness() { return }
    let script = NSHomeDirectory() + "/apps/harness-runtime/scripts/ensure-web.sh"
    guard FileManager.default.isExecutableFile(atPath: script) else { return }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = [script]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
    for _ in 0..<20 {
        if pingHarness() { return }
        Thread.sleep(forTimeInterval: 0.4)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureServer()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(1280, screen.width * 0.88)
        let height = min(860, screen.height * 0.88)
        let rect = NSRect(
            x: screen.midX - width / 2,
            y: screen.midY - height / 2,
            width: width,
            height: height
        )
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Harness"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("ComSimplewithusHarnessMacMain")
        window.tabbingMode = .disallowed

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let userContent = WKUserContentController()
        // Co-brand the top-left header that dsh-web renders inside the page
        // (separate from the macOS Dock app icon, which `install-dock-app.sh`
        // already swaps to the MMH master).  The upstream block from
        // @deepseek-ai/dsh-client-ui-dockkit is a whale SVG + the wordmark
        // "deepseek HARNESS".  The owner wants the HARNESS wordmark kept, the
        // upstream whale hidden, and the MM logo (the MMH master already
        // shipped via the icon-swap PR) + a small DS mark shown alongside.
        //
        // Two layers because the brand block mounts dynamically after
        // DOMContentLoaded: CSS hides class-tagged anchors/headers/SVGs on
        // first paint, then JS keeps the header in the desired shape as the
        // DOM mutates (also fixes the model-picker section heading "minimax"
        // -> "MiniMax" when the dropdown is opened).
        let css = """
        /* Hide the upstream whale SVG inside the brand block — keep the
           HARNESS wordmark visible.  The brand anchor itself is rebuilt by
           the JS below to add the MM logo and DS mark. */
        a[class*="brand"] svg, header [class*="brand"] svg,
        aside [class*="brand"] svg, nav [class*="brand"] svg,
        [class*="brand"] svg, [class*="logo"] svg {
          display: none !important;
        }
        /* Strip the empty-state hero whale (HeroFish in
           @deepseek-ai/dsh-client-ui-conversation/skeleton/EmptyHero).  The
           hero headline ("Into the Unknown" + preview badge) is kept; only
           the 34px SVG glyph and its hover-swim hitbox are removed. */
        [class*="_fishHitbox"], [class*="_fish"]:not([class*="brandMark"]):not([class*="railMark"]) {
          display: none !important;
        }
        /* Tighten the sidebar top-left header now that the upstream whale is
           gone: collapse the brandMark wrapper (its only content was the
           hidden SVG), collapse the brandIdentity gap (single remaining
           child), and zero out the DS chip's right margin so the [MM][DS]
           HARNESS row sits flush.  Class hashes (`hHd-Xa_*`,
           `pXSMma_*`) are CSS-module scoped; match by suffix so the rule
           survives an upstream re-hash. */
        [class*="_brandMark"] {
          display: none !important;
        }
        [class*="_brandIdentity"] {
          gap: 0 !important;
        }
        [data-harness-ds] {
          margin-right: 4px !important;
        }
        /* Make sure section headings in dropdowns use the brand case. */
        [class*="group-label"], [class*="vendor"], [class*="section-label"] {
          text-transform: capitalize;
        }
        """
        let cssBootstrap = """
        (function () {
          var s = document.createElement('style');
          s.textContent = \(cssSwiftLiteral(css));
          (document.head || document.documentElement).appendChild(s);
        })();
        """
        userContent.addUserScript(WKUserScript(source: cssBootstrap, injectionTime: WKUserScriptInjectionTime.atDocumentStart, forMainFrameOnly: true))

        // MiniMax provider mark, base64.  Deliberately NOT the Dock icon:
        // `assets/harness-icon-1024.png` is the neutral HARNESS mark, so the
        // app itself is not MiniMax-branded.  The MiniMax logo is used only
        // where MiniMax is actually named -- the sidebar co-brand chip the
        // owner asked for, and the model-picker provider group, so choosing
        // MiniMax in the picker shows the MiniMax logo.
        let miniMaxMark = harnessAssetDataURL("minimax-mark.svg", mime: "image/svg+xml")

        let brandAndPickerScript = """
        (function () {
          const text = (s) => (s || '').toString();

          // Find the top-left brand anchor.  dsh-web renders it as
          //   <a class="...brand..."> <svg/> deepseek HARNESS </a>
          // inside the sidebar header.
          const brandCandidates = Array.from(document.querySelectorAll(
            'a[class*="brand"], header [class*="brand"], aside [class*="brand"], nav [class*="brand"]'
          ));
          const brandEl = brandCandidates.find((el) => {
            const t = text(el.textContent || '').trim().toLowerCase();
            return t.includes('harness') || t.includes('deepseek');
          });

          if (brandEl) {
            // Drop the upstream "deepseek" prefix word so the brand reads
            // [MM logo] [DS] HARNESS, not "deepseek HARNESS".
            Array.from(brandEl.querySelectorAll('*')).forEach((el) => {
              const t = text(el.textContent || '').trim().toLowerCase();
              if (t === 'deepseek' && el.children.length === 0) {
                el.textContent = '';
              }
            });
            // Hide any inline SVG (whale) — already done by CSS, but belt-and-braces.
            brandEl.querySelectorAll('svg').forEach((svg) => { svg.style.display = 'none'; });

            // Add the DS chip if not already present.
            if (!brandEl.querySelector('[data-harness-ds]')) {
              const ds = document.createElement('span');
              ds.dataset.harnessDs = '1';
              ds.textContent = 'DS';
              ds.style.cssText = 'margin-right:6px;font-size:11px;opacity:0.55;letter-spacing:0.06em;';
              brandEl.insertBefore(ds, brandEl.firstChild);
            }
            // Add the MM logo if not already present.
            if (!brandEl.querySelector('[data-harness-mm]')) {
              const mm = document.createElement('img');
              mm.dataset.harnessMm = '1';
              mm.src = \(cssSwiftLiteral(miniMaxMark));
              mm.alt = 'MM';
              mm.style.cssText = 'width:22px;height:22px;margin-right:8px;border-radius:5px;vertical-align:middle;';
              brandEl.insertBefore(mm, brandEl.firstChild);
            }
          }

          // Model-picker provider group: the upstream heading is the raw
          // provider id from `listProviders()` display names, so MiniMax
          // renders as lowercase "minimax" with no logo at all.  Rewrite it to
          // brand case and put the MiniMax logo next to it, so choosing MiniMax
          // in the picker shows the MiniMax logo.
          const MINIMAX_MARK = \(cssSwiftLiteral(miniMaxMark));
          const markPickerHeadings = () => {
            document.querySelectorAll('div, span, li, p').forEach((el) => {
              if (el.children.length > 0) return;
              const t = text(el.textContent || '').trim();
              if (t !== 'minimax' && t !== 'MiniMax') return;
              if (t === 'minimax') el.textContent = 'MiniMax';
              // Idempotent: once the mark is in, `children.length > 0` above
              // short-circuits on later observer passes.  A re-render that
              // replaces this node yields a fresh childless element, so the
              // mark is re-applied.
              if (el.dataset.harnessMmPicker === '1' || !MINIMAX_MARK) return;
              el.dataset.harnessMmPicker = '1';
              const img = document.createElement('img');
              img.dataset.harnessMmPickerMark = '1';
              img.src = MINIMAX_MARK;
              img.alt = 'MiniMax';
              img.style.cssText = 'width:14px;height:14px;margin-right:6px;vertical-align:-2px;';
              el.insertBefore(img, el.firstChild);
            });
          };
          markPickerHeadings();
          const mo = new MutationObserver(() => {
            // Re-run the brand rewrite + picker heading/logo pass on every DOM
            // mutation.  Both layers are idempotent (data-harness-* checks).
            const el = brandCandidates.find((b) => true);
            if (el) {
              // Re-apply icon insertion in case dsh-web replaced the brand anchor.
              if (!el.querySelector('[data-harness-mm]')) {
                const mm = document.createElement('img');
                mm.dataset.harnessMm = '1';
                mm.src = \(cssSwiftLiteral(miniMaxMark));
                mm.alt = 'MM';
                mm.style.cssText = 'width:22px;height:22px;margin-right:8px;border-radius:5px;vertical-align:middle;';
                el.insertBefore(mm, el.firstChild);
              }
              if (!el.querySelector('[data-harness-ds]')) {
                const ds = document.createElement('span');
                ds.dataset.harnessDs = '1';
                ds.textContent = 'DS';
                ds.style.cssText = 'margin-right:6px;font-size:11px;opacity:0.55;letter-spacing:0.06em;';
                el.insertBefore(ds, el.firstChild);
              }
            }
            markPickerHeadings();
          });
          mo.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
        })();
        """
        userContent.addUserScript(WKUserScript(source: brandAndPickerScript, injectionTime: WKUserScriptInjectionTime.atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = userContent
        webView = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        window.contentView = webView
        loadHarness()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func showWindow() {
        if pingHarness() {
            loadHarness()
        } else {
            ensureServer()
            loadHarness()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadHarness() {
        guard let url = URL(string: harnessURLString) else { return }
        webView.load(URLRequest(url: url))
    }
}

private let heldDelegate = AppDelegate()

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = heldDelegate
app.run()
