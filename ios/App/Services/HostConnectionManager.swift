import Foundation
import SwiftUI
import Observation

@Observable
public final class HostConnectionManager {
    public static let shared = HostConnectionManager()

    private let hostsKey = "com.simplewithus.harness.saved_hosts"
    private let activeHostIdKey = "com.simplewithus.harness.active_host_id"

    public var hosts: [HostConnection] = []
    public var activeHost: HostConnection?
    public var isScanning: Bool = false
    public var isPinging: Bool = false

    public init() {
        loadHosts()
    }

    public func loadHosts() {
        if let data = UserDefaults.standard.data(forKey: hostsKey),
           let decoded = try? JSONDecoder().decode([HostConnection].self, from: data),
           !decoded.isEmpty {
            self.hosts = decoded
        } else {
            self.hosts = HostConnection.defaults
            saveHosts()
        }

        if let activeIdString = UserDefaults.standard.string(forKey: activeHostIdKey),
           let activeId = UUID(uuidString: activeIdString),
           let match = hosts.first(where: { $0.id == activeId }) {
            self.activeHost = match
        } else {
            self.activeHost = hosts.first(where: { $0.isActive }) ?? hosts.first
            if let active = self.activeHost {
                setActiveHost(active)
            }
        }
    }

    public func saveHosts() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: hostsKey)
        }
    }

    public func setActiveHost(_ host: HostConnection) {
        for i in 0..<hosts.count {
            hosts[i].isActive = (hosts[i].id == host.id)
        }
        activeHost = hosts.first(where: { $0.id == host.id })
        UserDefaults.standard.set(host.id.uuidString, forKey: activeHostIdKey)
        saveHosts()
    }

    public func addHost(_ host: HostConnection) {
        var newHost = host
        if hosts.isEmpty {
            newHost.isActive = true
            activeHost = newHost
        }
        hosts.append(newHost)
        saveHosts()
        Task {
            await pingHost(newHost)
        }
    }

    public func updateHost(_ host: HostConnection) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
            if activeHost?.id == host.id {
                activeHost = host
            }
            saveHosts()
            Task {
                await pingHost(host)
            }
        }
    }

    public func deleteHost(_ host: HostConnection) {
        hosts.removeAll(where: { $0.id == host.id })
        if activeHost?.id == host.id {
            activeHost = hosts.first
            if let first = activeHost {
                setActiveHost(first)
            }
        }
        saveHosts()
    }

    @discardableResult
    public func pingHost(_ host: HostConnection) async -> (status: ConnectionStatus, latencyMs: Double) {
        guard let url = host.baseURL else {
            return (.unknown, 0)
        }

        let start = CFAbsoluteTimeGetCurrent()
        // Probe /v1/info endpoint to negotiate features and verify health
        let infoURL = url.appendingPathComponent("v1/info")
        var request = URLRequest(url: infoURL)
        request.httpMethod = "GET"
        if !host.authToken.isEmpty {
            request.setValue("Bearer \(host.authToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 4.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

            let status: ConnectionStatus
            var discoveredFeatures: [String]?
            var hostKind = host.hostKind

            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 {
                    status = host.authToken.isEmpty ? .unauthorized : .online
                } else if (200..<500).contains(http.statusCode) {
                    status = .online

                    // Parse /v1/info metadata if valid JSON returned
                    struct HostInfo: Codable {
                        let name: String?
                        let version: String?
                        let features: [String]?
                        let agent_count: Int?
                    }
                    if let info = try? JSONDecoder().decode(HostInfo.self, from: data) {
                        if let feats = info.features {
                            discoveredFeatures = feats
                            if feats.contains("crons") || feats.contains("agents") || feats.contains("drive") {
                                hostKind = .miniMaxCompanion
                            } else if feats.contains("composio") || feats.contains("rag") || feats.contains("tools") {
                                hostKind = .harnessDaemon
                            }
                        }
                    }
                } else {
                    status = .offline
                }
            } else {
                status = .offline
            }

            await MainActor.run {
                if let idx = self.hosts.firstIndex(where: { $0.id == host.id }) {
                    self.hosts[idx].status = status
                    self.hosts[idx].latencyMs = elapsed
                    self.hosts[idx].lastSeen = Date()
                    self.hosts[idx].hostKind = hostKind
                    if let f = discoveredFeatures {
                        self.hosts[idx].features = f
                    }
                    if self.activeHost?.id == host.id {
                        self.activeHost?.status = status
                        self.activeHost?.latencyMs = elapsed
                        self.activeHost?.lastSeen = Date()
                        self.activeHost?.hostKind = hostKind
                        if let f = discoveredFeatures {
                            self.activeHost?.features = f
                        }
                    }
                    self.saveHosts()
                }
            }
            return (status, elapsed)
        } catch {
            await MainActor.run {
                if let idx = self.hosts.firstIndex(where: { $0.id == host.id }) {
                    self.hosts[idx].status = .offline
                    self.hosts[idx].latencyMs = nil
                    if self.activeHost?.id == host.id {
                        self.activeHost?.status = .offline
                        self.activeHost?.latencyMs = nil
                    }
                    self.saveHosts()
                }
            }
            return (.offline, 0)
        }
    }

    public func pingAllHosts() async {
        await MainActor.run { isPinging = true }
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask {
                    _ = await self.pingHost(host)
                }
            }
        }
        await MainActor.run { isPinging = false }
    }

    public func parsePairingURL(_ url: URL) -> HostConnection? {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "harness" || scheme == "minimax" || scheme == "minimax-remote",
              url.host == "pair" else { return nil }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let items = comps?.queryItems ?? []

        let isMM = (scheme == "minimax" || scheme == "minimax-remote")
        let defaultName = isMM ? "MiniMax Companion" : "Harness Host"
        let defaultPort = isMM ? 7842 : 3080

        let name = items.first(where: { $0.name == "name" })?.value ?? defaultName
        // Support both ?host= and short ?h=
        let host = items.first(where: { $0.name == "host" })?.value
            ?? items.first(where: { $0.name == "h" })?.value
        guard let host = host, !host.isEmpty else { return nil }

        // Support both ?port= and short ?p=
        let portStr = items.first(where: { $0.name == "port" })?.value
            ?? items.first(where: { $0.name == "p" })?.value
            ?? String(defaultPort)
        let port = Int(portStr) ?? defaultPort

        let tlsStr = items.first(where: { $0.name == "tls" })?.value ?? "0"
        let useTLS = tlsStr == "1" || tlsStr.lowercased() == "true"

        // Support both ?token= and short ?t=
        let token = items.first(where: { $0.name == "token" })?.value
            ?? items.first(where: { $0.name == "t" })?.value
            ?? ""

        return HostConnection(
            name: name,
            host: host,
            port: port,
            useTLS: useTLS,
            authToken: token,
            isActive: false,
            status: .unknown,
            osType: "macOS",
            hostKind: isMM ? .miniMaxCompanion : .harnessDaemon,
            features: isMM ? ["chat", "crons", "agents", "drive"] : ["chat", "tools", "composio", "rag", "computer_use"]
        )
    }

    public func importPairingCode(_ code: String) -> HostConnection? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            if let host = parsePairingURL(url) {
                return host
            }
        }
        // Handle host:port@token or bare host
        if trimmed.contains(":") {
            let parts = trimmed.components(separatedBy: ":")
            let host = parts[0]
            var port = 3080
            var token = ""
            if parts.count > 1 {
                let rest = parts[1]
                if rest.contains("@") {
                    let sub = rest.components(separatedBy: "@")
                    port = Int(sub[0]) ?? 3080
                    token = sub[1]
                } else {
                    port = Int(rest) ?? 3080
                }
            }
            let isMM = (port == 7842)
            return HostConnection(
                name: isMM ? "MiniMax Companion (\(host))" : "Harness Host (\(host))",
                host: host,
                port: port,
                useTLS: false,
                authToken: token,
                isActive: false,
                status: .unknown,
                osType: "macOS",
                hostKind: isMM ? .miniMaxCompanion : .harnessDaemon,
                features: isMM ? ["chat", "crons", "agents", "drive"] : ["chat", "tools", "composio", "rag", "computer_use"]
            )
        }
        return nil
    }
}
