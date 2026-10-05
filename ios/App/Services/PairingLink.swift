import Foundation

/// A host the app can pair with: the clutch web origin plus the one-time
/// launch token that `dsh web` mints per process.  Visiting
/// `<origin>/?token=<launchToken>` once makes clutch-web set a signed,
/// authority-bound cookie (30-day lifetime) and redirect to `/`; after that the
/// cookie alone authenticates, so the token is only needed for the first load.
public struct PairingPayload: Equatable {
    public var name: String
    public var origin: URL
    public var launchToken: String?
}

public enum PairingLinkError: Error, Equatable {
    case empty
    case unsupportedScheme(String)
    case missingHost
    case invalidURL

    public var message: String {
        switch self {
        case .empty:
            return "Enter a pairing link or an address."
        case .unsupportedScheme(let scheme):
            return "Links starting with \(scheme):// are not clutch pairing links."
        case .missingHost:
            return "That pairing link does not name a host."
        case .invalidURL:
            return "That does not look like a pairing link or an address."
        }
    }
}

/// Parses everything a person can hand the app to reach clutch web:
///
/// - `clutch://pair?url=<launch URL>&name=<label>` — what `clutch-pair-ios` prints and encodes as a QR code.
/// - `clutch://pair?h=<host>&p=<port>&tls=1&t=<token>&name=<label>` — the original v0.2 pairing form.
/// - a plain `http(s)://host[:port]/?token=…` launch URL, as printed by `dsh web`.
/// - a bare `host[:port]` address, which defaults to port 3180.
public enum PairingLink {
    public static let defaultPort = 3180

    public static func parse(_ raw: String) -> Result<PairingPayload, PairingLinkError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        if let schemeEnd = trimmed.range(of: "://") {
            let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
            switch scheme {
            case "clutch", "minimax":
                return parseClutchLink(trimmed)
            case "http", "https":
                return parseWebURL(trimmed, name: nil)
            default:
                return .failure(.unsupportedScheme(scheme))
            }
        }

        return parseBareAddress(trimmed)
    }

    // MARK: - Forms

    private static func parseClutchLink(_ raw: String) -> Result<PairingPayload, PairingLinkError> {
        guard let comps = URLComponents(string: raw), comps.host?.lowercased() == "pair" else {
            return .failure(.invalidURL)
        }
        let isMiniMax = comps.scheme?.lowercased() == "minimax"
        let items = comps.queryItems ?? []
        func value(_ keys: String...) -> String? {
            for key in keys {
                if let v = items.first(where: { $0.name == key })?.value, !v.isEmpty { return v }
            }
            return nil
        }
        let name = value("name") ?? (isMiniMax ? "MiniMax Remote" : nil)

        if let inner = value("url") {
            return parseWebURL(inner, name: name)
        }

        guard let host = value("host", "h") else { return .failure(.missingHost) }
        let fallbackPort = isMiniMax ? 7842 : defaultPort
        let port = value("port", "p").flatMap(Int.init) ?? fallbackPort
        let tlsRaw = (value("tls") ?? "0").lowercased()
        let useTLS = tlsRaw == "1" || tlsRaw == "true"
        var origin = URLComponents()
        origin.scheme = useTLS ? "https" : "http"
        origin.host = host
        origin.port = port
        guard let url = origin.url else { return .failure(.invalidURL) }
        return build(origin: url, token: value("token", "t"), name: name)
    }

    private static func parseWebURL(_ raw: String, name: String?) -> Result<PairingPayload, PairingLinkError> {
        guard let comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failure(.invalidURL)
        }
        guard let host = comps.host, !host.isEmpty else { return .failure(.missingHost) }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = comps.port
        guard let url = origin.url else { return .failure(.invalidURL) }
        let token = comps.queryItems?.first(where: { $0.name == "token" })?.value
        return build(origin: url, token: token, name: name)
    }

    private static func parseBareAddress(_ raw: String) -> Result<PairingPayload, PairingLinkError> {
        guard !raw.contains(" "), !raw.contains("/") else { return .failure(.invalidURL) }
        let looksLocal = isLocalHostname(raw.split(separator: ":").first.map(String.init) ?? raw)
        let scheme = looksLocal ? "http" : "https"
        let withPort = raw.contains(":") ? raw : "\(raw):\(defaultPort)"
        return parseWebURL("\(scheme)://\(withPort)", name: nil)
    }

    private static func build(origin: URL, token: String?, name: String?) -> Result<PairingPayload, PairingLinkError> {
        let cleanedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(PairingPayload(
            name: (name?.isEmpty == false ? name! : defaultName(for: origin)),
            origin: origin,
            launchToken: (cleanedToken?.isEmpty == false) ? cleanedToken : nil
        ))
    }

    // MARK: - Helpers

    /// A friendly label: "This Mac" for loopback, the first DNS label for a
    /// Tailscale name, otherwise the hostname.
    public static func defaultName(for origin: URL) -> String {
        let host = (origin.host ?? "").lowercased()
        if host == "127.0.0.1" || host == "localhost" || host == "::1" { return "This Mac" }
        if host.hasSuffix(".ts.net"), let first = host.split(separator: ".").first {
            return String(first)
        }
        return host
    }

    static func isLocalHostname(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
