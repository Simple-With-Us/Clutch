import Foundation

/// Output already received from one turn, retained on every terminal path.
struct ChatTurnBuffer: Equatable {
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

    mutating func append(_ chunk: String) {
        guard !finished else { return }
        text += chunk
    }

    mutating func updateTool(id: String, name: String, status: String) {
        guard !finished else { return }
        if !id.isEmpty, let index = tools.firstIndex(where: { $0.id == id }) {
            tools[index].status = status
            if !name.isEmpty { tools[index].name = name }
        } else {
            let toolId = id.isEmpty ? "unidentified-\(UUID().uuidString)" : id
            tools.append(Tool(id: toolId, name: name.isEmpty ? "Tool Call" : name, status: status))
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
        return snapshot
    }
}
