import Foundation

/// Minimal client for the Mac chat bridge (`POST /clutch/v1/chat`, SSE).
/// The CometChat message list is the display source of truth; this stream
/// drives the sending state, the thought line, and turn completion.
public enum ChatStreamEvent: Equatable {
    case started(sessionId: String, engine: String)
    case message(String)
    case thought(String)
    case done(stopReason: String, sessionId: String, remoteSessionId: String?)
    case failed(String)
}

public struct ChatSessionClient {
    public var host: ClutchHost
    public var model: String
    public var sessionId: String?
    public var relayReceiverUid: String
    /// Engine override (`mcode` for MiniMax Code remote). Nil routes by
    /// model on the sidecar, preserving the DeepSeek/MiniMax behavior.
    public var engine: String?

    public init(host: ClutchHost, model: String, sessionId: String? = nil, relayReceiverUid: String, engine: String? = nil) {
        self.host = host
        self.model = model
        self.sessionId = sessionId
        self.relayReceiverUid = relayReceiverUid
        self.engine = engine
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
                    ]
                    if let sessionId { body["sessionId"] = sessionId }
                    if let engine { body["engine"] = engine }
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
        case "done":
            return .done(
                stopReason: (json["stopReason"] as? String) ?? "",
                sessionId: (json["sessionId"] as? String) ?? "",
                remoteSessionId: json["remoteSessionId"] as? String
            )
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
