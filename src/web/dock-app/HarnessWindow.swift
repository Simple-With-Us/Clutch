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

private func pingHarness() async -> Bool {
    guard let url = URL(string: harnessURLString) else { return false }
    // 8s: a 2s ping under CPU load false-negatives, then ensure-web.sh
    // pm2-restarts a healthy dsh-web and WebKit reports "Load failed".
    var req = URLRequest(url: url, timeoutInterval: 8)
    req.httpMethod = "GET"
    guard let (_, response) = try? await URLSession.shared.data(for: req),
          let http = response as? HTTPURLResponse else { return false }
    return (200..<500).contains(http.statusCode)
}

private func ensureServer() async {
    if await pingHarness() { return }
    let script = NSHomeDirectory() + "/apps/harness-runtime/scripts/ensure-web.sh"
    guard FileManager.default.isExecutableFile(atPath: script) else { return }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = [script]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    // Register the termination handler before launch so an early exit
    // cannot race past it, then await the exit instead of blocking on
    // the process; a failed launch resumes immediately.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        proc.terminationHandler = { _ in continuation.resume() }
        do {
            try proc.run()
        } catch {
            proc.terminationHandler = nil
            continuation.resume()
        }
    }
    for _ in 0..<20 {
        if await pingHarness() { return }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }
}

// MARK: - DeepSeek Model Discovery (Settings)

/// Lists the models the DeepSeek account can call, for the Settings > Models
/// panel.
///
/// The request has to happen here rather than in the page for two reasons.
/// The web view is served from `http://127.0.0.1:3080/`, and DeepSeek's API
/// sends no CORS headers for a browser origin, so a page-issued `fetch` is
/// refused.  More importantly the credential lives in the dsh credential
/// plane and must never be handed to page JavaScript.
///
/// The reply carries model ids only.  The key is read from
/// `~/.dsh/.credentials.yaml` under `refs:`, is never logged, and never
/// appears in an error string handed back to the page.
enum DeepSeekModels {
    static let modelsURL = "https://api.deepseek.com/models"
    static let credentialRef = "DEEPSEEK_API_KEY"
    /// Mirrors `DEEPSEEK_MODELS_MAX_BYTES` in `src/dsh/deepseek-models.ts`.
    static let maxBytes = 2 * 1024 * 1024

    /// Read one ref out of `~/.dsh/.credentials.yaml`.
    ///
    /// The store is a two-level map (`refs:` then the ref name), so a scoped
    /// scan is honest and avoids pulling in a YAML parser for one scalar.
    /// Quoted and unquoted scalars are both accepted; anything unrecognised
    /// yields `nil` rather than a guess.
    static func credential(home: String = NSHomeDirectory()) -> String? {
        let path = (home as NSString).appendingPathComponent(".dsh/.credentials.yaml")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var inRefs = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // A non-indented key ends the `refs:` block.
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inRefs = trimmed == "refs:"
                continue
            }
            guard inRefs else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard name == credentialRef else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// One listing, as `{ "ok": true, "models": ["id", ...] }` or
    /// `{ "ok": false, "message": "..." }`.  Only ids cross the bridge.
    ///
    /// Async end to end: the first version waited on a semaphore for up
    /// to 12 seconds, and its only caller is the script-message handler,
    /// which runs on the main thread.
    static func listing(home: String = NSHomeDirectory()) async -> [String: Any] {
        guard let key = credential(home: home) else {
            return ["ok": false, "message": "No \(credentialRef) in the dsh credential store."]
        }
        guard let url = URL(string: modelsURL) else {
            return ["ok": false, "message": "Bad model-list URL."]
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let status: Int
        do {
            let (replyData, response) = try await URLSession.shared.data(for: request)
            data = replyData
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return ["ok": false, "message": "Could not reach DeepSeek."]
        }
        if status == 401 || status == 403 {
            return ["ok": false, "message": "DeepSeek rejected the API key (\(status))."]
        }
        guard status == 200, !data.isEmpty else {
            return ["ok": false, "message": "DeepSeek answered \(status)."]
        }
        if data.count > maxBytes {
            return ["ok": false, "message": "The model list is larger than expected."]
        }
        guard
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = body["data"] as? [[String: Any]]
        else {
            return ["ok": false, "message": "DeepSeek did not answer with a model list."]
        }

        var ids: [String] = []
        var seen = Set<String>()
        for entry in entries {
            guard let id = entry["id"] as? String else { continue }
            let trimmed = id.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || seen.contains(trimmed) { continue }
            seen.insert(trimmed)
            ids.append(trimmed)
        }
        return ["ok": true, "models": ids]
    }
}

/// Bridges the injected Settings script to `DeepSeekModels`.  Kept separate
/// from the app delegate so the script message has one narrow job and the
/// AppDelegate stays about windows.
final class DeepSeekModelsMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "harnessDeepSeekModels"

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let webView = message.webView else { return }
        // listing() awaits the network instead of blocking on a
        // semaphore; run it off the main thread this handler is called
        // on, and reply when the listing is ready.
        Task {
            let reply = await DeepSeekModels.listing()
            let json = (try? JSONSerialization.data(withJSONObject: reply))
                .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false,"message":"bridge failure"}"#
            let script = "window.__harnessDeepSeekModelsResolve && window.__harnessDeepSeekModelsResolve(\(json));"
            DispatchQueue.main.async { webView.evaluateJavaScript(script, completionHandler: nil) }
        }
    }
}

// MARK: - Mac In-App Updater (Seamless & TestFlight Aware)

final class HarnessAppUpdater: NSObject {
    static let shared = HarnessAppUpdater()

    private let repoOwner = "jaywedgeworth22"
    private let repoName = "Harness"
    private(set) var latestVersionFound: String?
    private(set) var isChecking: Bool = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
    }

    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2"
    }

    var isTestFlightOrAppStore: Bool {
        if let receipt = Bundle.main.appStoreReceiptURL,
           FileManager.default.fileExists(atPath: receipt.path) {
            return receipt.lastPathComponent == "sandboxReceipt" || receipt.path.contains("masreceipt")
        }
        return false
    }

    func checkInBackground(updateMenuItem: NSMenuItem? = nil) {
        guard !isChecking && !isTestFlightOrAppStore else { return }
        isChecking = true

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            isChecking = false
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Harness-Mac-Updater/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { return }
            defer { self.isChecking = false }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return
            }

            let remoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            DispatchQueue.main.async {
                if self.isVersion(remoteVersion, newerThan: self.currentVersion) {
                    self.latestVersionFound = remoteVersion
                    updateMenuItem?.title = "Check for Updates... (v\(remoteVersion) Available)"
                }
            }
        }.resume()
    }

    func promptUserForUpdateCheck(window: NSWindow?) {
        if isTestFlightOrAppStore {
            let alert = NSAlert()
            alert.messageText = "Managed by TestFlight"
            alert.informativeText = "Harness is distributed via TestFlight / App Store.  Updates are installed automatically by macOS TestFlight in the background."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Harness-Mac-Updater/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tagName = json["tag_name"] as? String {
                    let remoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                    let htmlURL = json["html_url"] as? String ?? "https://github.com/\(self.repoOwner)/\(self.repoName)/releases"

                    if self.isVersion(remoteVersion, newerThan: self.currentVersion) {
                        self.latestVersionFound = remoteVersion
                        let updateAlert = NSAlert()
                        updateAlert.messageText = "Update Available"
                        updateAlert.informativeText = "Harness \(remoteVersion) is now available (you have \(self.currentVersion)).  Would you like to install it now?"
                        updateAlert.alertStyle = .informational
                        updateAlert.addButton(withTitle: "Update & Relaunch")
                        updateAlert.addButton(withTitle: "View Release Notes")
                        updateAlert.addButton(withTitle: "Later")

                        let response = updateAlert.runModal()
                        if response == .alertFirstButtonReturn {
                            self.performLocalUpdateAndRelaunch()
                        } else if response == .alertSecondButtonReturn {
                            if let targetURL = URL(string: htmlURL) {
                                NSWorkspace.shared.open(targetURL)
                            }
                        }
                    } else {
                        let upToDateAlert = NSAlert()
                        upToDateAlert.messageText = "You're Up to Date!"
                        upToDateAlert.informativeText = "Harness \(self.currentVersion) (build \(self.currentBuild)) is currently the newest version available."
                        upToDateAlert.alertStyle = .informational
                        upToDateAlert.addButton(withTitle: "OK")
                        upToDateAlert.runModal()
                    }
                } else {
                    self.checkLocalRepoUpdate(window: window)
                }
            }
        }.resume()
    }

    private func checkLocalRepoUpdate(window: NSWindow?) {
        let home = NSHomeDirectory()
        let scriptCandidates = [
            "\(home)/apps/harness-runtime/scripts/update-mac-app.sh",
            "\(home)/Code/Harness/scripts/update-mac-app.sh"
        ]
        if scriptCandidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let alert = NSAlert()
            alert.messageText = "Harness Local Update"
            alert.informativeText = "Harness is installed from local runtime.  Run update script to pull latest commits and recompile?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Update & Relaunch")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                performLocalUpdateAndRelaunch()
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "You're Up to Date"
            alert.informativeText = "Harness \(currentVersion) is running normally."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func performLocalUpdateAndRelaunch() {
        let home = NSHomeDirectory()
        let scriptCandidates = [
            "\(home)/apps/harness-runtime/scripts/update-mac-app.sh",
            "\(home)/Code/Harness/scripts/update-mac-app.sh"
        ]
        guard let script = scriptCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            let alert = NSAlert()
            alert.messageText = "Update Script Not Found"
            alert.informativeText = "Could not locate update-mac-app.sh in harness-runtime or Code/Harness."
            alert.alertStyle = .critical
            alert.runModal()
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script]
        try? proc.run()
        NSApplication.shared.terminate(nil)
    }

    private func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(parts1.count, parts2.count) {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var updateMenuItem: NSMenuItem?
    /// Retained for the life of the app: `WKUserContentController` keeps a
    /// script message handler alive, but holding it here makes the lifetime
    /// explicit rather than incidental.
    var deepSeekModelsHandler: DeepSeekModelsMessageHandler?

    @objc func checkForUpdates(_ sender: Any?) {
        HarnessAppUpdater.shared.promptUserForUpdateCheck(window: window)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Harness", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updateItem = appMenu.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "u")
        updateItem.target = self
        self.updateMenuItem = updateItem
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
        // Non-intrusive background update check after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            HarnessAppUpdater.shared.checkInBackground(updateMenuItem: self?.updateMenuItem)
        }
        // Ensure the server without freezing launch: the ping, the
        // ensure-web wait, and the retry loop are all awaited.  If the
        // first page load raced a server (re)start and failed, reload
        // once the server answers.
        Task { [weak self] in
            await ensureServer()
            await MainActor.run {
                guard let self, self.loadFailed else { return }
                self.loadHarness()
            }
        }
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
        // Settings > Models asks the shell — not the page — for the live
        // DeepSeek model list, because the API sends no CORS headers for a
        // browser origin and the credential must stay out of page JavaScript.
        let modelsHandler = DeepSeekModelsMessageHandler()
        deepSeekModelsHandler = modelsHandler
        userContent.add(modelsHandler, name: DeepSeekModelsMessageHandler.name)
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
        // DeepSeek provider mark, base64.  Same role as miniMaxMark for the
        // DeepSeek provider group heading in the model picker.
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
              if (el.children.length > 0) return;
              const t = text(el.textContent || '').trim();
              // Exact provider names only.  Model rows ('MiniMax-M3',
              // 'DeepSeek-V4.1-Flash', ...) are markPickerModelRows' job:
              // tagging one here would give it a child, and the badge pass
              // skips elements that already have children.
              const isMM = t === 'minimax' || t === 'MiniMax';
              const isDS = t === 'deepseek' || t === 'DeepSeek';
              if (!isMM && !isDS) return;
              if (t === 'minimax') el.textContent = 'MiniMax';
              if (t === 'deepseek') el.textContent = 'DeepSeek';
              if (isMM) {
                if (el.dataset.harnessMmPicker === '1' || !MINIMAX_MARK) return;
                el.dataset.harnessMmPicker = '1';
                const img = document.createElement('img');
                img.dataset.harnessMmPickerMark = '1';
                img.src = MINIMAX_MARK;
                img.alt = 'MiniMax';
                img.style.cssText = 'width:14px;height:14px;margin-right:6px;vertical-align:-2px;';
                el.insertBefore(img, el.firstChild);
              } else {
                if (el.dataset.harnessDsPicker === '1' || !DEEPSEEK_MARK) return;
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

          // Settings > Models: give the DeepSeek card a way to list what the
          // account can actually call.
          //
          // The upstream bundle already ships a "Fetch available models" button,
          // but it is rendered only for `llm-pi-ai` providers: the DeepSeek card
          // mounts `DeepSeekModelsEditor`, which is handed no fetch affordance,
          // and `dsh-llm-deepseek` registers no model discovery at all.  So the
          // affordance is added here.
          //
          // The request is made by the native shell, not the page: DeepSeek's API
          // sends no CORS headers for a browser origin, and the credential lives
          // in the dsh credential plane and must not reach page JavaScript.  The
          // bridge replies with model ids only.
          //
          // Deliberately read-only.  Persisting an adopted model means writing
          // `llm-deepseek.models` through the app's own settings writer, and
          // driving that from injected script is not something to ship unverified;
          // showing what the account can call is honest and immediately useful.
          const mountDeepSeekModelsButton = () => {
            const section = document.querySelector('section[aria-label="Models"], section[aria-label="模型"]');
            if (!section) return;
            if (section.querySelector('[data-harness-ds-models="1"]')) return;

            const button = document.createElement('button');
            button.type = 'button';
            button.dataset.harnessDsModels = '1';
            button.textContent = 'Fetch available models';
            button.style.cssText = 'margin-left:auto;padding:6px 12px;border-radius:6px;font-size:13px;'
              + 'line-height:18px;cursor:pointer;';

            const report = document.createElement('div');
            report.dataset.harnessDsModelsReport = '1';
            report.style.cssText = 'margin-top:8px;font-size:13px;line-height:20px;white-space:pre-wrap;';
            report.hidden = true;

            button.addEventListener('click', () => {
              button.disabled = true;
              const original = button.textContent;
              button.textContent = 'Asking DeepSeek…';
              report.hidden = true;

              window.__harnessDeepSeekModelsResolve = (payload) => {
                window.__harnessDeepSeekModelsResolve = undefined;
                button.disabled = false;
                button.textContent = original;
                const models = Array.isArray(payload.models) ? payload.models : [];
                if (payload.ok !== true) {
                  report.textContent = payload.message || 'DeepSeek did not answer.';
                  report.hidden = false;
                  return;
                }
                report.textContent = models.length === 0
                  ? 'DeepSeek listed no models.'
                  : models.join('\n');
                report.hidden = false;
              };

              try {
                window.webkit.messageHandlers.harnessDeepSeekModels.postMessage({});
              } catch (error) {
                window.__harnessDeepSeekModelsResolve
                  && window.__harnessDeepSeekModelsResolve({ ok: false, message: 'bridge unavailable' });
              }
            });

            const head = section.firstElementChild;
            if (head) head.appendChild(button);
            section.appendChild(report);
          };

          // Auto-bind workspace ONLY on cold initial launch if the landing screen is completely empty
          // with "Choose a workspace to start" and NO active messages or sessions exist.
          let didInitialAutoSelect = false;
          const ensureWorkspaceSelected = () => {
            if (didInitialAutoSelect) return;

            // Never auto-click if in Settings, or if chat messages/history exist
            if (location.hash.includes('settings') || !!document.querySelector('[class*="settings" i], [data-slot*="settings" i]')) return;
            if (document.querySelector('[class*="chatMessage"], [class*="messageRow"], [data-role="user"], [data-role="assistant"]')) {
              didInitialAutoSelect = true;
              return;
            }

            const bodyText = document.body ? (document.body.innerText || '') : '';
            if (bodyText.includes('Choose a workspace to start')) {
              const firstNewBtn = document.querySelector('button[aria-label*="New session in "]')
                || document.querySelector('button[aria-label*="session in" i]')
                || document.querySelector('button[aria-label*="新建会话"]');
              if (firstNewBtn) {
                didInitialAutoSelect = true;
                firstNewBtn.click();
              }
            }

            // Top "New Session" button fallback if clicked in inert state
            const topNewBtn = document.querySelector('button[class*="_newSession"]');
            if (topNewBtn && topNewBtn.dataset.harnessBound !== '1') {
              topNewBtn.dataset.harnessBound = '1';
              topNewBtn.addEventListener('click', () => {
                setTimeout(() => {
                  const checkInert = (document.body ? document.body.innerText : '').includes('Choose a workspace to start');
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
          mountDeepSeekModelsButton();

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
            mountDeepSeekModelsButton();
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

    func applicationDidBecomeActive(_ notification: Notification) {
        if let win = window, !win.isVisible {
            win.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: - Navigation state

    /// A page finished loading and is live in the web view.  Only a load that
    /// never reached `didFinish` leaves this false, which is what makes a
    /// foreground re-activation safe to answer with "do nothing".
    private var hasLoadedPage = false
    /// The last main-frame load failed, so the web view is showing a WebKit
    /// error page rather than the harness.  Re-activating should retry.
    private var loadFailed = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoadedPage = true
        loadFailed = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed = true
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hasLoadedPage = false
        loadFailed = true
        loadHarness()
    }

    /// Bring the window forward, reloading only when there is nothing live to
    /// preserve.
    ///
    /// If the web view has already successfully loaded and has not failed,
    /// a foreground switch must never ping the server or reload the page.
    /// Doing so causes beachballs, false-negative server restarts under CPU load,
    /// and destroys active sessions and open settings.
    private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard !hasLoadedPage || loadFailed else { return }

        // A missing or failed page can mean a down server: ping and
        // restart off the main thread, then reload once the server
        // state settles.  The window is already forward, so nothing
        // here may block the main thread.
        Task { [weak self] in
            let serverWasUp = await pingHarness()
            if !serverWasUp {
                await ensureServer()
            }
            await MainActor.run {
                guard let self else { return }
                if !self.hasLoadedPage || self.loadFailed || !serverWasUp {
                    self.loadHarness()
                }
            }
        }
    }

    private func loadHarness() {
        guard let url = URL(string: harnessURLString) else { return }
        loadFailed = false
        webView.load(URLRequest(url: url))
    }
}

private let heldDelegate = AppDelegate()

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = heldDelegate
app.run()
