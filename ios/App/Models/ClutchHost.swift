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

/// One clutch web deployment the app can show — a Mac over Tailscale, or
/// `127.0.0.1:3180` when running in the Simulator on that Mac.
public struct ClutchHost: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    /// `scheme://host[:port]` with no path.
    public var origin: URL
    /// The launch token from the pairing link.  Cleared once clutch web has
    /// exchanged it for its signed cookie, so it is never kept longer than needed.
    public var pendingLaunchToken: String?
    public var status: HostStatus
    public var lastChecked: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        origin: URL,
        pendingLaunchToken: String? = nil,
        status: HostStatus = .unknown,
        lastChecked: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.pendingLaunchToken = pendingLaunchToken
        self.status = status
        self.lastChecked = lastChecked
    }

    public init(pairing: PairingPayload) {
        self.init(name: pairing.name, origin: pairing.origin, pendingLaunchToken: pairing.launchToken)
    }

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
