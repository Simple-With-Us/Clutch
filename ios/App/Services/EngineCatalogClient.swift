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

    public func fetch(engine: String? = nil) async throws -> EngineCatalog {
        guard let token = host.chatToken, !token.isEmpty else { throw ChatClientError.missingToken }
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        comps.path = "/clutch/v1/engines"
        if let engine {
            comps.queryItems = [URLQueryItem(name: "engine", value: engine)]
        }
        guard let url = comps.url else { throw ChatClientError.badHost }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let catalog = try JSONDecoder().decode(EngineCatalog.self, from: data)
        // The catalog this host published is kept, so a later failed read
        // does not empty the pickers.
        await EngineCatalogMemory.shared.remember(catalog, for: host.id.uuidString)
        return catalog
    }

    /// The catalog this host published last, when it published one.
    public func lastKnownCatalog() async -> EngineCatalog? {
        await EngineCatalogMemory.shared.catalog(for: host.id.uuidString)
    }
}

/// The last catalog each host published, kept in memory.
///
/// A failed read must not make the chat unusable: the choices the host
/// published last stay on screen, and the built-in models stand in only
/// when there never were any.  The catalogs are small and per host, so
/// they are kept for the life of the app.
public actor EngineCatalogMemory {
    public static let shared = EngineCatalogMemory()

    private var catalogs: [String: EngineCatalog] = [:]

    /// Remember the catalog a host published.
    public func remember(_ catalog: EngineCatalog, for hostKey: String) {
        catalogs[hostKey] = catalog
    }

    /// The catalog a host published last, when it published one.
    public func catalog(for hostKey: String) -> EngineCatalog? {
        catalogs[hostKey]
    }
}
