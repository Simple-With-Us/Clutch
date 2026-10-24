import Foundation

/// Cookie-less health probe of a clutch web origin.
///
/// clutch web (`dsh web`) auth-walls `/`: without its signed cookie it
/// answers `401` with a fixed plain-text body.  That wall is the most reliable
/// fingerprint available without credentials, so an ephemeral session (no
/// shared cookies) is used on purpose.
public enum HostProbe {
    static let authWallMarker = "dsh web authentication required"

    public static func classify(statusCode: Int, body: String) -> HostStatus {
        if statusCode == 401 && body.localizedCaseInsensitiveContains(authWallMarker) {
            return .online
        }
        if statusCode > 0 {
            return .notClutch
        }
        return .offline
    }

    /// A MiniMax Code server host has no web origin to fingerprint; its
    /// sidecar health route answers 200 with a token and 401 without one,
    /// and either answer proves the sidecar is the thing listening.
    public static func classifyMiniMaxCode(statusCode: Int) -> HostStatus {
        if statusCode == 200 || statusCode == 401 {
            return .online
        }
        if statusCode > 0 {
            return .notClutch
        }
        return .offline
    }

    public static func probe(_ host: ClutchHost, timeout: TimeInterval = 5) async -> HostStatus {
        if host.isMiniMaxCodeOnly {
            return await probeMiniMaxCode(host, timeout: timeout)
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: host.rootURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data.prefix(512), as: UTF8.self)
            return classify(statusCode: code, body: body)
        } catch {
            return .offline
        }
    }

    private static func probeMiniMaxCode(_ host: ClutchHost, timeout: TimeInterval) async -> HostStatus {
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        comps.path = "/clutch/v1/health"
        guard let url = comps.url else { return .offline }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.data(for: request)
            return classifyMiniMaxCode(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .offline
        }
    }
}
