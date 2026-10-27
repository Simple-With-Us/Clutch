import SwiftUI

@main
struct ClutchApp: App {
    /// Light is the first-run default; System and Dark are available in Settings.
    @AppStorage("clutch_theme_preference") private var themePreference: String = "light"

    init() {
        #if os(iOS)
        // Sentry is linked into the iOS targets only; this file is shared with macOS.
        SentryTelemetry.start()
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ClutchResetHosts") {
            HostStore.resetPersistedHosts()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch themePreference {
        case "dark": return .dark
        case "system": return nil
        default: return .light
        }
    }
}
