import SwiftUI

@main
struct HarnessCompanionApp: App {
    @State private var connectionManager = HostConnectionManager.shared
    @AppStorage("harness_theme_preference") private var themePreference: String = "light"
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .preferredColorScheme(colorScheme)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .task {
                    // Initial health probe across all hosts on launch
                    await connectionManager.pingAllHosts()
                }
        }
    }
    
    private var colorScheme: ColorScheme? {
        switch themePreference {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
    
    private func handleIncomingURL(_ url: URL) {
        if let host = connectionManager.parsePairingURL(url) {
            connectionManager.addHost(host)
            connectionManager.setActiveHost(host)
        }
    }
}
