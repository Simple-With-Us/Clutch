import SwiftUI

/// The Mac settings window, behind the comma key.
///
/// The settings the app has live here rather than only in a sheet, so they
/// are reachable while a thread is open and the reader is in the middle of
/// something.
struct MacSettingsView: View {
    @AppStorage("clutch_theme_preference") private var themePreference: String = "light"
    @AppStorage(MacBusySendMode.storageKey) private var busySendModeRawValue = MacBusySendMode.defaultMode.rawValue

    private var busySendMode: MacBusySendMode {
        MacBusySendMode(rawValue: busySendModeRawValue) ?? .queue
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themePreference) {
                    Text("Light").tag("light")
                    Text("System").tag("system")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Messages While Working") {
                Picker("Default Action", selection: $busySendModeRawValue) {
                    Text("Queue").tag(MacBusySendMode.queue.rawValue)
                    Text("Steer").tag(MacBusySendMode.steer.rawValue)
                }
                .pickerStyle(.segmented)
                Text(busySendMode.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }
}
