import SwiftUI
import UIKit
import WebKit

/// What the embedded harness web page is doing.
public enum WebSurfaceState: Equatable {
    case loading
    case ready
    /// harness web answered 401: no valid cookie and no valid launch token.
    case needsPairing
    case failed(String)
}

/// The full harness web UI (sessions, streaming chat, model picker, settings)
/// in a `WKWebView`, with the Harness brand treatment injected the same way
/// the Mac Dock app does it.
struct HarnessWebView: UIViewRepresentable {
    let host: HarnessHost
    /// Changes whenever the page must be (re)loaded: new host, new pairing, or Reload.
    let loadKey: String
    @Binding var state: WebSurfaceState
    let onAuthenticated: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.applicationNameForUserAgent = "HarnessiOS/\(Bundle.main.shortVersion)"
        config.userContentController = Self.brandingController()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        #if DEBUG
        webView.isInspectable = true
        #endif
        context.coordinator.load(host: host, key: loadKey, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedKey != loadKey {
            context.coordinator.load(host: host, key: loadKey, in: webView)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: HarnessWebView
        var loadedKey: String?
        private var currentHost: HarnessHost?

        init(parent: HarnessWebView) {
            self.parent = parent
        }

        func load(host: HarnessHost, key: String, in webView: WKWebView) {
            loadedKey = key
            currentHost = host
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

        // Keep navigation on the paired origin; send everything else to Safari.
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
            UIApplication.shared.open(url)
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
            webView.reload()
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
                    UIApplication.shared.open(url)
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
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            present(alert, fallback: completionHandler)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor (Bool) -> Void
        ) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            present(alert) { completionHandler(false) }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor (String?) -> Void
        ) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            present(alert) { completionHandler(nil) }
        }

        private func present(_ alert: UIAlertController, fallback: @escaping () -> Void) {
            guard let presenter = UIApplication.shared.topViewController else {
                fallback()
                return
            }
            presenter.present(alert, animated: true)
        }
    }

    // MARK: - Branding

    /// Hides the upstream brand mark and adds the Harness "H" monogram,
    /// matching `src/web/dock-app/HarnessWindow.swift` on the Mac.
    static func brandingController() -> WKUserContentController {
        let controller = WKUserContentController()
        let css = """
        [data-slot*="brand"], [data-slot*="brand"] *, [class*="brandMark"], [class*="brandMark"] *,
        [class*="brandName"], [class*="brandName"] *, [class*="_brandIdentity"] > span,
        [class*="_brandIdentity"] > div:not([data-harness-brand]),
        button[class*="brand"] svg:not([data-harness-brand] svg),
        button[class*="_brand"] svg:not([data-harness-brand] svg) {
          display: none !important;
        }
        [class*="_fishHitbox"], [class*="_fish"], [class*="fishHitbox"] {
          display: none !important;
        }
        [data-harness-brand] { display: inline-flex !important; }
        [data-harness-brand] svg { display: block !important; }
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
            if (identity && !identity.querySelector('[data-harness-brand="1"]')) {
              const h = document.createElement('div');
              h.dataset.harnessBrand = '1';
              h.style.cssText = 'display:inline-flex;flex-direction:column;align-items:flex-start;justify-content:center;gap:2px;line-height:1;user-select:none;padding:1px 0;';
              h.innerHTML = '<svg width="22" height="18" viewBox="0 0 484 440" fill="currentColor" style="display:block;"><path d="M0 0h112v172h260V0h112v440H372V268H112v172H0z"/></svg>'
                + '<span style="font-size:9.5px;font-weight:700;letter-spacing:0.12em;line-height:1;color:inherit;opacity:0.85;">HARNESS</span>';
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

extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    var buildNumber: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }
}

extension UIApplication {
    var topViewController: UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
