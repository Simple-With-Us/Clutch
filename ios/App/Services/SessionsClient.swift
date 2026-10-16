import Foundation

/// Client for the sidecar's MiniMax Code session endpoints (see
/// `src/web/chat-bridge.ts`).  Same chat-token gate as the send path; the
/// token never leaves the device.
///
/// Only `mcode` is discoverable today: the sidecar answers
/// `GET /clutch/v1/sessions` with a 400 for any other engine, because the
/// DeepSeek and MiniMax bridges keep no resumable session list of their own.
public struct SessionsClient {
    public var host: ClutchHost

    public init(host: ClutchHost) {
        self.host = host
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

    public func list(limit: Int = 100) async throws -> [AcpSessionInfo] {
        var comps = try base()
        comps.path = "/clutch/v1/sessions"
        comps.queryItems = [
            URLQueryItem(name: "engine", value: "mcode"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = comps.url else { throw ChatClientError.badHost }
        let (data, resp) = try await URLSession.shared.data(for: authorized(url))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Payload: Decodable { var sessions: [AcpSessionInfo] }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.sessions ?? []
    }

    /// `cwd` is effectively required: the sidecar falls back to `$HOME` when it
    /// is absent, and the ACP bridge then refuses any thread whose persisted
    /// workspace is elsewhere ("Requested cwd does not match the persisted
    /// session workspace").  Always pass the cwd the session was listed with,
    /// or every thread outside `$HOME` fails to resume.
    @discardableResult
    public func load(sessionId: String, cwd: String? = nil, limit: Int = 200) async throws -> LoadedSession {
        var comps = try base()
        comps.path = "/clutch/v1/sessions/load"
        guard let url = comps.url else { throw ChatClientError.badHost }
        var req = try authorized(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["engine": "mcode", "sessionId": sessionId, "limit": limit]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
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
