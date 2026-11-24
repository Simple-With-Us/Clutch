import SwiftUI
import UserNotifications

@main
struct ClutchApp: App {
    /// Light is the first-run default; System and Dark are available in Settings.
    @AppStorage("clutch_theme_preference") private var themePreference: String = "light"
    #if os(macOS)
    /// The commands the menu bar offers, shared with the window in front.
    ///
    /// The menu bar reaches the window through this, so a command works
    /// whether the thread rail is showing or hidden.
    @State private var commands = MacWorkspaceCommands()
    #endif

    #if os(macOS)
    /// Brings the app forward for a UI test run, and does nothing otherwise.
    @NSApplicationDelegateAdaptor(ClutchTestActivationDelegate.self) private var testActivation
    #endif

    init() {
        // Sentry links both native targets; without a DSN the start below
        // is a no-op, so local and CI builds without one behave as before.
        SentryTelemetry.start()
        // The delegate is what lets an action on a notification answer the
        // request, and it has to be in place before a notification arrives:
        // a notification can be what launched the app.
        UNUserNotificationCenter.current().delegate = ClutchNotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(colorScheme)
                #if os(macOS)
                .clutchTestWindow()
                .environment(commands)
                #endif
        }
        #if os(macOS)
        WindowGroup("Thread", for: MacThreadWindowRequest.self) { $request in
            MacThreadWindow(request: $request)
                .preferredColorScheme(colorScheme)
                .environment(commands)
        }
        .defaultSize(width: 1040, height: 760)
        .commands { macCommands }
        Settings {
            MacSettingsView()
        }
        #endif
    }

    #if os(macOS)
    /// The Mac menu bar's commands.
    ///
    /// The thread commands are here and not only on the rail, because the
    /// rail can be closed and a command that only exists on a closed rail
    /// is a command that does not exist.
    @CommandsBuilder
    private var macCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Thread") {
                commands.newThread?()
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Open Thread In New Window") {
                commands.newWindow?()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Thread") {
            Button("Refresh Thread") {
                commands.refresh?()
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
    #endif

    private var colorScheme: ColorScheme? {
        switch themePreference {
        case "dark": return .dark
        case "system": return nil
        default: return .light
        }
    }
}
