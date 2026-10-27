import Foundation

/// One entry in the engine's execution plan.
///
/// The engine reports the whole plan every time it changes, so a client
/// shows the list it was given rather than patching the one it had.
public struct AcpPlanEntry: Decodable, Equatable, Sendable, Identifiable {
    /// What the entry says, as the engine wrote it.
    public var content: String
    /// The engine's priority for the entry.
    public var priority: String
    /// Where the entry stands.
    public var status: String

    public var id: String { "\(status)-\(content)" }

    public init(content: String, priority: String = "medium", status: String = "pending") {
        self.content = content
        self.priority = priority
        self.status = status
    }

    /// True when the entry is the one the engine is working on.
    public var isActive: Bool { status == "in_progress" }
    /// True when the entry is finished.
    public var isDone: Bool { status == "completed" }
}

/// One option the engine offers for a permission request.
public struct AcpPermissionOption: Decodable, Equatable, Sendable, Identifiable {
    /// The id the sidecar answers with.
    public var optionId: String
    /// The engine's kind for the option: `allow_once`, `allow_always`,
    /// `reject_once`, `reject_always`.
    public var kind: String
    /// The engine's own name for the option.
    public var name: String

    public var id: String { optionId }

    public init(optionId: String, kind: String, name: String) {
        self.optionId = optionId
        self.kind = kind
        self.name = name
    }

    /// True when the option lets the tool run.
    public var allows: Bool {
        kind == "allow_once" || kind == "allow_always"
    }
}

/// A permission request the engine is waiting on.
///
/// The engine blocks until the request is answered, so the request travels
/// with the turn and the answer goes back the same way.
public struct AcpPermissionRequest: Decodable, Equatable, Sendable, Identifiable {
    /// The id the sidecar answers with.
    public var requestId: String
    /// What the tool wants to do, as the engine described it.
    public var title: String
    /// The tool that wants the permission.
    public var toolName: String
    /// The options the engine offers.
    public var options: [AcpPermissionOption]

    public var id: String { requestId }

    public init(requestId: String, title: String, toolName: String, options: [AcpPermissionOption]) {
        self.requestId = requestId
        self.title = title
        self.toolName = toolName
        self.options = options
    }

    /// The heading the card shows: what the tool wants, and which tool it is.
    public var headline: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let tool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        return tool.isEmpty ? "The engine is asking for permission" : tool
    }
}

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

/// One session from `GET /clutch/v1/sessions`.
///
/// Shared by the Mac chat surface and the iOS dashboard so both read the same
/// wire shape; the sidecar is the only source, and it answers every engine
/// with this shape.
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
    /// Present on a `plan` entry: the plan the engine last reported.
    public var plan: [AcpPlanEntry]?

    public init(
        sessionId: String,
        kind: String,
        text: String,
        toolCallId: String? = nil,
        toolStatus: String? = nil,
        plan: [AcpPlanEntry]? = nil
    ) {
        self.sessionId = sessionId
        self.kind = kind
        self.text = text
        self.toolCallId = toolCallId
        self.toolStatus = toolStatus
        self.plan = plan
    }

    public var isTool: Bool { kind == "tool_call" || kind == "tool_call_update" }

    /// True on a `plan` entry, which carries the engine's execution plan
    /// rather than a line of the transcript.
    public var isPlan: Bool { kind == "plan" }

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
