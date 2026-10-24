import Foundation

/// Reads the host's engine catalog (`GET /clutch/v1/engines`).
///
/// The catalog says which engines the host can run, which models each one
/// offers right now, and which reasoning-effort levels it accepts.  The
/// apps use it to build the model and effort pickers, so a provider that
/// ships a new model shows up without an app release.
public struct EngineCatalogClient {
    public var host: ClutchHost

    public init(host: ClutchHost) {
        self.host = host
    }

    public func fetch() async throws -> EngineCatalog {
        guard let token = host.chatToken, !token.isEmpty else { throw ChatClientError.missingToken }
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        comps.path = "/clutch/v1/engines"
        guard let url = comps.url else { throw ChatClientError.badHost }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(EngineCatalog.self, from: data)
    }
}
