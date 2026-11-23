import Foundation

/// The transcript a Mac thread shows, derived from one state.
///
/// The rows are derived and not stored:  the view holds the history, the
/// prompts it sent, the tool calls and the turn that is running, and this
/// model turns them into the rows the transcript renders.
/// Keeping the derivation in one place means the view renders a transcript
/// instead of being one, and it means the derivation can be tested without
/// a window.
///
/// The live turn is part of the transcript.  A separate pane for it made
/// the answer move twice:  it streamed in the pane and then jumped into
/// the transcript when the turn ended, so the reader had to follow it.
public struct MacTranscriptModel: Equatable, Sendable {

    // MARK: - Turns

    /// What a tool call touched.
    public enum ToolKind: String, Equatable, Sendable {
        /// A file:  it read one, wrote one or edited one.
        case file
        /// A command:  it ran something.
        case command
        /// A test:  it ran a suite.
        case test
        /// Anything else.
        case other

        /// The kind a tool's name names.
        ///
        /// The engines name their tools after what they do, so the name is
        /// the only thing there is to go on.  The names are read the way the
        /// engines write them:  `read_file`, `edit_file`, `apply_patch`,
        /// `bash`, `run_tests`.
        public static func classify(_ name: String) -> ToolKind {
            let n = name.lowercased()
            if n.contains("test") { return .test }
            if n.contains("file") || n.contains("patch")
                || n.hasPrefix("read") || n.hasPrefix("write") || n.hasPrefix("edit") {
                return .file
            }
            if n.contains("bash") || n.contains("shell") || n.contains("exec")
                || n.contains("command") || n.contains("terminal") || n.hasPrefix("run") {
                return .command
            }
            return .other
        }
    }

    /// One turn of the thread.
    ///
    /// A turn is one prompt and everything the engine did in answer to it.
    /// The ledger shows the turn as a header and the rows as its body, so a
    /// reader can see where a turn began, how long it took and what it
    /// touched without reading every row.
    public struct Turn: Identifiable, Equatable, Sendable {
        /// The turn's stable identity.
        ///
        /// It is derived from the row that started the turn, so the same
        /// turn keeps the same identity across launches and the collapsed
        /// state a reader chose stays collapsed.
        public var id: String
        /// The turn's number, counting from one.
        public var number: Int
        /// The prompt that started the turn, shortened to a headline.
        public var summary: String
        /// The time the turn started, when one is known.
        public var startedAt: Date?
        /// How long the turn took, when the times are known.
        public var duration: TimeInterval?
        /// How many tool calls the turn made.
        public var toolCount: Int
        /// How many files the turn touched.
        public var fileCount: Int
        /// How many commands the turn ran.
        public var commandCount: Int
        /// How many tests the turn ran.
        public var testCount: Int
        /// The rows of the turn, in order.
        public var rowIDs: [String]
        /// Whether the turn is the one running right now.
        public var isRunning: Bool
    }

    /// Where a row sits, in the words a reader uses.
    public struct TurnLocation: Equatable, Sendable {
        /// The turn the row is in, counting from one.
        public var turn: Int
        /// The tool call the row is, counting from one within the turn.
        public var tool: Int?
        /// What the row holds.
        public var kind: Kind
    }

    /// The turns of the transcript, in order.
    public var turns: [Turn] {
        var order: [Int] = []
        var buckets: [Int: [Row]] = [:]
        for row in rawRows {
            let number = row.turn ?? 1
            if buckets[number] == nil { order.append(number) }
            buckets[number, default: []].append(row)
        }
        return order.map { number in
            let rows = buckets[number] ?? []
            let tools = rows.filter { $0.kind == .tool }
            return Turn(
                id: MacTranscriptModel.stableIdentifier(["turn", String(number), rows.first?.id ?? ""]),
                number: number,
                summary: promptSummary(of: rows),
                startedAt: rows.compactMap { $0.date }.min(),
                duration: span(of: rows),
                toolCount: tools.count,
                fileCount: tools.filter { ToolKind.classify($0.text) == .file }.count,
                commandCount: tools.filter { ToolKind.classify($0.text) == .command }.count,
                testCount: tools.filter { ToolKind.classify($0.text) == .test }.count,
                rowIDs: rows.map { $0.id },
                isRunning: rows.contains { $0.kind == .live || $0.kind == .failure }
            )
        }
    }

    /// Where a row sits, in the words a reader uses.
    ///
    /// Find can then say "turn 3, tool 5" instead of highlighting a string
    /// and hoping the reader knows where they are.
    public func location(of rowID: String) -> TurnLocation? {
        let rows = rawRows
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return nil }
        let row = rows[index]
        let turn = row.turn ?? 1
        var tool = 0
        for candidate in rows {
            guard (candidate.turn ?? 1) == turn else { continue }
            if candidate.kind == .tool {
                tool += 1
                if candidate.id == rowID { break }
            }
        }
        return TurnLocation(turn: turn, tool: tool == 0 ? nil : tool, kind: row.kind)
    }

    /// Numbers the turns of the transcript.
    ///
    /// A turn begins at a prompt and runs until the next one.  The rows
    /// that come before the first prompt are the thread that was already
    /// there, and they are a turn of their own.
    private func numberingTurns(_ rows: [Row]) -> [Row] {
        var out: [Row] = []
        var turn = 0
        for row in rows {
            if turn == 0 || (row.kind == .message && !row.fromAgent) { turn += 1 }
            var numbered = row
            numbered.turn = turn
            out.append(numbered)
        }
        return out
    }

    /// The headline of a turn:  the prompt that started it.
    private func promptSummary(of rows: [Row]) -> String {
        let prompt = rows.first { $0.kind == .message && !$0.fromAgent }
        let text = prompt?.text ?? rows.first?.text ?? ""
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        if line.isEmpty { return "Turn" }
        return line.count > 80 ? String(line.prefix(79)) + "\u{2026}" : line
    }

    /// How long a turn took, when the times are known.
    ///
    /// A turn whose rows carry no time has no length:  the length of a
    /// turn that is not timed is not the time it was read back.
    private func span(of rows: [Row]) -> TimeInterval? {
        let dates = rows.compactMap { $0.date }
        guard let first = dates.min(), let last = dates.max(), last > first else { return nil }
        return last.timeIntervalSince(first)
    }

    // MARK: - Verbosity

    /// How much of the transcript the reader wants to see.
    public enum Verbosity: String, CaseIterable, Identifiable, Sendable {
        /// The prompts, the answers, and one row for each run of tool calls.
        case summary
        /// Everything, with each run of tool calls collapsed into one row.
        case normal
        /// Every row:  each tool call on its own, and the thoughts with them.
        case verbose

        public var id: String { rawValue }

        /// The name the picker shows.
        public var title: String {
            switch self {
            case .summary: return "Summary"
            case .normal: return "Normal"
            case .verbose: return "Verbose"
            }
        }

        /// What the picker says the mode is for.
        public var detail: String {
            switch self {
            case .summary:
                return "Your prompts and the answers, with the tool calls counted"
            case .normal:
                return "Everything, with each run of tool calls collapsed"
            case .verbose:
                return "Every row, with each tool call and thought on its own"
            }
        }
    }

    // MARK: - Rows

    /// What a row holds.
    public enum Kind: String, Equatable, Sendable {
        /// A prompt the owner sent, or an answer from the thread.
        case message
        /// The engine's reasoning for the turn.
        case thought
        /// One tool call.
        case tool
        /// A run of tool calls collapsed into one row.
        case toolGroup
        /// The answer that is streaming right now.
        case live
        /// The turn failed.
        case failure
    }

    /// One row of the transcript.
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String
        public var kind: Kind
        public var text: String
        /// The time the row happened, when one is known.
        ///
        /// A replayed row carries the time the engine recorded it.  A row
        /// with no time shows no time at all:  a row that shows the time it
        /// was read back tells the reader that a three week old thread
        /// happened today.
        public var date: Date?
        public var fromAgent: Bool
        public var isCard: Bool
        public var toolStatus: String?
        public var toolDepth: Int
        public var toolInput: String?
        /// What the tool answered, when the engine recorded an answer.
        public var toolOutput: String?
        /// How many tool calls a group row stands for.
        public var toolCount: Int
        /// The turn the row belongs to, counting from one.
        ///
        /// A turn is one prompt and everything the engine did in answer to
        /// it.  The number lets the ledger draw a header for the turn and
        /// lets Find say where a row is in the words the reader uses.
        public var turn: Int?

        public init(
            id: String,
            kind: Kind = .message,
            text: String,
            date: Date? = nil,
            fromAgent: Bool = true,
            isCard: Bool = false,
            toolStatus: String? = nil,
            toolDepth: Int = 0,
            toolInput: String? = nil,
            toolOutput: String? = nil,
            toolCount: Int = 1,
            turn: Int? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.date = date
            self.fromAgent = fromAgent
            self.isCard = isCard
            self.toolStatus = toolStatus
            self.toolDepth = toolDepth
            self.toolInput = toolInput
            self.toolOutput = toolOutput
            self.toolCount = toolCount
            self.turn = turn
        }
    }

    // MARK: - The state the transcript is derived from

    /// A prompt the owner sent here.
    public struct Prompt: Identifiable, Equatable, Sendable {
        public var id: String
        public var text: String
        public var at: Date?

        public init(id: String, text: String, at: Date? = nil) {
            self.id = id
            self.text = text
            self.at = at
        }
    }

    /// A message in the thread.
    public struct Message: Identifiable, Equatable, Sendable {
        public var id: String
        public var text: String
        public var date: Date?
        public var fromAgent: Bool
        public var isCard: Bool

        public init(
            id: String,
            text: String,
            date: Date? = nil,
            fromAgent: Bool = true,
            isCard: Bool = false
        ) {
            self.id = id
            self.text = text
            self.date = date
            self.fromAgent = fromAgent
            self.isCard = isCard
        }
    }

    /// One entry of a replayed thread.
    public struct HistoryEntry: Equatable, Sendable {
        public var id: String
        public var text: String
        /// The time the engine recorded the entry, when it recorded one.
        public var at: Date?
        public var fromAgent: Bool
        public var isThought: Bool
        public var isTool: Bool
        public var toolStatus: String?
        public var toolDepth: Int
        public var toolInput: String?
        /// What the tool answered, when the engine recorded an answer.
        public var toolOutput: String?

        public init(
            id: String,
            text: String,
            at: Date? = nil,
            fromAgent: Bool = true,
            isThought: Bool = false,
            isTool: Bool = false,
            toolStatus: String? = nil,
            toolDepth: Int = 0,
            toolInput: String? = nil,
            toolOutput: String? = nil
        ) {
            self.id = id
            self.text = text
            self.at = at
            self.fromAgent = fromAgent
            self.isThought = isThought
            self.isTool = isTool
            self.toolStatus = toolStatus
            self.toolDepth = toolDepth
            self.toolInput = toolInput
            self.toolOutput = toolOutput
        }
    }

    /// One tool call.
    public struct ToolCall: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var status: String?
        public var depth: Int
        public var input: String?
        /// What the call answered, when it has answered.
        public var output: String?

        public init(
            id: String,
            name: String,
            status: String? = nil,
            depth: Int = 0,
            input: String? = nil,
            output: String? = nil
        ) {
            self.id = id
            self.name = name
            self.status = status
            self.depth = depth
            self.input = input
            self.output = output
        }
    }

    /// The turn that is running right now.
    public struct Live: Equatable, Sendable {
        public var text: String
        public var thought: String?
        public var failure: String?
        public var running: Bool

        public static let idle = Live(text: "", thought: nil, failure: nil, running: false)

        public init(text: String = "", thought: String? = nil, failure: String? = nil, running: Bool = false) {
            self.text = text
            self.thought = thought
            self.failure = failure
            self.running = running
        }

        /// Whether the live turn has anything to show.
        public var isEmpty: Bool {
            !running && text.isEmpty && thought == nil && failure == nil
        }
    }

    /// The prompts the owner sent here.
    public var prompts: [Prompt] = []
    /// The messages of the thread.
    public var messages: [Message] = []
    /// The replayed thread, in the order the engine recorded it.
    public var history: [HistoryEntry] = []
    /// The prompts that have not been sent yet.
    public var pending: [Prompt] = []
    /// The tool calls of the turn that is running.
    public var tools: [ToolCall] = []
    /// The turn that is running right now.
    public var live: Live = .idle
    /// How much of the transcript the reader wants to see.
    public var verbosity: Verbosity = .normal
    /// Whether this is the workspace surface, where the replay is the truth.
    public var workspace: Bool = false

    // MARK: - Identity

    /// A stable identifier for a row.
    ///
    /// Swift's own `hashValue` is seeded per process, so the same row gets a
    /// different identity every launch.  A transcript that reorders itself on
    /// every launch feels broken, so the identifier is derived from the parts
    /// that make the row what it is.
    ///
    /// The hash is an FNV-1a:  it is small, it is stable across launches, and
    /// it never collides with a row that has different parts.
    public static func stableIdentifier(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for part in parts {
            for byte in part.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            hash ^= 0x1f
            hash = hash &* 0x100000001b3
        }
        return "r" + String(hash, radix: 36)
    }

    // MARK: - The rows

    /// The rows the transcript shows, in the order it shows them.
    public var rows: [Row] {
        applyVerbosity(to: rawRows)
    }

    /// The rows before the verbosity is applied.
    ///
    /// The ledger counts the work a turn did, so it counts the calls that
    /// are really there and not the rows that survived the collapsing.
    private var rawRows: [Row] {
        numberingTurns(workspace ? workspaceRows() : chatRows())
    }

    /// The rows of a chat thread.
    ///
    /// The chat surface keeps its own history, so the rows are ordered by
    /// the time each one happened.  A row with no time is ordered as the
    /// oldest thing there is:  it is a row that does not know when it
    /// happened, and pretending it happened just now would be a claim the
    /// transcript cannot support.
    private func chatRows() -> [Row] {
        let promptRows = prompts.map {
            Row(id: $0.id, text: $0.text, date: $0.at, fromAgent: false, isCard: false)
        }
        let messageRows = messages.map {
            Row(id: $0.id, text: $0.text, date: $0.date, fromAgent: $0.fromAgent, isCard: $0.isCard)
        }
        let ordered = (promptRows + messageRows).sorted {
            ($0.date ?? .distantPast) < ($1.date ?? .distantPast)
        }
        return ordered + toolRows() + liveRows()
    }

    /// The rows of the workspace surface.
    ///
    /// The workspace replays the engine's own history, and that history is
    /// already in the order the engine recorded it, so the rows keep it.
    private func workspaceRows() -> [Row] {
        var out = history.map { entry in
            Row(
                id: entry.id,
                kind: entry.isTool ? .tool : (entry.isThought ? .thought : .message),
                text: entry.text,
                date: entry.at,
                fromAgent: entry.fromAgent,
                isCard: false,
                toolStatus: entry.toolStatus,
                toolDepth: entry.toolDepth,
                toolInput: entry.toolInput,
                toolOutput: entry.toolOutput
            )
        }
        out += pending.map {
            Row(id: $0.id, text: $0.text, date: $0.at, fromAgent: false, isCard: false)
        }
        out += toolRows()
        out += liveRows()
        return out
    }

    /// The rows of the tool calls that are running now.
    ///
    /// A tool call has no recorded time of its own, so the row carries no
    /// time:  the time the client read the call back is not the time the
    /// call happened.
    private func toolRows() -> [Row] {
        tools.map {
            Row(
                id: "live-\($0.id)",
                kind: .tool,
                text: $0.name,
                date: nil,
                fromAgent: true,
                isCard: false,
                toolStatus: $0.status,
                toolDepth: $0.depth,
                toolInput: $0.input,
                toolOutput: $0.output
            )
        }
    }

    /// The rows of the turn that is running now.
    private func liveRows() -> [Row] {
        var out: [Row] = []
        if let thought = live.thought, !thought.isEmpty {
            out.append(Row(id: "live-thought", kind: .thought, text: thought, fromAgent: true))
        }
        if live.running {
            if live.text.isEmpty {
                out.append(Row(id: "live-working", kind: .live, text: "Working…", fromAgent: true))
            } else {
                out.append(Row(id: "live-answer", kind: .live, text: live.text, fromAgent: true))
            }
        }
        if let failure = live.failure, !failure.isEmpty {
            out.append(Row(id: "live-failure", kind: .failure, text: failure, fromAgent: true))
        }
        return out
    }

    // MARK: - Verbosity

    /// Applies the verbosity the reader asked for.
    private func applyVerbosity(to rows: [Row]) -> [Row] {
        switch verbosity {
        case .verbose:
            return rows
        case .normal:
            return collapseToolRuns(rows)
        case .summary:
            return collapseToolRuns(rows.filter { $0.kind != .thought })
        }
    }

    /// What a run of tool calls did, in one line.
    ///
    /// The count alone says how much happened and not what, so the line
    /// names the kinds:  "3 files, 1 command, 1 test" says more in one
    /// glance than "5 tool calls", and it is what a reader decides
    /// whether to open the run on.
    private func breakdown(of run: [Row]) -> String {
        let kinds = run.map { MacTranscriptModel.ToolKind.classify($0.text) }
        let files = kinds.filter { $0 == .file }.count
        let commands = kinds.filter { $0 == .command }.count
        let tests = kinds.filter { $0 == .test }.count
        var parts: [String] = []
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        if commands > 0 { parts.append("\(commands) command\(commands == 1 ? "" : "s")") }
        if tests > 0 { parts.append("\(tests) test\(tests == 1 ? "" : "s")") }
        let named = files + commands + tests
        if named < run.count {
            parts.append("\(run.count - named) more")
        }
        if parts.isEmpty {
            return "\(run.count) tool call\(run.count == 1 ? "" : "s")"
        }
        return parts.joined(separator: ", ")
    }

    /// Collapses each run of tool rows into one row.
    ///
    /// A turn calls its tools one after another, and one row per call
    /// buries the answer the reader came for under the calls that produced
    /// it.  The group row carries the count and the outcome of the run, so
    /// the reader still sees what happened without reading every call.
    private func collapseToolRuns(_ rows: [Row]) -> [Row] {
        var out: [Row] = []
        var run: [Row] = []

        func flush() {
            guard let first = run.first else { return }
            guard run.count > 1 else {
                out.append(first)
                run = []
                return
            }
            let last = run[run.count - 1]
            out.append(
                Row(
                    id: "group-\(first.id)",
                    kind: .toolGroup,
                    text: breakdown(of: run),
                    date: first.date,
                    fromAgent: true,
                    isCard: false,
                    toolStatus: last.toolStatus,
                    toolDepth: first.toolDepth,
                    toolInput: nil,
                    toolOutput: nil,
                    toolCount: run.count,
                    turn: first.turn
                )
            )
            run = []
        }

        for row in rows {
            if row.kind == .tool {
                run.append(row)
            } else {
                flush()
                out.append(row)
            }
        }
        flush()
        return out
    }
}
