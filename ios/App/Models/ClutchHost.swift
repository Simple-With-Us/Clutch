import Foundation

/// Reachability of a host as seen by a cookie-less probe of `/`.
public enum HostStatus: String, Codable, Equatable {
    /// clutch web answered with its auth wall — it is running.
    case online
    /// Something answered, but it is not recognizably clutch web.
    case notClutch
    /// No answer (offline, wrong address, or Tailscale not connected).
    case offline
    case unknown

    public var label: String {
        switch self {
        case .online: return "Online"
        case .notClutch: return "Not Clutch"
        case .offline: return "Offline"
        case .unknown: return "Checking"
        }
    }

    public var symbol: String {
        switch self {
        case .online: return "checkmark.circle.fill"
        case .notClutch: return "exclamationmark.triangle.fill"
        case .offline: return "xmark.circle.fill"
        case .unknown: return "circle.dotted"
        }
    }
}

/// What a paired host actually runs.  A `web` host is the full clutch stack
/// (dsh web plus the chat sidecar); a `miniMaxCode` host runs only the chat
/// sidecar in front of `mcode acp` — a Linux server, typically — so it has
/// MiniMax Code threads but no web canvas and no dsh host contract.
public enum HostKind: String, Codable, Equatable, Hashable, Sendable {
    case web
    case miniMaxCode
}

/// One clutch web deployment the app can show — a Mac over Tailscale, or
/// `127.0.0.1:3180` when running in the Simulator on that Mac.
public struct ClutchHost: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: HostKind
    /// `scheme://host[:port]` with no path.
    public var origin: URL
    /// The launch token from the pairing link.  Cleared once clutch web has
    /// exchanged it for its signed cookie, so it is never kept longer than needed.
    public var pendingLaunchToken: String?
    /// The chat-bridge auth token (`Bearer` on `/clutch/v1/chat`).  Long-lived
    /// and refreshed on re-pair — unlike the launch token it is kept.
    public var chatToken: String?
    /// The sidecar's port on the same host.  3181 is the shipped default.
    public var chatPort: Int
    public var status: HostStatus
    public var lastChecked: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        origin: URL,
        kind: HostKind = .web,
        pendingLaunchToken: String? = nil,
        chatToken: String? = nil,
        chatPort: Int = 3181,
        status: HostStatus = .unknown,
        lastChecked: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.origin = origin
        self.pendingLaunchToken = pendingLaunchToken
        self.chatToken = chatToken
        self.chatPort = chatPort
        self.status = status
        self.lastChecked = lastChecked
    }

    // MARK: - Codable (chatToken/chatPort decode to defaults from pre-chat archives)

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, origin, pendingLaunchToken, chatToken, chatPort, status, lastChecked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // Hosts paired before server hosts existed are web hosts.
        kind = try c.decodeIfPresent(HostKind.self, forKey: .kind) ?? .web
        origin = try c.decode(URL.self, forKey: .origin)
        pendingLaunchToken = try c.decodeIfPresent(String.self, forKey: .pendingLaunchToken)
        chatToken = try c.decodeIfPresent(String.self, forKey: .chatToken)
        chatPort = try c.decodeIfPresent(Int.self, forKey: .chatPort) ?? 3181
        status = try c.decodeIfPresent(HostStatus.self, forKey: .status) ?? .unknown
        lastChecked = try c.decodeIfPresent(Date.self, forKey: .lastChecked)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(pendingLaunchToken, forKey: .pendingLaunchToken)
        try c.encodeIfPresent(chatToken, forKey: .chatToken)
        try c.encode(chatPort, forKey: .chatPort)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(lastChecked, forKey: .lastChecked)
    }

    public init(pairing: PairingPayload) {
        self.init(name: pairing.name, origin: pairing.origin, kind: pairing.kind ?? .web, pendingLaunchToken: pairing.launchToken, chatToken: pairing.chatToken, chatPort: pairing.chatPort ?? 3181)
    }

    /// True for a MiniMax Code server host: MiniMax Code threads only, no
    /// web canvas and no dsh host contract behind it.
    public var isMiniMaxCodeOnly: Bool { kind == .miniMaxCode }

    /// `host[:port]` for display.
    public var address: String {
        let host = origin.host ?? origin.absoluteString
        if let port = origin.port { return "\(host):\(port)" }
        return host
    }

    public var rootURL: URL {
        URL(string: "/", relativeTo: origin)?.absoluteURL ?? origin
    }

    /// The URL the web view opens: `/?token=…` while a launch token is
    /// pending, otherwise plain `/` (the cookie authenticates).
    public var launchURL: URL {
        guard let token = pendingLaunchToken, !token.isEmpty,
              var comps = URLComponents(url: rootURL, resolvingAgainstBaseURL: false) else {
            return rootURL
        }
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        return comps.url ?? rootURL
    }

    /// True when `url` is on this host's origin (same scheme, host, and port).
    public func isSameOrigin(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        return scheme == origin.scheme?.lowercased()
            && host == origin.host?.lowercased()
            && ClutchHost.effectivePort(url) == ClutchHost.effectivePort(origin)
    }

    static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
