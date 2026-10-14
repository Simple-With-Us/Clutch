import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WebKit

/// macOS port of the iOS ClutchWebView (`Views/ClutchWebView.swift`, which is
/// excluded from the Mac target). Same public surface — `host` / `loadKey` /
/// `state` / `onAuthenticated` — so `RootView.ClutchScreen` stays shared.
/// UIKit pieces become AppKit ones: `NSViewRepresentable`, a native
/// `NSOpenPanel` for file inputs (no presenter lookup needed), `NSAlert` for
/// JavaScript dialogs, and `NSWorkspace` for external links.
/// `WebSurfaceState`, `OpenPanelSession`, the branding script, and the
/// `Bundle` helpers are duplicated here (marked below) so the iOS file —
/// and therefore the iOS build — stays byte-for-byte untouched.
struct ClutchWebView: NSViewRepresentable {
    let host: ClutchHost
    /// Changes whenever the page must be (re)loaded: new host, new pairing, or Reload.
    let loadKey: String
    @Binding var state: WebSurfaceState
    let onAuthenticated: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "ClutchMac/\(Bundle.main.shortVersion)"
        config.userContentController = Self.brandingController()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        context.coordinator.load(host: host, key: loadKey, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedKey != loadKey {
            context.coordinator.load(host: host, key: loadKey, in: webView)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: ClutchWebView
        var loadedKey: String?
        private var currentHost: ClutchHost?
        private let openPanel = OpenPanelSession()
        private weak var openPicker: NSOpenPanel?

        init(parent: ClutchWebView) {
            self.parent = parent
        }

        func load(host: ClutchHost, key: String, in webView: WKWebView) {
            loadedKey = key
            currentHost = host
            cancelOpenPanel()
            setState(.loading)
            var request = URLRequest(url: host.launchURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            webView.load(request)
        }

        private func setState(_ state: WebSurfaceState) {
            if parent.state != state {
                DispatchQueue.main.async { self.parent.state = state }
            }
        }

        // Keep navigation on the paired origin; send everything else to the browser.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url, let host = currentHost else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "about" || scheme == "blob" || scheme == "data" || host.isSameOrigin(url) {
                decisionHandler(.allow)
                return
            }
            if navigationAction.targetFrame?.isMainFrame == false {
                // Sub-frame content (embedded previews) stays inline.
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame,
               let http = navigationResponse.response as? HTTPURLResponse,
               let host = currentHost {
                if http.statusCode == 401 {
                    setState(.needsPairing)
                } else if (200..<300).contains(http.statusCode),
                          let url = http.url, host.isSameOrigin(url), url.path == "/" || url.path.isEmpty {
                    // The cookie now authenticates; the one-time token is spent.
                    let id = host.id
                    DispatchQueue.main.async { self.parent.onAuthenticated(id) }
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if parent.state == .loading { setState(.ready) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }

        private func handle(_ error: Error) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return } // frame load interrupted
            if parent.state == .needsPairing { return }
            setState(.failed(ns.localizedDescription))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            cancelOpenPanel()
            webView.reload()
        }

        // MARK: - File pickers
        //
        // clutch web asks for a workspace or an attachment through a file
        // input. On macOS the panel is native: sheet-attached when the web
        // view is in a window, app-modal otherwise.

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            cancelOpenPanel()
            let panel = NSOpenPanel()
            panel.canChooseFiles = !parameters.allowsDirectories
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canCreateDirectories = false
            panel.allowedContentTypes = OpenPanelSession.contentTypes(allowsDirectories: parameters.allowsDirectories)
            openPanel.begin { urls in completionHandler(urls) }
            openPicker = panel
            if let window = webView.window {
                panel.beginSheetModal(for: window) { [weak self] response in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.openPicker = nil
                        self.openPanel.finish(with: response == .OK ? panel.urls : nil)
                    }
                }
            } else {
                let response = panel.runModal()
                openPicker = nil
                openPanel.finish(with: response == .OK ? panel.urls : nil)
            }
        }

        /// Dismisses a panel that is still up and tells WebKit it was cancelled,
        /// so a reload underneath one cannot leave the request hanging forever.
        private func cancelOpenPanel() {
            if let panel = openPicker {
                if let sheetParent = panel.sheetParent {
                    sheetParent.endSheet(panel, returnCode: .cancel)
                } else {
                    panel.cancel(nil)
                }
            }
            openPicker = nil
            openPanel.finish(with: nil)
        }

        // target=_blank and window.open
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                if let host = currentHost, host.isSameOrigin(url) {
                    webView.load(navigationAction.request)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor () -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            present(alert, in: webView) { _ in completionHandler() }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            present(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn) }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor (String?) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = prompt
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            input.stringValue = defaultText ?? ""
            alert.accessoryView = input
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            present(alert, in: webView) { response in
                completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
            }
        }

        private func present(_ alert: NSAlert, in webView: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
            if let window = webView.window {
                alert.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
        }
    }

    // MARK: - Branding (copy of Views/ClutchWebView.swift)

    /// Hides the upstream brand mark and adds the Clutch "C" monogram,
    /// matching `src/web/dock-app/ClutchWindow.swift` on the Mac.
    static func brandingController() -> WKUserContentController {
        let controller = WKUserContentController()
        let css = """
        [data-slot*="brand"], [data-slot*="brand"] *, [class*="brandMark"], [class*="brandMark"] *,
        [class*="brandName"], [class*="brandName"] *, [class*="_brandIdentity"] > span,
        [class*="_brandIdentity"] > div:not([data-clutch-brand]),
        button[class*="brand"] svg:not([data-clutch-brand] svg),
        button[class*="_brand"] svg:not([data-clutch-brand] svg) {
          display: none !important;
        }
        [class*="_fishHitbox"], [class*="_fish"], [class*="fishHitbox"] {
          display: none !important;
        }
        [data-clutch-brand] { display: inline-flex !important; }
        [data-clutch-brand] svg { display: block !important; }
        """
        let cssBootstrap = """
        (function () {
          var s = document.createElement('style');
          s.textContent = `\(css)`;
          (document.head || document.documentElement).appendChild(s);
        })();
        """
        controller.addUserScript(WKUserScript(source: cssBootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let monogram = """
        (function () {
          const mark = () => {
            const identity = document.querySelector('[class*="brandIdentity"]');
            if (identity && !identity.querySelector('[data-clutch-brand="1"]')) {
              const h = document.createElement('div');
              h.dataset.clutchBrand = '1';
              h.style.cssText = 'display:inline-flex;flex-direction:column;align-items:flex-start;justify-content:center;gap:2px;line-height:1;user-select:none;padding:1px 0;';
              h.innerHTML = '<svg width="22" height="18" viewBox="0 0 484 440" fill="currentColor" style="display:block;"><path d="M436.5 78.6A220 220 0 1 0 436.5 361.4L350.7 289.4A108 108 0 1 1 350.7 150.6z"/></svg>'
                + '<span style="font-size:9.5px;font-weight:700;letter-spacing:0.12em;line-height:1;color:inherit;opacity:0.85;">CLUTCH</span>';
              identity.appendChild(h);
            }
          };
          mark();
          new MutationObserver(mark).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
        controller.addUserScript(WKUserScript(source: monogram, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return controller
    }
}

/// What the embedded clutch web page is doing.
/// Copy of `Views/ClutchWebView.swift` (excluded from this target).
public enum WebSurfaceState: Equatable {
    case loading
    case ready
    /// clutch web answered 401: no valid cookie and no valid launch token.
    case needsPairing
    case failed(String)
}

/// Keeps at most one WebKit open panel in flight.
/// Copy of `Views/ClutchWebView.swift` (excluded from this target).
@MainActor
final class OpenPanelSession {
    private var completion: (@MainActor ([URL]?) -> Void)?

    /// What the picker should offer. WebKit tells us only whether the input
    /// accepts directories, so a `webkitdirectory` request gets folders and
    /// everything else gets ordinary items.
    static func contentTypes(allowsDirectories: Bool) -> [UTType] {
        allowsDirectories ? [.folder] : [.item]
    }

    /// Records the completion for a new panel, cancelling any panel already open.
    func begin(_ completion: @escaping @MainActor ([URL]?) -> Void) {
        self.completion?(nil)
        self.completion = completion
    }

    /// Hands the result back to WebKit, at most once per request.
    func finish(with urls: [URL]?) {
        let handler = completion
        completion = nil
        handler?(urls)
    }

    var isActive: Bool { completion != nil }
}

extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    var buildNumber: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }
}
