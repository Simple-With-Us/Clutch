import Foundation

public struct RecallHit: Identifiable, Codable, Hashable {
    public var id: String
    /// Nil when the corpus reports no score for a hit.  The UI then shows no
    ///  match percentage at all rather than inventing one.
    public var score: Double?
    public var text: String
    public var source: String
    public var app: String
    public var seat: String
    public var heading: String
    public var title: String
    public var path: String
    public var createdAt: Date?

    public init(
        id: String = UUID().uuidString,
        score: Double? = nil,
        text: String,
        source: String = "doc",
        app: String = "fleet",
        seat: String = "FLEET",
        heading: String = "",
        title: String = "",
        path: String = "",
        createdAt: Date? = nil
    ) {
        self.id = id
        self.score = score
        self.text = text
        self.source = source
        self.app = app
        self.seat = seat
        self.heading = heading
        self.title = title
        self.path = path
        self.createdAt = createdAt
    }
}

/// Corpus counts for the Fleet Recall header.
///
/// Every numeric field starts at zero because nothing populates them yet.  The
/// fleet MCP server exposes `recall_search` and `recall_contribute`, but there is
/// no confirmed stats method on it: the `recall_stats` tool in the fleet preset
/// (`src/presets/fleet-recall/plugins/fleet-recall-tools.mjs`) shells out to a
/// local `recall stats --json` CLI rather than calling the MCP endpoint, so it is
/// not evidence that the server serves stats over JSON-RPC.  Rather than guess at
/// an endpoint name and seed the view with invented numbers, these stay at zero
/// and the view renders "Unavailable".  Fill them in when a real stats method is
/// confirmed server-side.
public struct RecallStats: Codable {
    public var collectionsCount: Int
    public var totalChunks: Int
    public var vectorDimensions: Int
    public var endpoint: String
    public var queryCount24h: Int

    /// True when no live stats call has populated this snapshot.
    public var isPlaceholder: Bool {
        collectionsCount == 0 && totalChunks == 0 && queryCount24h == 0
    }

    public init(
        collectionsCount: Int = 0,
        totalChunks: Int = 0,
        vectorDimensions: Int = 0,
        endpoint: String = "https://agents.jays.services/mcp",
        queryCount24h: Int = 0
    ) {
        self.collectionsCount = collectionsCount
        self.totalChunks = totalChunks
        self.vectorDimensions = vectorDimensions
        self.endpoint = endpoint
        self.queryCount24h = queryCount24h
    }
}

public struct LessonContribution: Codable {
    public var title: String
    public var content: String
    public var category: String
    public var appSlug: String
    public var authorSeat: String

    public init(
        title: String,
        content: String,
        category: String = "lesson",
        appSlug: String = "clutch",
        authorSeat: String = "AG"
    ) {
        self.title = title
        self.content = content
        self.category = category
        self.appSlug = appSlug
        self.authorSeat = authorSeat
    }
}

// MARK: - Contribute

/// The five categories the fleet corpus accepts.  Anything else is rejected
///  client-side, before any request is fired.
public enum RecallCategory: String, CaseIterable, Identifiable, Hashable {
    case lesson
    case preference
    case infrastructure
    case decision
    case runbook

    public var id: String { rawValue }

    /// Title Case label for the picker row.
    public var label: String {
        switch self {
        case .lesson: return "Lesson"
        case .preference: return "Preference"
        case .infrastructure: return "Infrastructure"
        case .decision: return "Decision"
        case .runbook: return "Runbook"
        }
    }
}

/// Everything that can stop a contribution, with a message safe to show a human.
///
/// Server response text is deliberately never folded into these messages: the
///  transport keeps the raw body out of the UI, and each case below is a message
///  Clutch wrote.
public enum RecallContributionError: Error, Equatable, Hashable {
    case invalidCategory
    case textTooShort
    case textTooLong
    case badEndpoint
    case malformedRequest
    case unreachable
    case rejected(statusCode: Int)
    case serverRejected
    case unrecognizedResponse

    /// Sentence case, two spaces between sentences, no server text.
    public var message: String {
        switch self {
        case .invalidCategory:
            return "Pick a category from Lesson, Preference, Infrastructure, Decision, or Runbook."
        case .textTooShort:
            return "Add more detail before submitting.  A lesson needs at least \(RecallContributionDraft.minTextLength) characters."
        case .textTooLong:
            return "Trim the lesson to \(RecallContributionDraft.maxTextLength) characters or fewer."
        case .badEndpoint:
            return "The saved fleet recall endpoint isn't a valid URL."
        case .malformedRequest:
            return "Clutch couldn't build the request for the fleet recall corpus."
        case .unreachable:
            return "Couldn't reach the fleet recall corpus.  Check the connection and try again."
        case .rejected(let statusCode):
            return "The fleet recall corpus rejected the request (HTTP \(statusCode))."
        case .serverRejected:
            return "The fleet recall corpus refused the contribution."
        case .unrecognizedResponse:
            return "The fleet recall corpus replied in a form Clutch didn't understand.  Check that the endpoint is reachable and not behind a sign-in wall."
        }
    }
}

/// What the corpus said about a contribution.
///
/// A duplicate is a success: the lesson is already in the corpus, which is
///  exactly what a re-submit should report back.
public enum RecallContributionOutcome: Equatable, Hashable {
    case stored(docID: String?)
    case duplicate

    public var isSuccess: Bool { true }

    public var confirmationTitle: String {
        switch self {
        case .stored: return "Lesson Contributed"
        case .duplicate: return "Already In The Corpus"
        }
    }

    public var confirmationMessage: String {
        switch self {
        case .stored: return "The lesson is in the fleet recall corpus now."
        case .duplicate: return "An equivalent lesson was already in the fleet recall corpus."
        }
    }
}

/// A contribution the user composed, plus the one place it is validated.
///
/// Validation lives here rather than in the sheet so the same rules apply no
///  matter who calls `contribute`, and so the rules are unit-testable without a
///  network or a view.
public struct RecallContributionDraft: Equatable {
    public static let minTextLength = 40
    public static let maxTextLength = 4_000

    public var title: String
    public var text: String
    public var category: String
    public var app: String
    public var seat: String

    public init(
        title: String = "",
        text: String = "",
        category: String = RecallCategory.lesson.rawValue,
        app: String = "clutch",
        seat: String = "AG"
    ) {
        self.title = title
        self.text = text
        self.category = category
        self.app = app
        self.seat = seat
    }

    public var normalizedCategory: String {
        category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Checks category first, then length.  Order matters: a reader who typed
    ///  both a bad category and a short lesson should be told about the field
    ///  they are most likely looking at.
    public func validate() -> RecallContributionError? {
        guard RecallCategory(rawValue: normalizedCategory) != nil else {
            return .invalidCategory
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= RecallContributionDraft.minTextLength else {
            return .textTooShort
        }
        guard text.count <= RecallContributionDraft.maxTextLength else {
            return .textTooLong
        }
        return nil
    }

    /// Arguments for the `recall_contribute` JSON-RPC tool call.  Blank
    ///  optional fields are omitted so the server applies its own default
    ///  instead of being handed an empty string.
    public var arguments: [String: Any] {
        var args: [String: Any] = [
            "text": text,
            "category": normalizedCategory
        ]
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { args["title"] = trimmedTitle }
        let trimmedApp = app.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedApp.isEmpty { args["app"] = trimmedApp }
        let trimmedSeat = seat.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSeat.isEmpty { args["seat"] = trimmedSeat }
        return args
    }
}

/// Pure mapping from the corpus's JSON to a `RecallContributionOutcome`.
///
/// Kept free of networking so the success / duplicate / unknown-status rules
///  can be tested directly.  A payload with no recognizable status returns nil:
///  an unreadable reply is a failure to report, not a success to assume.
public enum RecallContributionResponse {
    public static let storedStatuses: Set<String> = ["stored", "created", "ok", "success", "added", "indexed"]
    public static let duplicateStatuses: Set<String> = ["duplicate", "already_exists", "exists"]

    public static func outcome(from object: [String: Any]) -> RecallContributionOutcome? {
        guard let rawStatus = object["status"] as? String else { return nil }
        let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if duplicateStatuses.contains(status) { return .duplicate }
        guard storedStatuses.contains(status) else { return nil }
        return .stored(docID: documentID(from: object))
    }

    static func documentID(from object: [String: Any]) -> String? {
        for key in ["id", "doc_id", "docId", "document_id"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? Int { return String(value) }
        }
        return nil
    }
}

// MARK: - Search

/// Turns a `recall_search` payload into hits.
///
/// The fleet corpus is reached through a thin MCP tool whose text block carries
///  the tool's own JSON.  Field names vary across versions (`doc_id` vs `id`,
///  `excerpt` vs `text`), so each field is read from a small set of aliases and
///  a missing score simply stays missing.  An unrecognizable payload yields an
///  empty array, which the caller reports as an error instead of dressing up as
///  results.
public enum RecallSearchResponse {
    public static func hits(from payload: String, app: String) -> [RecallHit] {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        let documents: [[String: Any]]
        if let list = json as? [[String: Any]] {
            documents = list
        } else if let object = json as? [String: Any] {
            documents = documentList(in: object)
        } else {
            return []
        }

        return documents.compactMap { hit(from: $0, fallbackApp: app) }
    }

    private static func documentList(in object: [String: Any]) -> [[String: Any]] {
        for key in ["hits", "results", "matches", "documents", "items"] {
            if let list = object[key] as? [[String: Any]] { return list }
        }
        // A single-document payload still describes one real hit.
        return [object]
    }

    private static func hit(from object: [String: Any], fallbackApp: String) -> RecallHit? {
        let text = string(object, "text", "excerpt", "content", "body", "chunk")
        guard let text, !text.isEmpty else { return nil }
        return RecallHit(
            id: RecallContributionResponse.documentID(from: object) ?? UUID().uuidString,
            score: score(from: object),
            text: text,
            source: string(object, "source", "kind") ?? "doc",
            app: string(object, "app", "app_slug") ?? fallbackApp,
            seat: string(object, "seat", "author") ?? "FLEET",
            heading: string(object, "heading", "section") ?? "",
            title: string(object, "title", "name") ?? "",
            path: string(object, "path", "file", "location") ?? "",
            createdAt: date(from: object)
        )
    }

    private static func score(from object: [String: Any]) -> Double? {
        for key in ["score", "similarity", "relevance"] {
            if let value = object[key] as? Double { return value }
            if let value = object[key] as? Int { return Double(value) }
            if let text = object[key] as? String, let value = Double(text) { return value }
        }
        return nil
    }

    private static func string(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func date(from object: [String: Any]) -> Date? {
        guard let stamp = string(object, "created_at", "createdAt", "date") else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFraction.date(from: stamp) { return parsed }
        return ISO8601DateFormatter().date(from: stamp)
    }
}