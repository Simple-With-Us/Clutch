import Foundation

/// Minimal client for the Mac chat bridge (`POST /clutch/v1/chat`, SSE).
/// The CometChat message list is the display source of truth; this stream
/// drives the sending state, the thought line, and turn completion.
public enum ChatStreamEvent: Equatable {
    case started(sessionId: String, engine: String)
    case message(String)
    case thought(String)
    /// One tool call the agent ran, or a status update to one already shown.
    case tool(id: String, name: String, status: String)
    case done(stopReason: String, sessionId: String, remoteSessionId: String?)
    case usage(AcpSessionUsage)
    /// The engine is waiting for a permission request to be answered.
    case permission(AcpPermissionRequest)
    /// The engine's execution plan, as it last reported it.
    case plan([AcpPlanEntry])
    case failed(String)
}

public struct ChatSessionClient {
    public var host: ClutchHost
    public var model: String
    public var sessionId: String?
    public var relayReceiverUid: String
    /// Engine override (`mcode` for MiniMax Code remote, `muse` for Muse
    /// Code). Nil routes by model on the sidecar, preserving the
    /// DeepSeek/MiniMax behavior.
    public var engine: String?
    /// Working directory for a turn that creates a session.  The sidecar
    /// defaults a missing cwd to `$HOME`, and MiniMax Code then refuses to
    /// resume the thread from anywhere else — so the Mac sidebar's chosen
    /// folder has to ride along on the first turn.
    public var cwd: String?
    /// Reasoning effort for this turn.  The sidecar maps it onto whatever
    /// the engine calls its effort option.
    public var effort: String?
    /// Images attached to this turn, the way the web canvas attaches files.
    public var images: [ChatAttachment]

    public init(
        host: ClutchHost,
        model: String,
        sessionId: String? = nil,
        relayReceiverUid: String,
        engine: String? = nil,
        cwd: String? = nil,
        effort: String? = nil,
        images: [ChatAttachment] = []
    ) {
        self.host = host
        self.model = model
        self.sessionId = sessionId
        self.relayReceiverUid = relayReceiverUid
        self.engine = engine
        self.cwd = cwd
        self.effort = effort
        self.images = images
    }

    public func chatURL() -> URL? {
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        comps.path = "/clutch/v1/chat"
        return comps.url
    }

    /// Streams one turn. Throws on transport failure; server-side turn
    /// problems arrive as `.failed` instead.
    public func stream(prompt: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let url = chatURL() else { throw ChatClientError.badHost }
                    guard let token = host.chatToken, !token.isEmpty else { throw ChatClientError.missingToken }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 600
                    var body: [String: Any] = [
                        "prompt": prompt,
                        "model": model,
                        "relay": ["receiver": relayReceiverUid, "receiverType": "user"],
                        // The sidecar holds a permission request until the
                        // answer comes back, so the engine asks this client
                        // rather than answering for itself.
                        "permissions": "ask",
                    ]
                    if let sessionId { body["sessionId"] = sessionId }
                    if let engine { body["engine"] = engine }
                    if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
                    if let effort, !effort.isEmpty { body["effort"] = effort }
                    if !images.isEmpty {
                        body["images"] = images.map { image in
                            [
                                "mimeType": image.mimeType,
                                "data": image.data,
                                "name": image.name,
                            ]
                        }
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
                    }
                    var event = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if let ev = ChatSessionClient.decode(event: event, payload: payload) {
                                continuation.yield(ev)
                            }
                            event = ""
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Stop one in-flight turn without dropping the stream first
    /// (`POST /clutch/v1/chat/cancel`).  Best effort: the stream's own close
    /// handler on the sidecar cancels again, so a failed call here still
    /// ends with the local task cancelled by the caller.
    public static func cancel(host: ClutchHost, sessionId: String) async {
        guard let token = host.chatToken, !token.isEmpty else { return }
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        comps.path = "/clutch/v1/chat/cancel"
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId])
        req.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Answer a permission request the engine is waiting on
    /// (`POST /clutch/v1/permissions`).
    ///
    /// The option id is the one the engine offered.  A nil option cancels the
    /// request, which is what a "deny" answer amounts to when the engine
    /// offered no reject option of its own.
    @discardableResult
    public static func answerPermission(
        host: ClutchHost,
        sessionId: String,
        requestId: String,
        optionId: String?
    ) async -> Bool {
        guard let token = host.chatToken, !token.isEmpty else { return false }
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        comps.path = "/clutch/v1/permissions"
        guard let url = comps.url else { return false }
        var payload: [String: Any] = ["sessionId": sessionId, "requestId": requestId]
        if let optionId { payload["optionId"] = optionId }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    static func decode(event: String, payload: String) -> ChatStreamEvent? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch event {
        case "start":
            guard let id = json["sessionId"] as? String else { return nil }
            return .started(sessionId: id, engine: (json["engine"] as? String) ?? "")
        case "message":
            guard let text = json["text"] as? String else { return nil }
            return .message(text)
        case "thought":
            guard let text = json["text"] as? String else { return nil }
            return .thought(text)
        case "tool":
            return .tool(
                id: (json["id"] as? String) ?? "",
                name: (json["name"] as? String) ?? "Tool call",
                status: (json["status"] as? String) ?? "running"
            )
        case "done":
            return .done(
                stopReason: (json["stopReason"] as? String) ?? "",
                sessionId: (json["sessionId"] as? String) ?? "",
                remoteSessionId: json["remoteSessionId"] as? String
            )
        case "usage":
            // The sidecar pushes the engine's own accounting record as it
            // writes it; without this case the event was dropped and the
            // usage strip never left "not reported".
            guard let usageDict = json["usage"] as? [String: Any],
                  let usageData = try? JSONSerialization.data(withJSONObject: usageDict),
                  let usage = try? JSONDecoder().decode(AcpSessionUsage.self, from: usageData) else { return nil }
            return .usage(usage)
        case "permission":
            // The engine is blocked on this request until the answer goes
            // back, so it is carried with the turn rather than dropped.
            guard let requestDict = json as? [String: Any] else { return nil }
            guard let requestData = try? JSONSerialization.data(withJSONObject: requestDict),
                  let request = try? JSONDecoder().decode(AcpPermissionRequest.self, from: requestData) else { return nil }
            return .permission(request)
        case "plan":
            // The plan is a state rather than a line of the transcript: the
            // client shows the list the engine last reported.
            guard let entries = json["entries"] as? [[String: Any]] else { return nil }
            let plan = entries.compactMap { entry -> AcpPlanEntry? in
                guard let content = entry["content"] as? String else { return nil }
                return AcpPlanEntry(
                    content: content,
                    priority: (entry["priority"] as? String) ?? "medium",
                    status: (entry["status"] as? String) ?? "pending"
                )
            }
            return .plan(plan)
        case "error":
            return .failed((json["message"] as? String) ?? "unknown error")
        default:
            return nil
        }
    }
}

public enum ChatClientError: Error, LocalizedError {
    case badHost
    case missingToken
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .badHost:
            return "This host has no usable chat address."
        case .missingToken:
            return "Pair again to enable native chat."
        case .http(let code):
            return "Chat bridge answered \(code)."
        }
    }
}
