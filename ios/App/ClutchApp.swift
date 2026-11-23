import SwiftUI

@main
struct ClutchApp: App {
    /// Light is the first-run default; System and Dark are available in Settings.
    @AppStorage("clutch_theme_preference") private var themePreference: String = "light"

    init() {
        // Sentry links both native targets; without a DSN the start below
        // is a no-op, so local and CI builds without one behave as before.
        SentryTelemetry.start()
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
                #if os(macOS)
                .clutchTestWindow()
                #endif
        }
        #if os(macOS)
        WindowGroup("Thread", for: MacThreadWindowRequest.self) { $request in
            MacThreadWindow(request: $request)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 1040, height: 760)
        #endif
    }

    private var colorScheme: ColorScheme? {
        switch themePreference {
        case "dark": return .dark
        case "system": return nil
        default: return .light
        }
    }
}
