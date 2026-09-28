import Foundation

public enum ConnectionStatus: String, Codable, CaseIterable {
    case online = "Online"
    case offline = "Offline"
    case connecting = "Connecting"
    case unauthorized = "Unauthorized"
    case unknown = "Unknown"
    
    public var icon: String {
        switch self {
        case .online: return "checkmark.circle.fill"
        case .offline: return "xmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath.circle.fill"
        case .unauthorized: return "lock.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

public struct HostConnection: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var useTLS: Bool
    public var authToken: String
    public var isActive: Bool
    public var lastSeen: Date?
    public var latencyMs: Double?
    public var status: ConnectionStatus
    public var osType: String?
    
    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 3080,
        useTLS: Bool = false,
        authToken: String = "",
        isActive: Bool = false,
        lastSeen: Date? = nil,
        latencyMs: Double? = nil,
        status: ConnectionStatus = .unknown,
        osType: String? = "macOS"
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.authToken = authToken
        self.isActive = isActive
        self.lastSeen = lastSeen
        self.latencyMs = latencyMs
        self.status = status
        self.osType = osType
    }
    
    public var scheme: String {
        useTLS ? "https" : "http"
    }
    
    public var hostAndPort: String {
        if (useTLS && port == 443) || (!useTLS && port == 80) {
            return host
        }
        return "\(host):\(port)"
    }
    
    public var baseURL: URL? {
        URL(string: "\(scheme)://\(hostAndPort)")
    }
    
    public var webLaunchURL: URL? {
        guard let base = baseURL else { return nil }
        if authToken.isEmpty {
            return base
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "token", value: authToken)]
        return components?.url ?? base
    }
    
    public var pairingURLString: String {
        var comps = URLComponents()
        comps.scheme = "harness"
        comps.host = "pair"
        comps.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "tls", value: useTLS ? "1" : "0"),
            URLQueryItem(name: "token", value: authToken)
        ]
        return comps.url?.absoluteString ?? ""
    }
    
    public static var defaults: [HostConnection] {
        [
            HostConnection(
                name: "MacBook Pro (Local)",
                host: "127.0.0.1",
                port: 3080,
                useTLS: false,
                authToken: "",
                isActive: true,
                status: .online,
                osType: "macOS"
            ),
            HostConnection(
                name: "Tailscale Mac",
                host: "macbook.boa-roygbiv.ts.net",
                port: 3080,
                useTLS: false,
                authToken: "",
                isActive: false,
                status: .unknown,
                osType: "macOS"
            ),
            HostConnection(
                name: "Hetzner Cloud Harness",
                host: "cloud.jays.services",
                port: 3080,
                useTLS: true,
                authToken: "",
                isActive: false,
                status: .offline,
                osType: "Linux"
            )
        ]
    }
}
