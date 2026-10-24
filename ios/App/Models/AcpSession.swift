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

    /// Case-insensitive filter over title, working directory, and session
    /// id — the three things a person actually remembers about a thread.
    /// An empty query keeps the list untouched.
    public static func filtered(_ sessions: [AcpSessionInfo], query: String) -> [AcpSessionInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sessions }
        return sessions.filter { session in
            [session.title ?? "", session.cwd ?? "", session.sessionId]
                .joined(separator: " ")
                .lowercased()
                .contains(needle)
        }
    }

    /// One date bucket of threads for a grouped sidebar.
    public struct Group: Identifiable, Equatable, Sendable {
        public var title: String
        public var sessions: [AcpSessionInfo]
        public var id: String { title }

        public init(title: String, sessions: [AcpSessionInfo]) {
            self.title = title
            self.sessions = sessions
        }
    }

    /// Date groups with a Pinned group floated above them.  Pins are a
    /// local, per-host reading aid (see `ThreadPinStore`); a pinned thread
    /// appears once, in Pinned, not again in its date bucket.
    public static func grouped(_ sessions: [AcpSessionInfo], pinned: Set<String>, now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        guard !pinned.isEmpty else { return grouped(sessions, now: now, calendar: calendar) }
        let pinnedRows = newestFirst(sessions.filter { pinned.contains($0.sessionId) })
        let rest = sessions.filter { !pinned.contains($0.sessionId) }
        guard !pinnedRows.isEmpty else { return grouped(sessions, now: now, calendar: calendar) }
        return [Group(title: "Pinned", sessions: pinnedRows)] + grouped(rest, now: now, calendar: calendar)
    }

    /// Newest-first sessions bucketed as Today / Yesterday / Previous 7 Days
    /// / Older / Undated, empty buckets dropped.  Undated threads go last:
    /// they still work, they just cannot claim a place in the timeline.
    public static func grouped(_ sessions: [AcpSessionInfo], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let ordered = newestFirst(sessions)
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfYesterday
        var buckets: [(String, [AcpSessionInfo])] = [
            ("Today", []), ("Yesterday", []), ("Previous 7 Days", []), ("Older", []), ("Undated", []),
        ]
        for session in ordered {
            guard let date = session.updated else {
                buckets[4].1.append(session)
                continue
            }
            if date >= startOfToday { buckets[0].1.append(session) }
            else if date >= startOfYesterday { buckets[1].1.append(session) }
            else if date >= startOfWeek { buckets[2].1.append(session) }
            else { buckets[3].1.append(session) }
        }
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, sessions: $0.1) }
    }
}

/// One replayed update from `POST /clutch/v1/sessions/load`.
public struct AcpHistoryEntry: Decodable, Equatable, Sendable {
    public var sessionId: String
    public var kind: String
    public var text: String
    /// Present on tool-call entries (`tool_call`, `tool_call_update`).
    public var toolCallId: String?
    public var toolStatus: String?

    public init(sessionId: String, kind: String, text: String, toolCallId: String? = nil, toolStatus: String? = nil) {
        self.sessionId = sessionId
        self.kind = kind
        self.text = text
        self.toolCallId = toolCallId
        self.toolStatus = toolStatus
    }

    public var isTool: Bool { kind == "tool_call" || kind == "tool_call_update" }

    /// Sidecar kinds that are user- or assistant-visible; tool chatter and
    /// progress notices are dropped so the transcript stays readable.  The
    /// chunk spellings are the ones the sidecar actually replays
    /// (`agent_message_chunk` / `user_message_chunk` from ACP
    /// `session/update`); the short spellings stay for older replays.
    public var isVisible: Bool {
        switch kind {
        case "user_message_chunk", "agent_message_chunk",
             "user_message", "assistant_message", "user", "assistant", "message", "text": true
        default: false
        }
    }

    public var isUser: Bool {
        switch kind {
        case "user_message_chunk", "user_message", "user": true
        default: false
        }
    }
}
