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

    public static func probe(_ host: ClutchHost, timeout: TimeInterval = 5) async -> HostStatus {
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
}
