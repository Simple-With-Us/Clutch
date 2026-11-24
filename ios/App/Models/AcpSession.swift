import Foundation

private final class AcpSessionDateParser: @unchecked Sendable {
    private let lock = NSLock()
    private let cache = NSCache<NSString, NSDate>()
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()

    init() {
        cache.countLimit = 2048
        cache.totalCostLimit = 128 * 1024
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let key = value as NSString
        // NSCache supports concurrent access, so the common hit path need not
        // wait behind a formatter parse for another timestamp.
        if let cached = cache.object(forKey: key) { return cached as Date }

        lock.lock()
        defer { lock.unlock() }
        if let cached = cache.object(forKey: key) { return cached as Date }
        guard let parsed = fractional.date(from: value) ?? plain.date(from: value) else { return nil }
        cache.setObject(parsed as NSDate, forKey: key, cost: value.utf8.count)
        return parsed
    }
}

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

/// What a permission option does, as far as this build can tell.
///
/// The engine names four kinds and this build knows three of them well:
/// an allow that ends with the turn, an allow that outlives it, and a
/// refusal.  A kind this build has never seen is not a refusal, and the
/// card does not pretend to know more than it does:  the option is shown
/// with a mark that says so, and it waits for the owner like any other
/// grant.
public enum AcpPermissionOptionEffect: Equatable, Sendable {
    /// The tool runs, and the grant ends with the turn.
    case allowOnce
    /// The tool runs, and the grant outlives the turn.
    case allowAlways
    /// The tool does not run.
    case reject
    /// The engine named a kind this build does not know.
    case unknown
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

    /// What the option does, as far as this build can tell.
    public var effect: AcpPermissionOptionEffect {
        switch kind {
        case "allow_once": return .allowOnce
        case "allow_always": return .allowAlways
        case "reject_once", "reject_always": return .reject
        default: return .unknown
        }
    }

    /// True when the engine said the option lets the tool run.
    ///
    /// A kind this build does not know is not counted here:  the engine
    /// never said so, and the card shows what it knows rather than what it
    /// guesses.
    public var allows: Bool {
        effect == .allowOnce || effect == .allowAlways
    }

    /// True when the option refuses the tool.
    ///
    /// Only the kinds the protocol names are refusals.  An unfamiliar kind
    /// is not one, so the gate stays shut on it.
    public var isReject: Bool {
        effect == .reject
    }

    /// True when answering this option needs the owner to be there.
    ///
    /// The gate is default-deny:  every option but a known refusal waits
    /// for the owner's face, so a kind this build has never seen cannot
    /// go through unchecked.
    public var needsOwnerPresence: Bool {
        !isReject
    }
}

/// One thing the owner reads before answering a permission request.
public struct AcpPermissionEvidenceLine: Equatable, Sendable, Identifiable {
    /// What the line holds, in the owner's words.
    public var label: String
    /// The command, the path or the diff.
    public var text: String

    public var id: String { label }

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }
}

/// What the tool wants to do, as the owner reads it before answering.
///
/// An approval the owner cannot read is not an approval, so the sidecar
/// carries the command for a shell tool, the path for a file tool and a
/// compact diff for an edit.  A request whose evidence is missing shows no
/// evidence:  the card says what it knows and nothing more.
public struct AcpPermissionEvidence: Decodable, Equatable, Sendable {
    /// The command the tool wants to run.
    public var command: String?
    /// The path the tool wants to touch.
    public var path: String?
    /// The lines the tool wants to write, as a compact diff.
    public var diff: String?

    public init(command: String? = nil, path: String? = nil, diff: String? = nil) {
        self.command = command
        self.path = path
        self.diff = diff
    }

    /// What the card shows, in the order the owner reads it.
    ///
    /// The command comes first because it is what the owner has to judge,
    /// then the path the command touches, then the lines an edit writes.
    public var lines: [AcpPermissionEvidenceLine] {
        var out: [AcpPermissionEvidenceLine] = []
        if let command = self.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            out.append(AcpPermissionEvidenceLine(label: "Command", text: command))
        }
        if let path = self.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            out.append(AcpPermissionEvidenceLine(label: "Path", text: path))
        }
        if let diff = self.diff?.trimmingCharacters(in: .whitespacesAndNewlines), !diff.isEmpty {
            out.append(AcpPermissionEvidenceLine(label: "Changes", text: diff))
        }
        return out
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
    /// What the tool wants to do, when the engine said enough to read it.
    public var evidence: AcpPermissionEvidence?

    public var id: String { requestId }

    public init(
        requestId: String,
        title: String,
        toolName: String,
        options: [AcpPermissionOption],
        evidence: AcpPermissionEvidence? = nil
    ) {
        self.requestId = requestId
        self.title = title
        self.toolName = toolName
        self.options = options
        self.evidence = evidence
    }

    /// The options the phone offers.
    ///
    /// There is no "Always allow" on the phone:  an allow that outlives the
    /// turn is an allow the owner cannot see the scope of, and the phone is
    /// the surface where the owner is not at the keyboard.  The Mac keeps
    /// the option, because the owner is at the keyboard there.
    public var phoneOptions: [AcpPermissionOption] {
        options.filter { $0.effect != .allowAlways }
    }

    /// The option that refuses this request, when the engine offered one.
    ///
    /// A missing option id cancels the request, which is what a deny amounts
    /// to when the engine offered no reject option of its own.
    public var denyOptionId: String? {
        options.first(where: { $0.isReject })?.optionId
    }

    /// The options the phone does not offer, and why the Mac keeps them.
    ///
    /// The phone names these instead of dropping them without a word, so
    /// the owner can see that the Mac has an option the phone does not.
    public var phoneWithheldOptions: [AcpPermissionOption] {
        options.filter { $0.effect == .allowAlways }
    }

    /// True when the answer belongs to this request.
    ///
    /// The request can turn over while the owner is confirming it, and an
    /// answer for a request that is gone must not approve the request that
    /// took its place.
    public func accepts(_ answer: AcpPermissionAnswer) -> Bool {
        answer.requestId == requestId
    }

    /// The heading the card shows: what the tool wants, and which tool it is.
    public var headline: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let tool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        return tool.isEmpty ? "The engine is asking for permission" : tool
    }
}

/// One answer the owner gave to one permission request.
///
/// The request travels with the answer, because the owner confirms on a
/// delay — the phone asks for a face — and the request on screen can
/// turn over while they do.  An answer that names a request which is no
/// longer the one on screen is dropped rather than sent to whatever
/// replaced it.
public struct AcpPermissionAnswer: Equatable, Sendable {
    /// The request the owner was answering.
    public var requestId: String
    /// The option the owner picked, or nil to cancel the request.
    public var optionId: String?

    public init(requestId: String, optionId: String?) {
        self.requestId = requestId
        self.optionId = optionId
    }

    /// What the owner is told when an answer is dropped because the
    /// request it belonged to is no longer the one on screen.
    ///
    /// It names the request the owner answered rather than the one on
    /// screen, because the two are not the same and the owner has to know
    /// which one did not go out.
    public static let staleRequestMessage =
        "The request you answered changed before the answer went out, so it was not sent."
}

/// The permission requests one surface is holding, oldest first.
///
/// The engine asks one question at a time, but a second request can land
/// before the first is answered, so the surface keeps the earlier one on
/// screen instead of dropping it behind the newer card.
///
/// Every request carries the id the engine gave it, and the acknowledgment
/// names that id, so the card that goes is the card the owner answered and
/// not merely the first one on screen:  a queue of requests does not lose a
/// card because a later one was answered.
public struct PermissionRequests: Equatable, Sendable {
    /// The requests on screen, oldest first.
    public private(set) var requests: [AcpPermissionRequest] = []
    /// The requests this surface has answered.
    ///
    /// An engine that asks the same question twice gets one card, so an
    /// answered request does not come back as a second card the owner would
    /// answer a second time.
    public private(set) var acknowledged: Set<String> = []

    public init() {}

    /// The request on screen.
    public var first: AcpPermissionRequest? { requests.first }
    /// How many requests are waiting behind the one on screen.
    public var count: Int { requests.count }
    public var isEmpty: Bool { requests.isEmpty }

    /// The request one id names, when it is on screen.
    public func request(for requestId: String) -> AcpPermissionRequest? {
        requests.first { $0.requestId == requestId }
    }

    /// Puts a request on screen.
    ///
    /// A request that is already on screen, or that this surface has already
    /// answered, is a no-op:  the card stays one card per request, and an
    /// answered request does not come back as a question nobody is waiting
    /// for any more.
    public mutating func arrive(_ request: AcpPermissionRequest) {
        guard !acknowledged.contains(request.requestId) else { return }
        guard !requests.contains(where: { $0.requestId == request.requestId }) else { return }
        requests.append(request)
    }

    /// Clears the request one acknowledgment names, and nothing else.
    ///
    /// The acknowledgment is this device's own state, so the request id
    /// alone says which card and which activity entry it clears:  no
    /// round-trip to the host is needed to work out what the acknowledgment
    /// means.  A request that is not on screen is a no-op:  nothing changes,
    /// no other request is cleared and nothing is raised, so an answer for a
    /// card that has already gone cannot take another card with it.
    @discardableResult
    public mutating func acknowledge(requestId: String) -> Bool {
        guard let index = requests.firstIndex(where: { $0.requestId == requestId }) else { return false }
        requests.remove(at: index)
        acknowledged.insert(requestId)
        return true
    }

    /// Takes every request off the screen.
    ///
    /// A turn that ended cannot answer a question any more, so the cards go
    /// with it rather than sitting there inviting an answer that lands
    /// nowhere.
    public mutating func clearAll() {
        requests.removeAll()
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
    public var basis: String?
    public var totalsComplete: Bool?
    public var inputTokensReported: Bool?
    public var outputTokensReported: Bool?
    public var cachedTokens: Int?
    public var responseTokensPerSecond: Double?
    public var completionDurationMs: Double?
    public var provider: String?
    public var model: String?
    /// The model's total context window, as the engine reported it.
    public var contextWindow: Int?
    public var contextUsedTokens: Int?
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
        outputTokensPerSecond: Double? = nil,
        basis: String? = nil,
        totalsComplete: Bool? = nil,
        inputTokensReported: Bool? = nil,
        outputTokensReported: Bool? = nil,
        cachedTokens: Int? = nil,
        responseTokensPerSecond: Double? = nil,
        completionDurationMs: Double? = nil,
        contextUsedTokens: Int? = nil
    ) {
        self.provider = provider
        self.model = model
        self.contextWindow = contextWindow
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokensPerSecond = outputTokensPerSecond
        self.basis = basis
        self.totalsComplete = totalsComplete
        self.inputTokensReported = inputTokensReported
        self.outputTokensReported = outputTokensReported
        self.cachedTokens = cachedTokens
        self.responseTokensPerSecond = responseTokensPerSecond
        self.completionDurationMs = completionDurationMs
        self.contextUsedTokens = contextUsedTokens
    }

    /// Occupancy as a percentage of the window, or nil when either half is
    /// unknown.  A zero or missing window yields nil rather than infinity.
    public var contextUsedPercent: Double? {
        guard contextUsedTokens != nil || basis != "session-totals" else { return nil }
        guard let contextWindow, contextWindow > 0 else { return nil }
        return (Double(contextUsedTokens ?? totalTokens) / Double(contextWindow)) * 100
    }

    /// `152.1k`, `1.04M`, or the raw number under a thousand.
    public static func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }

    /// `61% · 610k / 1M`, or nil when the engine reported neither half.
    public var occupancyLabel: String? {
        guard contextUsedTokens != nil || basis != "session-totals" else { return nil }
        guard contextWindow != nil || totalTokens > 0 else { return nil }
        guard let percent = contextUsedPercent, let contextWindow else { return nil }
        return String(
            format: "%.0f%% · %@ / %@",
            percent,
            Self.compact(contextUsedTokens ?? totalTokens),
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
    /// Exact model identity reported by the engine when available.
    public var provider: String?
    public var model: String?
    /// Present only when the sidecar could read the engine's own accounting.
    public var usage: AcpSessionUsage?
    /// Project this session belongs to, set by the sidecar's metadata store.
    public var projectId: String?
    /// True when the user archived it.  Archived threads are hidden, never gone.
    public var archived: Bool?

    private static let dateParser = AcpSessionDateParser()

    public var id: String { sessionId }

    public init(
        sessionId: String,
        cwd: String? = nil,
        title: String? = nil,
        updatedAt: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        usage: AcpSessionUsage? = nil,
        projectId: String? = nil,
        archived: Bool? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.provider = provider
        self.model = model
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
        dateParser.date(from: value)
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
                session.model, session.provider,
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
        let ordered = newestFirst(sessions)
        return grouped(ordered: ordered, pinned: pinned, now: now, calendar: calendar)
    }

    static func grouped(ordered sessions: [AcpSessionInfo], pinned: Set<String>, now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        guard !pinned.isEmpty else { return grouped(ordered: sessions, now: now, calendar: calendar) }
        let pinnedRows = sessions.filter { pinned.contains($0.sessionId) }
        let rest = sessions.filter { !pinned.contains($0.sessionId) }
        guard !pinnedRows.isEmpty else { return grouped(ordered: sessions, now: now, calendar: calendar) }
        return [Group(title: "Pinned", sessions: pinnedRows)] + grouped(ordered: rest, now: now, calendar: calendar)
    }

    /// Newest-first sessions bucketed as Today / Yesterday / Previous 7 Days
    /// / Older / Undated, empty buckets dropped.  Undated threads go last:
    /// they still work, they just cannot claim a place in the timeline.
    public static func grouped(_ sessions: [AcpSessionInfo], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        grouped(ordered: newestFirst(sessions), now: now, calendar: calendar)
    }

    private static func grouped(ordered: [AcpSessionInfo], now: Date, calendar: Calendar) -> [Group] {
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
/// One tool call the agent ran, or a status update to one already shown.
///
/// A tool that runs other tools is the parent of them, and the clients show
/// that as a tree: the children hang under the call that made them.
public struct AcpToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var status: String
    /// The call this one ran under, when a tool ran other tools.
    public var parentId: String?
    /// What the tool was asked to do, as the engine wrote it.
    public var input: String?
    /// What the tool answered, as the engine wrote it.
    public var output: String?

    public init(
        id: String,
        name: String,
        status: String,
        parentId: String? = nil,
        input: String? = nil,
        output: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.parentId = parentId
        self.input = input
        self.output = output
    }
}

public struct AcpHistoryEntry: Decodable, Equatable, Sendable {
    public var sessionId: String
    public var kind: String
    public var text: String
    /// Present on tool-call entries (`tool_call`, `tool_call_update`).
    public var toolCallId: String?
    public var toolStatus: String?
    /// The call this one ran under, when a tool ran other tools.
    public var parentToolCallId: String?
    /// What the tool was asked to do, as the engine wrote it.
    public var toolInput: String?
    /// What the tool answered, as the engine wrote it.
    ///
    /// The input says what the call was asked and the output says what came
    /// back.  A card that carries only the input shows a question; a card
    /// that carries both shows the work.
    public var toolOutput: String?
    /// Present on a `plan` entry: the plan the engine last reported.
    public var plan: [AcpPlanEntry]?
    /// The time the engine recorded the entry, in epoch milliseconds.
    ///
    /// A replayed entry carries the time it happened.  An entry with no
    /// time says so, and the client shows no time rather than the time the
    /// entry was read back.
    public var at: Double?

    public init(
        sessionId: String,
        kind: String,
        text: String,
        toolCallId: String? = nil,
        toolStatus: String? = nil,
        parentToolCallId: String? = nil,
        toolInput: String? = nil,
        toolOutput: String? = nil,
        plan: [AcpPlanEntry]? = nil,
        at: Double? = nil
    ) {
        self.sessionId = sessionId
        self.kind = kind
        self.text = text
        self.toolCallId = toolCallId
        self.toolStatus = toolStatus
        self.parentToolCallId = parentToolCallId
        self.toolInput = toolInput
        self.toolOutput = toolOutput
        self.plan = plan
        self.at = at
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
