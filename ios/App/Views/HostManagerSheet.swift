import SwiftUI

public struct HostManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var connectionManager = HostConnectionManager.shared
    @State private var isShowingAddHost: Bool = false
    @State private var isShowingPairingInput: Bool = false
    @State private var pairingCodeText: String = ""
    @State private var pairingError: String?
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(connectionManager.hosts) { host in
                        HostRowView(
                            host: host,
                            isActive: connectionManager.activeHost?.id == host.id,
                            onSelect: {
                                connectionManager.setActiveHost(host)
                            },
                            onPing: {
                                Task {
                                    await connectionManager.pingHost(host)
                                }
                            }
                        )
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let host = connectionManager.hosts[index]
                            connectionManager.deleteHost(host)
                        }
                    }
                } header: {
                    Text("Configured Computers & Clusters")
                } footer: {
                    Text("Harness saves each host endpoint and authentication token.&nbsp; Switch between your Mac, Hetzner cloud, or local server seamlessly.")
                }
                
                Section {
                    Button(action: {
                        isShowingAddHost = true
                    }) {
                        Label("Add New Computer / Host", systemImage: "plus.circle.fill")
                    }
                    
                    Button(action: {
                        isShowingPairingInput = true
                    }) {
                        Label("Import via Pairing URL or Code", systemImage: "qrcode.viewfinder")
                    }
                    
                    Button(action: {
                        Task {
                            await connectionManager.pingAllHosts()
                        }
                    }) {
                        HStack {
                            Label("Ping All Hosts", systemImage: "arrow.clockwise")
                            if connectionManager.isPinging {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Harness Computers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isShowingAddHost) {
                AddHostSheet()
            }
            .alert("Import Pairing Code", isPresented: $isShowingPairingInput) {
                TextField("harness://pair?host=... or host:port", text: $pairingCodeText)
                    .autocapitalization(.none)
                Button("Cancel", role: .cancel) {
                    pairingCodeText = ""
                }
                Button("Import") {
                    if let newHost = connectionManager.importPairingCode(pairingCodeText) {
                        connectionManager.addHost(newHost)
                        connectionManager.setActiveHost(newHost)
                        pairingCodeText = ""
                    } else {
                        pairingError = "Invalid pairing code or URL format."
                    }
                }
            } message: {
                Text("Paste a harness:// URL generated on your Mac or cloud server.")
            }
        }
    }
}

struct HostRowView: View {
    let host: HostConnection
    let isActive: Bool
    let onSelect: () -> Void
    let onPing: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Status icon
                Image(systemName: host.status.icon)
                    .foregroundColor(statusColor(host.status))
                    .font(.system(size: 20))
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(host.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        if isActive {
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text("\(host.scheme)://\(host.hostAndPort)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if let latency = host.latencyMs {
                    Text("\(Int(latency))ms")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                }
                
                Button(action: onPing) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func statusColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .online: return .green
        case .offline: return .red
        case .connecting: return .orange
        case .unauthorized: return .yellow
        case .unknown: return .gray
        }
    }
}

struct AddHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var connectionManager = HostConnectionManager.shared
    
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var portText: String = "3080"
    @State private var useTLS: Bool = false
    @State private var authToken: String = ""
    @State private var isTesting: Bool = false
    @State private var testResult: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Host Details")) {
                    TextField("Display Name (e.g. Hetzner Cloud)", text: $name)
                    TextField("Hostname / IP (e.g. 100.113.106.39)", text: $host)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                    Toggle("Use TLS (HTTPS)", isOn: $useTLS)
                }
                
                Section(header: Text("Authentication")) {
                    SecureField("Launch Token / Cookie Secret", text: $authToken)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    Text("Found in ~/.dsh/web-launch-url on your host or printed during startup.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    Button(action: testConnection) {
                        HStack {
                            Text("Test Connection")
                            if isTesting {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(host.isEmpty || isTesting)
                    
                    if let result = testResult {
                        Text(result)
                            .font(.footnote)
                            .foregroundColor(result.contains("Success") ? .green : .red)
                    }
                }
            }
            .navigationTitle("Add Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let port = Int(portText) ?? 3080
                        let finalName = name.isEmpty ? host : name
                        let newHost = HostConnection(
                            name: finalName,
                            host: host,
                            port: port,
                            useTLS: useTLS,
                            authToken: authToken,
                            isActive: true,
                            status: .unknown
                        )
                        connectionManager.addHost(newHost)
                        connectionManager.setActiveHost(newHost)
                        dismiss()
                    }
                    .disabled(host.isEmpty)
                }
            }
        }
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        let port = Int(portText) ?? 3080
        let temp = HostConnection(
            name: "Test",
            host: host,
            port: port,
            useTLS: useTLS,
            authToken: authToken
        )
        Task {
            let (status, latency) = await connectionManager.pingHost(temp)
            await MainActor.run {
                isTesting = false
                if status == .online {
                    testResult = "Success: Host responded in \(Int(latency))ms!"
                } else if status == .unauthorized {
                    testResult = "Host reached (401 Auth Required): Set valid launch token."
                } else {
                    testResult = "Connection failed: Host unreachable."
                }
            }
        }
    }
}
