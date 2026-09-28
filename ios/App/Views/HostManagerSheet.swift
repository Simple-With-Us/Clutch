import SwiftUI

public struct HostManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var connectionManager = HostConnectionManager.shared
    @ObservedObject private var discovery = BonjourDiscovery.shared

    @State private var isShowingAddHost: Bool = false
    @State private var isShowingQRScanner: Bool = false
    @State private var isShowingPairingInput: Bool = false
    @State private var pairingCodeText: String = ""
    @State private var pairingError: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                // Action Buttons at top
                Section {
                    Button(action: {
                        isShowingQRScanner = true
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 18))
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Scan Pairing QR Code")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Scan QR shown by Harness or MiniMax Companion")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Button(action: {
                        isShowingAddHost = true
                    }) {
                        Label("Add Host Manually", systemImage: "plus.circle.fill")
                    }

                    Button(action: {
                        isShowingPairingInput = true
                    }) {
                        Label("Import via URL or Code", systemImage: "link")
                    }
                }

                // Bonjour Discovered Hosts
                if !discovery.discoveredHosts.isEmpty {
                    Section {
                        ForEach(discovery.discoveredHosts) { disc in
                            HStack {
                                Image(systemName: disc.isMiniMax ? "sparkles" : "cpu.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 18))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(disc.name)
                                        .font(.system(size: 14, weight: .medium))
                                    Text("\(disc.isMiniMax ? "MiniMax Companion" : "Harness Daemon") • \(disc.effectiveHost):\(disc.defaultPort)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button("Connect") {
                                    let newHost = HostConnection(
                                        name: disc.name,
                                        host: disc.effectiveHost,
                                        port: disc.defaultPort,
                                        useTLS: false,
                                        authToken: "",
                                        isActive: true,
                                        status: .online,
                                        osType: "macOS",
                                        hostKind: disc.isMiniMax ? .miniMaxCompanion : .harnessDaemon,
                                        features: disc.isMiniMax ? ["chat", "crons", "agents", "drive"] : ["chat", "tools", "composio", "rag", "computer_use"]
                                    )
                                    connectionManager.addHost(newHost)
                                    connectionManager.setActiveHost(newHost)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                                .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        HStack {
                            Text("Discovered On Local Network")
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                    } footer: {
                        Text("Discovered automatically via Bonjour (_harness._tcp and _minimax._tcp).  Tap Connect to pair instantly.")
                    }
                }

                // Configured Hosts
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
                    HStack {
                        Text("Configured Computers & Clusters")
                        Spacer()
                        Button("Ping All") {
                            Task {
                                await connectionManager.pingAllHosts()
                            }
                        }
                        .font(.system(size: 12))
                    }
                } footer: {
                    Text("Harness saves each host endpoint and authentication token.  Switch between your Mac, Hetzner cloud, or local server seamlessly.")
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
            .onAppear {
                discovery.startDiscovery()
            }
            .onDisappear {
                discovery.stopDiscovery()
            }
            .sheet(isPresented: $isShowingQRScanner) {
                PairingScannerSheet { pairedHost in
                    connectionManager.addHost(pairedHost)
                    connectionManager.setActiveHost(pairedHost)
                    dismiss()
                }
            }
            .sheet(isPresented: $isShowingAddHost) {
                AddHostSheet()
            }
            .alert("Import Pairing Code", isPresented: $isShowingPairingInput) {
                TextField("harness://pair?host=... or minimax://pair", text: $pairingCodeText)
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
                Text("Paste a harness:// or minimax:// URL generated on your Mac or server.")
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
                // Status & Host Type icon
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: host.hostKind.icon)
                        .foregroundColor(.primary)
                        .font(.system(size: 20))
                        .frame(width: 28, height: 28)

                    Circle()
                        .fill(statusColor(host.status))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                }

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

                    HStack(spacing: 6) {
                        Text(host.hostKind.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("\(host.scheme)://\(host.hostAndPort)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
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
    @State private var hostKind: HostKind = .harnessDaemon
    @State private var isTesting: Bool = false
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Host Type")) {
                    Picker("Kind", selection: $hostKind) {
                        ForEach(HostKind.allCases, id: \.self) { kind in
                            Label(kind.rawValue, systemImage: kind.icon).tag(kind)
                        }
                    }
                    .onChange(of: hostKind) { _, newKind in
                        portText = String(newKind.defaultPort)
                    }
                }

                Section(header: Text("Host Details")) {
                    TextField("Display Name (e.g. Hetzner Server)", text: $name)
                    TextField("Hostname / IP (e.g. 100.113.106.39)", text: $host)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                    Toggle("Use TLS (HTTPS)", isOn: $useTLS)
                }

                Section(header: Text("Authentication")) {
                    SecureField("Auth Token / Launch Secret", text: $authToken)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    Text("Found in ~/.dsh/web-launch-url, printed during MiniMax startup, or set in config.")
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
                        saveHost()
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let port = Int(portText) ?? hostKind.defaultPort
        let testHost = HostConnection(
            name: name.isEmpty ? "Test Host" : name,
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            useTLS: useTLS,
            authToken: authToken,
            hostKind: hostKind
        )
        Task {
            let res = await connectionManager.pingHost(testHost)
            await MainActor.run {
                isTesting = false
                if res.status == .online {
                    testResult = "Success!  Host responded in \(Int(res.latencyMs))ms."
                } else if res.status == .unauthorized {
                    testResult = "Server reachable, but token is unauthorized."
                } else {
                    testResult = "Connection failed.  Host is unreachable."
                }
            }
        }
    }

    private func saveHost() {
        let port = Int(portText) ?? hostKind.defaultPort
        let newHost = HostConnection(
            name: name.isEmpty ? host : name,
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            useTLS: useTLS,
            authToken: authToken,
            isActive: connectionManager.hosts.isEmpty,
            status: .unknown,
            hostKind: hostKind,
            features: hostKind == .miniMaxCompanion ? ["chat", "crons", "agents", "drive"] : ["chat", "tools", "composio", "rag", "computer_use"]
        )
        connectionManager.addHost(newHost)
    }
}
