import Foundation

public struct Session: Identifiable, Codable, Hashable {
    public var id: String
    public var title: String
    public var workspacePath: String?
    public var model: String
    public var vendor: ModelVendor
    public var reasoningEffort: ReasoningEffort
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var tokenCount: Int
    public var hostId: UUID?
    
    public init(
        id: String = UUID().uuidString,
        title: String = "New Session",
        workspacePath: String? = nil,
        model: String = "MiniMax-M3",
        vendor: ModelVendor = .miniMax,
        reasoningEffort: ReasoningEffort = .medium,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        tokenCount: Int = 0,
        hostId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.workspacePath = workspacePath
        self.model = model
        self.vendor = vendor
        self.reasoningEffort = reasoningEffort
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.tokenCount = tokenCount
        self.hostId = hostId
    }
}
