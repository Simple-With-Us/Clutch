import Foundation

/// Client for the sidecar's file endpoints (see `src/web/files.ts`).
///
/// The web canvas shows the files of the folder a thread works in, and the
/// native apps ask the sidecar for the same thing.  The sidecar reads the
/// folder, so the answer is the same for every engine and the client never
/// speaks the dsh host's own contract.
public struct FilesClient {
    public var host: ClutchHost

    public init(host: ClutchHost) {
        self.host = host
    }

    /// One entry in a folder.
    public struct Entry: Decodable, Equatable, Identifiable, Sendable {
        public var name: String
        public var path: String
        public var kind: String
        public var size: Int?

        public var id: String { path }
        public var isDirectory: Bool { kind == "directory" }

        public init(name: String, path: String, kind: String, size: Int? = nil) {
            self.name = name
            self.path = path
            self.kind = kind
            self.size = size
        }
    }

    /// One folder, and what is in it.
    public struct Listing: Decodable, Equatable, Sendable {
        public var path: String
        public var parent: String?
        public var entries: [Entry]

        public init(path: String, parent: String? = nil, entries: [Entry] = []) {
            self.path = path
            self.parent = parent
            self.entries = entries
        }
    }

    /// One file, and enough of it to show.
    public struct Preview: Decodable, Equatable, Sendable {
        public var path: String
        public var name: String
        public var kind: String
        public var bytes: Int
        public var truncated: Bool
        public var content: String

        public var isText: Bool { kind == "text" }

        public init(
            path: String,
            name: String,
            kind: String,
            bytes: Int,
            truncated: Bool,
            content: String
        ) {
            self.path = path
            self.name = name
            self.kind = kind
            self.bytes = bytes
            self.truncated = truncated
            self.content = content
        }
    }

    private func authorized(_ url: URL, timeout: TimeInterval = 30) throws -> URLRequest {
        guard let token = host.chatToken, !token.isEmpty else { throw ChatClientError.missingToken }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeout
        return req
    }

    private func base() throws -> URLComponents {
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        guard comps.url != nil else { throw ChatClientError.badHost }
        return comps
    }

    /// The files in one folder of the tree.
    ///
    /// An empty root asks for the folder a new thread would work in, which is
    /// what the sidecar uses when the client does not name one.
    public func list(root: String = "", path: String = "") async throws -> Listing {
        var comps = try base()
        comps.path = "/clutch/v1/files"
        var items: [URLQueryItem] = []
        if !root.isEmpty { items.append(URLQueryItem(name: "root", value: root)) }
        if !path.isEmpty { items.append(URLQueryItem(name: "path", value: path)) }
        comps.queryItems = items
        guard let url = comps.url else { throw ChatClientError.badHost }
        let (data, resp) = try await URLSession.shared.data(for: authorized(url))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(Listing.self, from: data)
    }

    /// One file, far enough to show.
    public func preview(root: String = "", path: String) async throws -> Preview {
        var comps = try base()
        comps.path = "/clutch/v1/file"
        var items: [URLQueryItem] = []
        if !root.isEmpty { items.append(URLQueryItem(name: "root", value: root)) }
        items.append(URLQueryItem(name: "path", value: path))
        comps.queryItems = items
        guard let url = comps.url else { throw ChatClientError.badHost }
        let (data, resp) = try await URLSession.shared.data(for: authorized(url))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(Preview.self, from: data)
    }
}
