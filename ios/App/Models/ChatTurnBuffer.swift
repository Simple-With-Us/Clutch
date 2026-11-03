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
        let key = id.isEmpty ? name : id
        if let index = tools.firstIndex(where: { $0.id == key }) {
            tools[index].status = status
            if !name.isEmpty { tools[index].name = name }
        } else {
            tools.append(Tool(id: key, name: name.isEmpty ? "Tool Call" : name, status: status))
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
