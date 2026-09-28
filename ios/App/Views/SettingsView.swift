import SwiftUI

public struct SettingsView: View {
    @State private var connectionManager = HostConnectionManager.shared
    @State private var isShowingHostManager: Bool = false
    
    @AppStorage("harness_theme_preference") private var themePreference: String = "light"
    @AppStorage("harness_minimax_key") private var miniMaxApiKey: String = ""
    @AppStorage("harness_deepseek_key") private var deepSeekApiKey: String = ""
    @AppStorage("harness_sentry_dsn") private var sentryDsn: String = ""
    
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
                            Image(systemName: connectionManager.activeHost?.status.icon ?? "laptopcomputer")
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
                        Text("Bundle ID")
                        Spacer()
                        Text("com.simplewithus.harness.ios")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("0.1.0")
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
