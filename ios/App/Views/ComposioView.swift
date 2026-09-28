import SwiftUI

public struct ComposioView: View {
    @State private var composio = ComposioClient.shared
    @State private var isShowingKeyModal: Bool = false
    @State private var apiKeyInput: String = ""
    @State private var isTestingAction: Bool = false
    @State private var testApp: ComposioApp?
    
    public init() {}
    
    public var body: some View {
        List {
            // Composio status & API key banner
            Section {
                HStack {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.indigo)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Composio Tool Engine")
                            .font(.system(size: 15, weight: .bold))
                        Text(composio.apiKey.isEmpty ? "API Key required for direct triggers" : "Authorized & Active")
                            .font(.system(size: 12))
                            .foregroundColor(composio.apiKey.isEmpty ? .orange : .green)
                    }
                    
                    Spacer()
                    
                    Button(composio.apiKey.isEmpty ? "Set Key" : "Edit Key") {
                        apiKeyInput = composio.apiKey
                        isShowingKeyModal = true
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
            
            // Available App Integrations
            Section(header: Text("Connected Apps (\(composio.apps.filter { $0.isConnected }.count))")) {
                ForEach(composio.apps) { app in
                    HStack(spacing: 12) {
                        Image(systemName: app.iconName)
                            .font(.system(size: 18))
                            .foregroundColor(app.isConnected ? .accentColor : .secondary)
                            .frame(width: 28)
                        
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(app.name)
                                    .font(.system(size: 15, weight: .semibold))
                                
                                if app.isConnected {
                                    Text("CONNECTED")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15))
                                        .foregroundColor(.green)
                                        .clipShape(Capsule())
                                }
                            }
                            
                            Text(app.description)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            composio.toggleAppConnection(app)
                        }) {
                            Text(app.isConnected ? "Disconnect" : "Connect")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(app.isConnected ? Color(.secondarySystemBackground) : Color.accentColor)
                                .foregroundColor(app.isConnected ? .primary : .white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            // Fast Action Execution
            Section(header: Text("Quick Actions")) {
                Button(action: {
                    Task {
                        isTestingAction = true
                        _ = await composio.executeAction(
                            appId: "github",
                            actionName: "check_prs",
                            params: ["repo": "jaywedgeworth22/Harness"]
                        )
                        isTestingAction = false
                    }
                }) {
                    HStack {
                        Label("Query Open PRs on GitHub", systemImage: "arrow.triangle.pull")
                        if isTestingAction {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }
                .disabled(isTestingAction)
                
                if let output = composio.lastActionOutput {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ACTION RESULT")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Text(output.replacingOccurrences(of: "&nbsp;", with: "  "))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .sheet(isPresented: $isShowingKeyModal) {
            NavigationStack {
                Form {
                    Section(header: Text("Composio API Key")) {
                        SecureField("comp_...", text: $apiKeyInput)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        Text("Obtain from https://app.composio.dev/settings/api-keys")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .navigationTitle("Composio Key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isShowingKeyModal = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            composio.saveApiKey(apiKeyInput)
                            isShowingKeyModal = false
                        }
                    }
                }
            }
        }
    }
}
