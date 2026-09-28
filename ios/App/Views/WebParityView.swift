import SwiftUI
import WebKit

public struct WebParityView: View {
    @State private var connectionManager = HostConnectionManager.shared
    @State private var isShowingHostManager: Bool = false
    @State private var reloadToken: UUID = UUID()
    @State private var isLoading: Bool = true
    @State private var canGoBack: Bool = false
    @State private var canGoForward: Bool = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            ZStack {
                if let host = connectionManager.activeHost, let url = host.webLaunchURL {
                    HarnessWebViewContainer(
                        url: url,
                        reloadToken: reloadToken,
                        isLoading: $isLoading,
                        canGoBack: $canGoBack,
                        canGoForward: $canGoForward
                    )
                    .edgesIgnoringSafeArea(.bottom)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "network.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Host Connected")
                            .font(.headline)
                        Button("Select Host") {
                            isShowingHostManager = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                
                if isLoading {
                    VStack {
                        ProgressView()
                            .padding()
                            .background(Color(.systemBackground).opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .navigationTitle("Harness Web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        isShowingHostManager = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: connectionManager.activeHost?.status.icon ?? "laptopcomputer")
                                .font(.system(size: 11))
                                .foregroundColor(connectionManager.activeHost?.status == .online ? .green : .orange)
                            Text(connectionManager.activeHost?.name ?? "Host")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button(action: {
                            reloadToken = UUID()
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        
                        if let url = connectionManager.activeHost?.webLaunchURL {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingHostManager) {
                HostManagerSheet()
            }
        }
    }
}

struct HarnessWebViewContainer: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        
        let userContent = WKUserContentController()
        
        // CSS injection for brand header & styling parity
        let css = """
        [data-slot*="brand"], [data-slot*="brand"] *, [class*="brandMark"], [class*="brandMark"] *,
        [class*="brandName"], [class*="brandName"] *, [class*="_brandIdentity"] > span,
        [class*="_brandIdentity"] > div:not([data-harness-brand]),
        button[class*="brand"] svg:not([data-harness-brand] svg),
        button[class*="_brand"] svg:not([data-harness-brand] svg) {
          display: none !important;
        }
        [class*="_fishHitbox"], [class*="_fish"], [class*="fishHitbox"], [class*="fish"] {
          display: none !important;
        }
        [data-harness-brand] { display: inline-flex !important; }
        [data-harness-brand] svg { display: block !important; }
        [class*="group-label"], [class*="vendor"], [class*="section-label"] { text-transform: capitalize; }
        """
        
        let cssBootstrap = """
        (function () {
          var s = document.createElement('style');
          s.textContent = `\(css)`;
          (document.head || document.documentElement).appendChild(s);
        })();
        """
        userContent.addUserScript(WKUserScript(source: cssBootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        
        // JS injection for H monogram and badges
        let script = """
        (function () {
          const updateBrandHeader = () => {
            const brandIdentity = document.querySelector('[class*="brandIdentity"]');
            if (brandIdentity && !brandIdentity.querySelector('[data-harness-brand="1"]')) {
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
          };
          updateBrandHeader();
          const mo = new MutationObserver(() => updateBrandHeader());
          mo.observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
        userContent.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        
        config.userContentController = userContent
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        
        let request = URLRequest(url: url)
        webView.load(request)
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            let request = URLRequest(url: url)
            uiView.load(request)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HarnessWebViewContainer
        var lastReloadToken: UUID?
        
        init(_ parent: HarnessWebViewContainer) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
