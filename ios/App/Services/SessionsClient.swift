import Foundation

/// Client for the sidecar's session endpoints (see
/// `src/web/chat-bridge.ts`).  Same chat-token gate as the send path; the
/// token never leaves the device.
///
/// Every engine is discoverable: the code engines through their own ACP
/// bridge, and the dsh-hosted engines (DeepSeek, MiniMax) through the dsh
/// host that owns their session log.  The sidecar answers both with the same
/// shape, so the client does not branch on the engine.
public struct SessionsClient {
    public var host: ClutchHost

    public init(host: ClutchHost) {
        self.host = host
    }

    /// Session failures retain the sidecar's bounded, user-facing reason.
    static func loadFailure(status: Int, data: Data) -> Error {
        struct Payload: Decodable { var error: String }
        guard status == 409 || status == 502,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ChatClientError.http(status)
        }
        return SessionLoadFailure(message: String(payload.error.prefix(2048)))
    }

    private func authorized(_ url: URL, timeout: TimeInterval = 90) throws -> URLRequest {
        guard let token = host.chatToken, !token.isEmpty else { throw ChatClientError.missingToken }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Session discovery and full-history replay cross process spawns on a
        // loaded Mac; the old 30s budget timed out routinely.
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

    /// Sidecar health: reachable, token accepted, and whether this host can
    /// actually run MiniMax Code (`mcode` installed and signed in there).
    public func health() async throws -> Health {
        var comps = try base()
        comps.path = "/clutch/v1/health"
        guard let url = comps.url else { throw ChatClientError.badHost }
        let (data, resp) = try await URLSession.shared.data(for: authorized(url, timeout: 15))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Payload: Decodable {
            var ok: Bool
            var mcode: Mcode?
            struct Mcode: Decodable { var available: Bool }
        }
        let payload = try? JSONDecoder().decode(Payload.self, from: data)
        return Health(ok: payload?.ok ?? true, mcodeAvailable: payload?.mcode?.available ?? true)
    }

    public struct Health: Equatable, Sendable {
        public var ok: Bool
        public var mcodeAvailable: Bool

        public init(ok: Bool, mcodeAvailable: Bool) {
            self.ok = ok
            self.mcodeAvailable = mcodeAvailable
        }
    }

    public func list(engine: String = "mcode", limit: Int = 100, includingArchived: Bool = false) async throws -> [AcpSessionInfo] {
        var comps = try base()
        comps.path = "/clutch/v1/sessions"
        var items = [
            URLQueryItem(name: "engine", value: engine),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if includingArchived { items.append(URLQueryItem(name: "archived", value: "include")) }
        comps.queryItems = items
        guard let url = comps.url else { throw ChatClientError.badHost }
        let (data, resp) = try await URLSession.shared.data(for: authorized(url))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Payload: Decodable { var sessions: [AcpSessionInfo] }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.sessions ?? []
    }

    // MARK: - Projects and archiving
    //
    // The engine has no concept of either, so this is Clutch-side metadata that
    // the sidecar owns in `$CLUTCH_HOME/session-meta.json`, keyed by engine
    // session id.  Archiving hides a thread from the default list and is fully
    // reversible; nothing the engine owns is moved or deleted.

    public struct Project: Decodable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var createdAt: String?
        public init(id: String, name: String, createdAt: String? = nil) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
        }
    }

    /// A session's stored Project assignment and archive state.
    public struct SessionMetaEntry: Decodable, Equatable, Sendable {
        public var projectId: String?
        public var archived: Bool?
        public var archivedAt: String?
        public init(projectId: String? = nil, archived: Bool? = nil, archivedAt: String? = nil) {
            self.projectId = projectId
            self.archived = archived
            self.archivedAt = archivedAt
        }
    }

    public struct SessionMeta: Decodable, Equatable, Sendable {
        public var projects: [Project]
        public var sessions: [String: SessionMetaEntry]
        public init(projects: [Project] = [], sessions: [String: SessionMetaEntry] = [:]) {
            self.projects = projects
            self.sessions = sessions
        }
    }

    public func meta() async throws -> SessionMeta {
        var comps = try base()
        comps.path = "/clutch/v1/session-meta"
        guard let url = comps.url else { throw ChatClientError.badHost }
        let (data, resp) = try await URLSession.shared.data(for: authorized(url))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return (try? JSONDecoder().decode(SessionMeta.self, from: data)) ?? SessionMeta()
    }

    /// Assign, unassign (`projectId: nil`), archive or unarchive one session.
    /// Returns the fresh metadata so the caller can redraw without a refetch.
    @discardableResult
    public func updateMeta(
        sessionId: String,
        projectId: String?? = nil,
        archived: Bool? = nil
    ) async throws -> SessionMeta {
        var comps = try base()
        comps.path = "/clutch/v1/session-meta"
        guard let url = comps.url else { throw ChatClientError.badHost }
        var req = try authorized(url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `projectId` is doubly optional so "leave it alone" and "clear it" are
        // distinguishable:  the outer nil omits the key, the inner nil sends null.
        var body: [String: Any] = ["sessionId": sessionId]
        if let projectId { body["projectId"] = projectId as Any? ?? NSNull() }
        if let archived { body["archived"] = archived }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Payload: Decodable {
            var projects: [Project]
            var sessions: [String: SessionMetaEntry]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ChatClientError.http(200)
        }
        return SessionMeta(projects: payload.projects, sessions: payload.sessions)
    }

    /// Create a Project, or return the existing one when the name already
    /// exists — the sidecar matches case-insensitively and reports `created`.
    @discardableResult
    public func createProject(name: String) async throws -> (project: Project, created: Bool) {
        var comps = try base()
        comps.path = "/clutch/v1/projects"
        guard let url = comps.url else { throw ChatClientError.badHost }
        var req = try authorized(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 || status == 201 else {
            throw ChatClientError.http(status)
        }
        struct Payload: Decodable { var project: Project; var created: Bool }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ChatClientError.http(200)
        }
        return (payload.project, payload.created)
    }

    /// `cwd` is effectively required: the sidecar falls back to `$HOME` when it
    /// is absent, and the ACP bridge then refuses any thread whose persisted
    /// workspace is elsewhere ("Requested cwd does not match the persisted
    /// session workspace").  Always pass the cwd the session was listed with,
    /// or every thread outside `$HOME` fails to resume.
    @discardableResult
    public func load(
        sessionId: String,
        cwd: String? = nil,
        engine: String = "mcode",
        model: String? = nil,
        effort: String? = nil,
        limit: Int = 200
    ) async throws -> LoadedSession {
        var comps = try base()
        comps.path = "/clutch/v1/sessions/load"
        guard let url = comps.url else { throw ChatClientError.badHost }
        var req = try authorized(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["engine": engine, "sessionId": sessionId, "limit": limit]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        if let model, !model.isEmpty { body["model"] = model }
        if let effort, !effort.isEmpty { body["effort"] = effort }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Self.loadFailure(status: (resp as? HTTPURLResponse)?.statusCode ?? -1, data: data)
        }
        struct Payload: Decodable {
            var sessionId: String
            var remoteSessionId: String?
            var cwd: String?
            var history: [AcpHistoryEntry]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ChatClientError.http(200)
        }
        // The sidecar does not echo cwd back, so keep the one we asked for:
        // the pull-to-refresh path needs it to resume this same thread again.
        return LoadedSession(
            chatId: payload.sessionId,
            remoteSessionId: payload.remoteSessionId ?? sessionId,
            cwd: payload.cwd ?? cwd,
            history: payload.history ?? []
        )
    }

    /// What `load` hands back: a fresh sidecar chat id plus the replayed
    /// transcript.  `remoteSessionId` is the durable ACP id, which is the only
    /// thing that survives a sidecar restart.
    public struct LoadedSession {
        public var chatId: String
        public var remoteSessionId: String
        public var cwd: String?
        public var history: [AcpHistoryEntry]

        public init(chatId: String, remoteSessionId: String, cwd: String?, history: [AcpHistoryEntry]) {
            self.chatId = chatId
            self.remoteSessionId = remoteSessionId
            self.cwd = cwd
            self.history = history
        }
    }
}

private struct SessionLoadFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
