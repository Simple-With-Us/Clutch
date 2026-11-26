import Foundation

/// One reminder from the host's schedule projection, as `GET
/// /clutch/v1/crons` carries it.  Delivery is session-local by upstream
/// design: the reminder fires in the thread that owns it, so the row
/// names that thread's session alongside the reminder itself.
public struct CronItem: Decodable, Equatable, Identifiable, Sendable {
    /// The schedule id, unique only within its owning session.
    public var cronId: String
    /// The list identity: schedule ids repeat across sessions, so a row
    /// is its session and its schedule id together.
    public var id: String { "\(sessionId)|\(cronId)" }
    public var sessionId: String
    public var kind: String
    public var prompt: String
    public var scheduledAt: String
    public var afterSeconds: Int?
    public var everySeconds: Int?
    public var state: String
    public var deliveryMode: String

    private enum CodingKeys: String, CodingKey {
        case cronId = "id"
        case sessionId, kind, prompt, scheduledAt, afterSeconds, everySeconds, state, deliveryMode
    }

    public init(
        id: String,
        sessionId: String,
        kind: String,
        prompt: String,
        scheduledAt: String,
        afterSeconds: Int? = nil,
        everySeconds: Int? = nil,
        state: String,
        deliveryMode: String = "session-local"
    ) {
        self.cronId = id
        self.sessionId = sessionId
        self.kind = kind
        self.prompt = prompt
        self.scheduledAt = scheduledAt
        self.afterSeconds = afterSeconds
        self.everySeconds = everySeconds
        self.state = state
        self.deliveryMode = deliveryMode
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter = ISO8601DateFormatter()

    private static let ruleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// When this reminder next fires, when the host named a real instant.
    public var scheduledDate: Date? {
        Self.fractionalFormatter.date(from: scheduledAt) ?? Self.plainFormatter.date(from: scheduledAt)
    }

    /// The rule in the owner's words: "in 10 min", "daily at 9:00 AM",
    /// or "every 1 hr" for the fixed-rate kind.
    public var ruleLabel: String {
        switch kind {
        case "after":
            guard let afterSeconds else { return "One time" }
            return "In \(Self.duration(afterSeconds))"
        case "every":
            guard let everySeconds else { return "Repeating" }
            return "Every \(Self.duration(everySeconds))"
        default:
            guard let scheduledDate else { return "One time" }
            return Self.ruleDateFormatter.string(from: scheduledDate)
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return "\(seconds / 3600) hr" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) sec"
    }
}

/// The list answer of `GET /clutch/v1/crons`.
public struct CronList: Decodable, Equatable, Sendable {
    public var crons: [CronItem]

    public init(crons: [CronItem]) {
        self.crons = crons
    }
}

/// The create answer of `POST /clutch/v1/crons`.
public struct CronCreated: Decodable, Equatable, Sendable {
    public var cron: CronItem

    public init(cron: CronItem) {
        self.cron = cron
    }
}
