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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4.0
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            
            let status: ConnectionStatus
            if let http = response as? HTTPURLResponse {
                // 200..499 means the server responded!
                // 401 is normal for auth-walled dsh-web without launch token
                if http.statusCode == 401 {
                    status = host.authToken.isEmpty ? .unauthorized : .online
                } else if (200..<500).contains(http.statusCode) {
                    status = .online
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
                    if self.activeHost?.id == host.id {
                        self.activeHost?.status = status
                        self.activeHost?.latencyMs = elapsed
                        self.activeHost?.lastSeen = Date()
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
        guard url.scheme == "harness", url.host == "pair" else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let items = comps?.queryItems ?? []
        
        let name = items.first(where: { $0.name == "name" })?.value ?? "Paired Computer"
        guard let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty else { return nil }
        let portStr = items.first(where: { $0.name == "port" })?.value ?? "3080"
        let port = Int(portStr) ?? 3080
        let tlsStr = items.first(where: { $0.name == "tls" })?.value ?? "0"
        let useTLS = tlsStr == "1" || tlsStr.lowercased() == "true"
        let token = items.first(where: { $0.name == "token" })?.value ?? ""
        
        return HostConnection(
            name: name,
            host: host,
            port: port,
            useTLS: useTLS,
            authToken: token,
            isActive: false,
            status: .unknown
        )
    }
    
    public func importPairingCode(_ code: String) -> HostConnection? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme == "harness" {
            return parsePairingURL(url)
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
            return HostConnection(
                name: "Imported Host (\(host))",
                host: host,
                port: port,
                useTLS: false,
                authToken: token,
                isActive: false,
                status: .unknown
            )
        }
        return nil
    }
}
