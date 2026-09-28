import Foundation

public enum MessageRole: String, Codable {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
    case tool = "tool"
}

public enum ToolStatus: String, Codable {
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

public struct ToolCall: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    public var argumentsJson: String
    public var output: String?
    public var status: ToolStatus
    public var durationMs: Double?
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        argumentsJson: String,
        output: String? = nil,
        status: ToolStatus = .completed,
        durationMs: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.argumentsJson = argumentsJson
        self.output = output
        self.status = status
        self.durationMs = durationMs
    }
}

public struct ChatMessage: Identifiable, Codable, Hashable {
    public var id: UUID
    public var role: MessageRole
    public var content: String
    public var reasoningContent: String?
    public var isReasoningExpanded: Bool
    public var toolCalls: [ToolCall]
    public var timestamp: Date
    public var modelUsed: String?
    public var isStreaming: Bool
    
    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        reasoningContent: String? = nil,
        isReasoningExpanded: Bool = false,
        toolCalls: [ToolCall] = [],
        timestamp: Date = Date(),
        modelUsed: String? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.isReasoningExpanded = isReasoningExpanded
        self.toolCalls = toolCalls
        self.timestamp = timestamp
        self.modelUsed = modelUsed
        self.isStreaming = isStreaming
    }
}
