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

public enum HostKind: String, Codable, CaseIterable {
    case harnessDaemon = "Harness Daemon"
    case miniMaxCompanion = "MiniMax Companion"
    case cloudServer = "Cloud Server"
    case custom = "Custom"

    public var defaultPort: Int {
        switch self {
        case .harnessDaemon: return 3080
        case .miniMaxCompanion: return 7842
        case .cloudServer, .custom: return 3080
        }
    }

    public var icon: String {
        switch self {
        case .harnessDaemon: return "cpu.fill"
        case .miniMaxCompanion: return "sparkles"
        case .cloudServer: return "cloud.fill"
        case .custom: return "server.rack"
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
    public var hostKind: HostKind
    public var features: [String]

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
        osType: String? = "macOS",
        hostKind: HostKind = .harnessDaemon,
        features: [String] = ["chat", "tools", "composio", "rag", "computer_use"]
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
        self.hostKind = hostKind
        self.features = features
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
        comps.scheme = hostKind == .miniMaxCompanion ? "minimax" : "harness"
        comps.host = "pair"
        comps.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "h", value: host),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "tls", value: useTLS ? "1" : "0"),
            URLQueryItem(name: "t", value: authToken),
            URLQueryItem(name: "v", value: "1")
        ]
        return comps.url?.absoluteString ?? ""
    }

    public static var defaults: [HostConnection] {
        [
            HostConnection(
                name: "MacBook Pro (Harness)",
                host: "127.0.0.1",
                port: 3080,
                useTLS: false,
                authToken: "",
                isActive: true,
                status: .online,
                osType: "macOS",
                hostKind: .harnessDaemon,
                features: ["chat", "tools", "composio", "rag", "computer_use"]
            ),
            HostConnection(
                name: "Mac Mavis (MiniMax)",
                host: "127.0.0.1",
                port: 7842,
                useTLS: false,
                authToken: "",
                isActive: false,
                status: .unknown,
                osType: "macOS",
                hostKind: .miniMaxCompanion,
                features: ["chat", "crons", "agents", "drive"]
            ),
            HostConnection(
                name: "Hetzner Cloud Server",
                host: "cloud.jays.services",
                port: 3080,
                useTLS: true,
                authToken: "",
                isActive: false,
                status: .offline,
                osType: "Linux",
                hostKind: .cloudServer,
                features: ["chat", "tools", "composio", "rag", "computer_use", "crons"]
            )
        ]
    }
}
