import Foundation

/// One MiniMax Code session from `GET /clutch/v1/sessions`.
///
/// Shared by the Mac chat surface and the iOS dashboard so both read the same
/// wire shape; the sidecar is the only source.
public struct AcpSessionInfo: Decodable, Equatable, Identifiable, Sendable {
    public var sessionId: String
    public var cwd: String?
    public var title: String?
    public var updatedAt: String?

    public var id: String { sessionId }

    public init(sessionId: String, cwd: String? = nil, title: String? = nil, updatedAt: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
    }

    /// What the row shows when the session has no usable title.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        if let cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return "Untitled Session"
    }

    /// The sidecar sends ISO-8601 with milliseconds and a `Z` suffix; tolerate
    /// the plain form too so a thread without them still sorts sensibly.
    public static func updatedDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    public var updated: Date? { Self.updatedDate(updatedAt) }
}

/// One replayed update from `POST /clutch/v1/sessions/load`.
public struct AcpHistoryEntry: Decodable, Equatable, Sendable {
    public var sessionId: String
    public var kind: String
    public var text: String

    public init(sessionId: String, kind: String, text: String) {
        self.sessionId = sessionId
        self.kind = kind
        self.text = text
    }

    /// Sidecar kinds that are user- or assistant-visible; tool chatter and
    /// progress notices are dropped so the transcript stays readable.
    public var isVisible: Bool {
        switch kind {
        case "user_message", "assistant_message", "user", "assistant", "message", "text": true
        default: false
        }
    }

    public var isUser: Bool {
        switch kind {
        case "user_message", "user": true
        default: false
        }
    }
}
