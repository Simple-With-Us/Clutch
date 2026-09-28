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

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Harness", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Harness", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Harness", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu - Required for standard macOS keyboard shortcuts: Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z in WebKit
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
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
        /* Completely suppress any upstream brand elements, marks, names, or SVGs */
        [data-slot*="brand"],
        [data-slot*="brand"] *,
        [class*="brandMark"],
        [class*="brandMark"] *,
        [class*="brandName"],
        [class*="brandName"] *,
        [class*="_brandIdentity"] > span,
        [class*="_brandIdentity"] > div:not([data-harness-brand]),
        button[class*="brand"] svg:not([data-harness-brand] svg),
        button[class*="_brand"] svg:not([data-harness-brand] svg) {
          display: none !important;
        }
        /* Strip the empty-state hero whale (HeroFish) */
        [class*="_fishHitbox"], [class*="_fish"], [class*="fishHitbox"], [class*="fish"] {
          display: none !important;
        }
        /* Tighten the sidebar top-left header */
        [class*="_logoRow"] {
          height: 48px !important;
          margin-bottom: 2px !important;
          padding: 4px 8px 4px 4px !important;
          box-sizing: border-box !important;
          display: flex !important;
          align-items: center !important;
          overflow: visible !important;
        }
        [class*="_collapsed"] [class*="_logoRow"] {
          height: 40px !important;
          margin-bottom: 6px !important;
        }
        [class*="_brand"] {
          height: auto !important;
          overflow: visible !important;
          display: inline-flex !important;
        }
        [class*="_brandIdentity"] {
          height: auto !important;
          overflow: visible !important;
          display: inline-flex !important;
          flex-direction: column !important;
          align-items: flex-start !important;
          justify-content: center !important;
          gap: 2px !important;
        }
        /* Ensure our H monogram brand SVG and container are always visible */
        [data-harness-brand] {
          display: inline-flex !important;
        }
        [data-harness-brand] svg {
          display: block !important;
        }
        [data-harness-rail-brand] {
          display: flex !important;
          align-items: center !important;
          justify-content: center !important;
        }
        [data-harness-rail-brand] svg {
          display: block !important;
        }
        /* Strip extra margins from newSession button to eliminate any top gap */
        [class*="_newSession"] {
          margin-top: 0 !important;
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
        let deepSeekMark = harnessAssetDataURL("harness-icon-dsh-whale-1024.png", mime: "image/png")
        let deepSeekMark = harnessAssetDataURL("harness-icon-dsh-whale-1024.png", mime: "image/png")

        let brandAndPickerScript = """
        (function () {
          const text = (s) => (s || '').toString();

          // Update the brand header to the H monogram with just HARNESS under that.
          // In wide mode: injects H monogram + HARNESS into _brandIdentity.
          // In rail (collapsed) mode: injects H monogram into _railMark.
          // Eliminates any blank void in top left.
          const updateBrandHeader = () => {
            const brandIdentity = document.querySelector('[class*="brandIdentity"]');
            if (brandIdentity) {
              brandIdentity.querySelectorAll('[data-harness-mm], [data-harness-ds], [data-harness-h]').forEach((n) => n.remove());
              Array.from(brandIdentity.children).forEach((child) => {
                if (child.dataset.harnessBrand !== '1') {
                  child.style.setProperty('display', 'none', 'important');
                }
              });
              brandIdentity.querySelectorAll('svg').forEach((s) => {
                if (!s.closest('[data-harness-brand="1"]')) {
                  s.style.setProperty('display', 'none', 'important');
                }
              });
              if (!brandIdentity.querySelector('[data-harness-brand="1"]')) {
                const hBrand = document.createElement('div');
                hBrand.dataset.harnessBrand = '1';
                hBrand.style.cssText = 'display:inline-flex;flex-direction:column;align-items:flex-start;justify-content:center;gap:2px;line-height:1;user-select:none;cursor:pointer;padding:1px 0;';
                hBrand.innerHTML = `
                  <svg width="22" height="18" viewBox="0 0 484 440" fill="currentColor" style="display:block;">
                    <path d="M0 0h112v172h260V0h112v440H372V268H112v172H0z"/>
                  </svg>
                  <span style="font-size:9.5px;font-weight:700;letter-spacing:0.12em;line-height:1;color:inherit;opacity:0.85;">HARNESS</span>
                `;
                brandIdentity.appendChild(hBrand);
              }
            }

            const railMark = document.querySelector('[class*="railMark"]');
            if (railMark) {
              Array.from(railMark.children).forEach((child) => {
                if (child.dataset.harnessRailBrand !== '1') {
                  child.style.setProperty('display', 'none', 'important');
                }
              });
              railMark.querySelectorAll('svg').forEach((s) => {
                if (!s.closest('[data-harness-rail-brand="1"]')) {
                  s.style.setProperty('display', 'none', 'important');
                }
              });
              if (!railMark.querySelector('[data-harness-rail-brand="1"]')) {
                const railH = document.createElement('span');
                railH.dataset.harnessRailBrand = '1';
                railH.style.cssText = 'display:inline-flex;align-items:center;justify-content:center;line-height:1;';
                railH.innerHTML = `
                  <svg width="18" height="15" viewBox="0 0 484 440" fill="currentColor" style="display:block;">
                    <path d="M0 0h112v172h260V0h112v440H372V268H112v172H0z"/>
                  </svg>
                `;
                railMark.appendChild(railH);
              }
            }
          };

          // Model-picker provider group: the upstream heading is the raw
          // provider id from `listProviders()` display names, so MiniMax
          // renders as lowercase "minimax" with no logo at all.  Rewrite it to
          // brand case and put the MiniMax logo next to it, so choosing MiniMax
          // in the picker shows the MiniMax logo.
          const MINIMAX_MARK = \(cssSwiftLiteral(miniMaxMark));
          const DEEPSEEK_MARK = \(cssSwiftLiteral(deepSeekMark));
          const markPickerHeadings = () => {
            document.querySelectorAll('div, span, li, p').forEach((el) => {
              if (el.children.length > 0 && el.dataset.harnessMmPicker !== '1' && el.dataset.harnessDsPicker !== '1') return;
              const t = text(el.textContent || '').trim();
              if (!t) return;
              let isMM = t === 'minimax' || t === 'MiniMax' || t.startsWith('MiniMax-') || t.startsWith('MiniMax ');
              let isDS = t === 'deepseek' || t === 'DeepSeek' || t.startsWith('DeepSeek-') || t.startsWith('DeepSeek ');
              if (!isMM && !isDS) return;
              
              if (t === 'minimax') { el.textContent = 'MiniMax'; isMM = true; }
              if (t === 'deepseek') { el.textContent = 'DeepSeek'; isDS = true; }
              
              if (isMM && MINIMAX_MARK && el.dataset.harnessMmPicker !== '1') {
                el.dataset.harnessMmPicker = '1';
                const img = document.createElement('img');
                img.dataset.harnessMmPickerMark = '1';
                img.src = MINIMAX_MARK;
                img.alt = 'MiniMax';
                img.style.cssText = 'width:14px;height:14px;margin-right:6px;vertical-align:-2px;';
                el.insertBefore(img, el.firstChild);
              } else if (isDS && DEEPSEEK_MARK && el.dataset.harnessDsPicker !== '1') {
                el.dataset.harnessDsPicker = '1';
                const img = document.createElement('img');
                img.dataset.harnessDsPickerMark = '1';
                img.src = DEEPSEEK_MARK;
                img.alt = 'DeepSeek';
                img.style.cssText = 'width:14px;height:14px;margin-right:6px;vertical-align:-2px;';
                el.insertBefore(img, el.firstChild);
              }
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

          // Auto-bind workspace if the app is stuck on "Choose a workspace to start"
          // and allow clicking any workspace row to open a session in it.
          let lastAutoClick = { current: 0 };
          const ensureWorkspaceSelected = () => {
            const bodyText = document.body ? (document.body.innerText || '') : '';
            const isInert = bodyText.includes('Choose a workspace to start')
              || !!document.querySelector('[data-composer-placeholder*="workspace" i]')
              || !!document.querySelector('[data-phase="inert"]')
              || !!document.querySelector('[class*="cardWorkspaceTrigger"]')
              || !!document.querySelector('[aria-label*="Choose a workspace" i]');

            const now = Date.now();
            if (isInert && (now - lastAutoClick.current > 1000)) {
              const firstNewBtn = document.querySelector('button[aria-label*="New session in "]')
                || document.querySelector('button[aria-label*="session in" i]')
                || document.querySelector('button[aria-label*="新建会话"]');
              if (firstNewBtn) {
                lastAutoClick.current = now;
                firstNewBtn.click();
              }
            }

            // Top "New Session" button fallback if clicked in inert state
            const topNewBtn = document.querySelector('button[class*="_newSession"]');
            if (topNewBtn && topNewBtn.dataset.harnessBound !== '1') {
              topNewBtn.dataset.harnessBound = '1';
              topNewBtn.addEventListener('click', () => {
                setTimeout(() => {
                  const checkInert = (document.body ? document.body.innerText : '').includes('Choose a workspace to start')
                    || !!document.querySelector('[data-phase="inert"]')
                    || !!document.querySelector('[class*="cardWorkspaceTrigger"]');
                  if (checkInert) {
                    const firstBtn = document.querySelector('button[aria-label*="New session in "]')
                      || document.querySelector('button[aria-label*="session in" i]');
                    if (firstBtn) firstBtn.click();
                  }
                }, 50);
              });
            }

            // Clicking any workspace row opens a session in it
            document.querySelectorAll('[role="treeitem"][class*="projectRow"]').forEach((row) => {
              if (row.dataset.harnessRowBound === '1') return;
              row.dataset.harnessRowBound = '1';
              row.addEventListener('click', (e) => {
                if (e.target && e.target.closest('button[aria-label*="Workspace actions for"]')) return;
                const newBtn = row.querySelector('button[aria-label*="New session in "]')
                  || row.querySelector('button[aria-label*="session in" i]')
                  || row.querySelector('button[aria-label*="新建会话"]');
                if (newBtn) {
                  e.stopPropagation();
                  newBtn.click();
                }
              });
            });
          };

          updateBrandHeader();
          markPickerHeadings();
          markPickerModelRows();
          fixEffortOption();
          ensureWorkspaceSelected();

          // Ensure standard keyboard shortcuts are permitted on webview inputs
          window.addEventListener('keydown', (e) => {
            if ((e.metaKey || e.ctrlKey) && !e.altKey) {
              const k = (e.key || "").toLowerCase();
              if ("cvxaz".indexOf(k) !== -1) {
                e.stopPropagation();
              }
            }
          }, true);

          const mo = new MutationObserver(() => {
            updateBrandHeader();
            markPickerHeadings();
            markPickerModelRows();
            fixEffortOption();
            ensureWorkspaceSelected();
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
