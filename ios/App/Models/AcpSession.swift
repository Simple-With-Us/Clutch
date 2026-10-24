import Foundation

/// Real token accounting for one session, as reported by the engine.
///
/// Every field is optional because the sidecar omits what it could not read.
/// The rule this type exists to enforce:  a missing value is shown as "not
/// reported", never replaced by an estimate.  Nothing here derives tokens from
/// a character count, because a `characters / 4` figure is wrong often enough
/// to mislead a user deciding whether to start a fresh thread.
public struct AcpSessionUsage: Decodable, Equatable, Sendable {
    public var provider: String?
    public var model: String?
    /// The model's total context window, as the engine reported it.
    public var contextWindow: Int?
    public var inputTokens: Int
    public var outputTokens: Int
    /// Context occupancy:  the engine reports input + cacheRead + output here.
    public var totalTokens: Int
    public var cacheReadTokens: Int?
    /// Output tokens per second, measured between two real engine records.
    public var outputTokensPerSecond: Double?

    public init(
        provider: String? = nil,
        model: String? = nil,
        contextWindow: Int? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        cacheReadTokens: Int? = nil,
        outputTokensPerSecond: Double? = nil
    ) {
        self.provider = provider
        self.model = model
        self.contextWindow = contextWindow
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokensPerSecond = outputTokensPerSecond
    }

    /// Occupancy as a percentage of the window, or nil when either half is
    /// unknown.  A zero or missing window yields nil rather than infinity.
    public var contextUsedPercent: Double? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        return (Double(totalTokens) / Double(contextWindow)) * 100
    }

    /// `152.1k`, `1.04M`, or the raw number under a thousand.
    public static func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }

    /// `61% · 610k / 1M`, or nil when the engine reported neither half.
    public var occupancyLabel: String? {
        guard contextWindow != nil || totalTokens > 0 else { return nil }
        guard let percent = contextUsedPercent, let contextWindow else { return nil }
        return String(
            format: "%.0f%% · %@ / %@",
            percent,
            Self.compact(totalTokens),
            Self.compact(contextWindow)
        )
    }

    /// `4.2k tok/s`, or nil when the engine has not produced two dated records
    /// yet.  A rate needs two real samples, so it is absent for a fresh thread.
    public var rateLabel: String? {
        guard let rate = outputTokensPerSecond, rate.isFinite, rate >= 0 else { return nil }
        if rate >= 1000 { return String(format: "%.1fk tok/s", rate / 1000) }
        return String(format: "%.0f tok/s", rate)
    }
}

/// One MiniMax Code session from `GET /clutch/v1/sessions`.
///
/// Shared by the Mac chat surface and the iOS dashboard so both read the same
/// wire shape; the sidecar is the only source.
public struct AcpSessionInfo: Decodable, Equatable, Identifiable, Sendable {
    public var sessionId: String
    public var cwd: String?
    public var title: String?
    public var updatedAt: String?
    /// Present only when the sidecar could read the engine's own accounting.
    public var usage: AcpSessionUsage?
    /// Project this session belongs to, set by the sidecar's metadata store.
    public var projectId: String?
    /// True when the user archived it.  Archived threads are hidden, never gone.
    public var archived: Bool?

    public var id: String { sessionId }

    public init(
        sessionId: String,
        cwd: String? = nil,
        title: String? = nil,
        updatedAt: String? = nil,
        usage: AcpSessionUsage? = nil,
        projectId: String? = nil,
        archived: Bool? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.usage = usage
        self.projectId = projectId
        self.archived = archived
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
    /// id — the three things a person actually remembers about a thread —
    /// plus the model, provider, and project the sidecar reported, so a user
    /// can also find a thread by what drives it.  Each field is matched on its
    /// own, so a query never matches across the seam between two of them.  An
    /// empty query keeps the list untouched.
    public static func filtered(_ sessions: [AcpSessionInfo], query: String) -> [AcpSessionInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sessions }
        return sessions.filter { session in
            [
                session.title, session.cwd, session.sessionId,
                session.usage?.model, session.usage?.provider, session.projectId,
            ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(needle) }
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

    public init(sessionId: String, kind: String, text: String) {
        self.sessionId = sessionId
        self.kind = kind
        self.text = text
    }

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
