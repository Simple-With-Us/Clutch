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
        /* Hide the upstream whale SVG inside the brand block and rail */
        [class*="_brandMark"] svg, [class*="_railMark"] svg,
        [class*="_brand"] > svg {
          display: none !important;
        }
        /* Strip the empty-state hero whale (HeroFish) */
        [class*="_fishHitbox"], [class*="_fish"] {
          display: none !important;
        }
        /* Tighten the sidebar top-left header */
        [class*="_logoRow"] {
          height: 52px !important;
          margin-bottom: 4px !important;
          padding: 4px 8px 4px 4px !important;
          box-sizing: border-box !important;
          display: flex !important;
          align-items: center !important;
        }
        [class*="_brand"] {
          height: auto !important;
          overflow: visible !important;
        }
        [class*="_brandIdentity"] {
          height: auto !important;
          overflow: visible !important;
          display: inline-flex !important;
          flex-direction: column !important;
          align-items: flex-start !important;
          justify-content: center !important;
          gap: 0 !important;
        }
        /* Ensure our H monogram brand SVG and container are always visible */
        [data-harness-brand] {
          display: inline-flex !important;
        }
        [data-harness-brand] svg {
          display: block !important;
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

        // MiniMax provider mark, base64.  Used in the model-picker provider group
        // so choosing MiniMax shows the MiniMax logo next to the section heading.
        let miniMaxMark = harnessAssetDataURL("minimax-mark.svg", mime: "image/svg+xml")

        let brandAndPickerScript = """
        (function () {
          const text = (s) => (s || '').toString();

          // Find the brand container in the sidebar top-left.
          const findBrandEl = () => {
            return document.querySelector('[class*="_brandIdentity"]')
              || document.querySelector('button[class*="_brand"]')
              || document.querySelector('[class*="_brand"]')
              || document.querySelector('button[class*="brand"]');
          };

          // Update the top-left brand header to the H monogram with just HARNESS under that.
          // No MM or DS logos; eliminates blank space in top left.
          const updateBrandHeader = () => {
            const brandEl = findBrandEl();
            if (!brandEl) return;

            // Strip any legacy MM or DS marks
            brandEl.querySelectorAll('[data-harness-mm], [data-harness-ds], [data-harness-h]').forEach((n) => n.remove());

            if (!brandEl.querySelector('[data-harness-brand="1"]')) {
              Array.from(brandEl.children).forEach((child) => {
                if (!child.dataset.harnessBrand) {
                  child.style.display = 'none';
                }
              });
              const hBrand = document.createElement('div');
              hBrand.dataset.harnessBrand = '1';
              hBrand.style.cssText = 'display:inline-flex;flex-direction:column;align-items:flex-start;justify-content:center;gap:3px;line-height:1;user-select:none;cursor:pointer;padding:2px 0;';
              hBrand.innerHTML = `
                <svg width="22" height="18" viewBox="0 0 484 440" fill="currentColor" style="display:block;">
                  <path d="M0 0h112v172h260V0h112v440H372V268H112v172H0z"/>
                </svg>
                <span style="font-size:9.5px;font-weight:700;letter-spacing:0.12em;line-height:1;color:inherit;opacity:0.85;">HARNESS</span>
              `;
              brandEl.appendChild(hBrand);
            }
          };

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

          // Model rows: the bundle ships raw model ids with no cost or
          // capability signal.  Give each row its owner-facing label and, where
          // the choice has a price or availability consequence, a chip.
          //
          //   deepseek-flash  Multimodal  DeepSeek's Flash IS the
          //     image/video model; its image tokens bill at the same rate as
          //     text, so there is one row, not two.
          //   deepseek-v4-pro  DeepSeek V4.1 Pro (reasoning-capable)
          //   MiniMax-M3.1-Flash-Preview  Preview  Token Plan / MiniMax Code
          //     only, so it needs a Token Plan key to be callable.
          //   MiniMax-M2.7-highspeed  2x Cost  same 204,800 context as M2.7 at
          //     exactly twice M3's $0.30 / $1.20.
          const MODEL_ROWS = [
            {
              ids: ['deepseek-flash', 'deepseek-v4-flash', 'DeepSeek-V41-Flash', 'DeepSeek-V4.1-Flash', 'DeepSeek V4.1 Flash', 'DeepSeek V4 Flash'],
              label: 'DeepSeek-V4.1-Flash',
              badge: 'Multimodal',
              badgeTitle: 'Accepts image and video input at the same token rate as text — each image is capped at 1,024 tokens.',
            },
            {
              ids: ['deepseek-v4-pro', 'DeepSeek-V4-Pro', 'DeepSeek-V4.1-Pro', 'DeepSeek V4.1 Pro', 'DeepSeek V4 Pro'],
              label: 'DeepSeek-V4.1-Pro',
            },
            {
              ids: ['MiniMax-M3.1-Flash-Preview', 'MiniMax M3.1 Flash Preview'],
              label: 'MiniMax-M3.1-Flash-Preview',
              badge: 'Preview',
              badgeTitle: 'Frontier multimodal coding model with a 1M context window. MiniMax offers it through Token Plan and MiniMax Code, so it needs a Token Plan key.',
            },
            {
              ids: ['MiniMax-M3', 'MiniMax M3'],
              label: 'MiniMax-M3',
            },
            {
              ids: ['MiniMax-M2.7-highspeed', 'MiniMax M2.7 Highspeed', 'MiniMax M2.7 highspeed'],
              label: 'MiniMax-M2.7-highspeed',
              badge: '2x Cost',
              badgeTitle: 'Same 204,800 context as M2.7 at $0.60 / M input and $2.40 / M output — exactly twice MiniMax M3.',
            },
          ];

          // Disallow any legacy/extra DeepSeek models from appearing in the picker
          const DISALLOWED_MODELS = [
            'DeepSeek-V4-Flash',
            'DeepSeek-V4-Flash-Vision-Exp',
            'deepseek-v4-flash-vision-exp',
            'DeepSeek V4 Flash Vision Exp'
          ];
          const markPickerModelRows = () => {
            // Hide disallowed model buttons in picker
            document.querySelectorAll('button[role="menuitemradio"], button[class*="option"]').forEach((btn) => {
              const bText = text(btn.textContent || '').trim();
              if (DISALLOWED_MODELS.some((m) => bText === m || (bText.startsWith(m) && !bText.includes('4.1')))) {
                btn.style.display = 'none';
              }
            });

            // Decorate allowed model rows with labels and badges
            document.querySelectorAll('div, span, li, p, button, label').forEach((el) => {
              if (el.children.length > 0) return;
              const t = text(el.textContent || '').trim();
              if (!t) return;
              const row = MODEL_ROWS.find((candidate) => candidate.ids.includes(t));
              if (!row) return;
              if (t !== row.label) el.textContent = row.label;
              if (!row.badge) return;
              if (el.dataset.harnessModelRow === '1') return;
              el.dataset.harnessModelRow = '1';
              const chip = document.createElement('span');
              chip.dataset.harnessModelBadge = '1';
              chip.textContent = row.badge;
              chip.title = row.badgeTitle ?? row.badge;
              chip.setAttribute('role', 'img');
              chip.setAttribute('aria-label', row.badgeTitle ?? row.badge);
              chip.style.cssText = 'display:inline-block;margin-left:6px;padding:1px 6px;border-radius:999px;'
                + 'background:rgba(148,163,184,0.18);color:inherit;font-size:10px;'
                + 'line-height:16px;white-space:nowrap;vertical-align:1px;';
              el.appendChild(chip);
            });
          };

          // Enforce reasoning effort level only for models where it is applicable:
          // Applicable: DeepSeek-V4.1-Pro, MiniMax-M3.
          // Not applicable: DeepSeek-V4.1-Flash, MiniMax-M3.1-Flash-Preview, MiniMax-M2.7-highspeed.
          const fixEffortOption = () => {
            const triggerLabel = document.querySelector('[class*="triggerLabel"]');
            const activeModel = text(triggerLabel?.textContent || '').trim();
            const isReasoning = /(pro|reasoner)/i.test(activeModel) || activeModel === 'MiniMax-M3';

            const triggerEffort = document.querySelector('[class*="triggerEffort"]');
            if (triggerEffort) {
              triggerEffort.style.display = isReasoning ? '' : 'none';
            }

            document.querySelectorAll('button[role="menuitem"]').forEach((btn) => {
              const t = text(btn.textContent || '').trim().toLowerCase();
              if (t.startsWith('effort') || t.includes('reasoning')) {
                btn.style.display = isReasoning ? '' : 'none';
              }
            });
          };

          updateBrandHeader();
          markPickerHeadings();
          markPickerModelRows();
          fixEffortOption();

          const mo = new MutationObserver(() => {
            updateBrandHeader();
            markPickerHeadings();
            markPickerModelRows();
            fixEffortOption();
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
