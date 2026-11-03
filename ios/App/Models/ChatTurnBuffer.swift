import Foundation

/// Output already received from one turn, retained on every terminal path.
struct ChatTurnBuffer: Equatable {
    private static let maximumUnidentifiedToolRows = 128

    struct Tool: Identifiable, Equatable {
        var id: String
        var name: String
        var status: String
    }

    struct Snapshot: Equatable {
        var text: String
        var tools: [Tool]
    }

    private(set) var text = ""
    private(set) var tools: [Tool] = []
    private(set) var finished = false
    private var unidentifiedToolRows = 0
    private var unidentifiedOverflowCount = 0
    private var unidentifiedOverflowIndex: Int?

    mutating func append(_ chunk: String) {
        guard !finished else { return }
        text += chunk
    }

    mutating func updateTool(id: String, name: String, status: String) {
        guard !finished else { return }
        if !id.isEmpty {
            if let index = tools.firstIndex(where: { $0.id == id }) {
                tools[index].status = status
                if !name.isEmpty { tools[index].name = name }
            } else {
                tools.append(Tool(id: id, name: name.isEmpty ? "Tool Call" : name, status: status))
            }
            return
        }

        if unidentifiedToolRows < Self.maximumUnidentifiedToolRows {
            unidentifiedToolRows += 1
            tools.append(Tool(
                id: "unidentified-\(UUID().uuidString)",
                name: name.isEmpty ? "Tool Call" : name,
                status: status
            ))
            return
        }

        unidentifiedOverflowCount += 1
        let summaryName = "Additional Tool Updates (\(unidentifiedOverflowCount))"
        if let index = unidentifiedOverflowIndex {
            tools[index].name = summaryName
            tools[index].status = status
        } else {
            tools.append(Tool(id: "unidentified-overflow-\(UUID().uuidString)", name: summaryName, status: status))
            unidentifiedOverflowIndex = tools.index(before: tools.endIndex)
        }
    }

    /// Find an update target only among tool rows appended during this turn.
    /// ACP ids may be reused across turns, and a prior turn's row must remain
    /// immutable when a new stream reports the same id.
    static func latestToolIndex(
        in history: [AcpHistoryEntry],
        matching id: String,
        from turnStartIndex: Int
    ) -> Int? {
        guard !id.isEmpty, turnStartIndex >= history.startIndex, turnStartIndex <= history.endIndex else { return nil }
        return history[turnStartIndex...].lastIndex {
            $0.isTool && $0.toolCallId == id
        }
    }

    /// Draining twice cannot duplicate a response when cancel races completion.
    mutating func finish() -> Snapshot? {
        guard !finished else { return nil }
        finished = true
        return drain()
    }

    mutating func drain() -> Snapshot {
        let snapshot = Snapshot(text: text, tools: tools)
        text = ""
        tools = []
        unidentifiedToolRows = 0
        unidentifiedOverflowCount = 0
        unidentifiedOverflowIndex = nil
        return snapshot
    }
}
