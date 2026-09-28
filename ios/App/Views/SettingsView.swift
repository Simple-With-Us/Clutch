import SwiftUI

public struct SettingsView: View {
    @State private var connectionManager = HostConnectionManager.shared
    @State private var transcriptionService = TranscriptionService.shared
    @State private var isShowingHostManager: Bool = false

    @AppStorage("harness_theme_preference") private var themePreference: String = "light"
    @AppStorage("harness_minimax_key") private var miniMaxApiKey: String = ""
    @AppStorage("harness_deepseek_key") private var deepSeekApiKey: String = ""
    @State private var transcriptionMode: TranscriptionService.TranscriptionMode = TranscriptionService.shared.mode
    @State private var openRouterApiKey: String = TranscriptionService.shared.openRouterApiKey

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                // Host section
                Section(header: Text("Active Host Connection")) {
                    Button(action: {
                        isShowingHostManager = true
                    }) {
                        HStack {
                            Image(systemName: connectionManager.activeHost?.hostKind.icon ?? "cpu.fill")
                                .foregroundColor(connectionManager.activeHost?.status == .online ? .green : .orange)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(connectionManager.activeHost?.name ?? "No Active Host")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)

                                Text("\(connectionManager.activeHost?.scheme ?? "http")://\(connectionManager.activeHost?.hostAndPort ?? "—")")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Text("Switch")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                }

                // Voice & Speech-To-Text
                Section(header: Text("Voice & Speech-To-Text (Whisper)")) {
                    Picker("Engine", selection: $transcriptionMode) {
                        ForEach(TranscriptionService.TranscriptionMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .onChange(of: transcriptionMode) { _, newMode in
                        transcriptionService.mode = newMode
                    }

                    SecureField("OpenRouter API Key (Cloud)", text: $openRouterApiKey)
                        .autocapitalization(.none)
                        .onChange(of: openRouterApiKey) { _, newKey in
                            transcriptionService.openRouterApiKey = newKey
                        }

                    Text("Hold the microphone icon in Chat to dictate directives.  Local host uses whisper.cpp; cloud fallback uses OpenRouter Whisper.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // Provider Credentials
                Section(header: Text("Model Provider Keys (Optional)")) {
                    SecureField("MiniMax API Key", text: $miniMaxApiKey)
                        .autocapitalization(.none)
                    SecureField("DeepSeek API Key", text: $deepSeekApiKey)
                        .autocapitalization(.none)
                    Text("Host automatically uses credentials configured in its environment and Infisical vaults.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // Appearance
                Section(header: Text("Appearance")) {
                    Picker("Theme", selection: $themePreference) {
                        Text("Light (Default)").tag("light")
                        Text("Dark").tag("dark")
                        Text("System").tag("system")
                    }
                }

                // About
                Section(header: Text("About Harness")) {
                    HStack {
                        Text("Product Name")
                        Spacer()
                        Text("Harness (for iOS)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Architecture")
                        Spacer()
                        Text("Universal (MiniMax + DeepSeek)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Bundle ID")
                        Spacer()
                        Text("com.simplewithus.harness.ios")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("0.2.0")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Fleet Acronym")
                        Spacer()
                        Text("HR")
                            .foregroundColor(.secondary)
                    }
                    Link("GitHub Repository", destination: URL(string: "https://github.com/jaywedgeworth22/Harness")!)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $isShowingHostManager) {
                HostManagerSheet()
            }
        }
    }
}
