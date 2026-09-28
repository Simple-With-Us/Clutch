import Foundation

public struct WorkspaceItem: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    public var path: String
    public var gitBranch: String?
    public var isGitRepo: Bool
    public var modifiedFilesCount: Int
    public var lastAccessed: Date
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        gitBranch: String? = nil,
        isGitRepo: Bool = true,
        modifiedFilesCount: Int = 0,
        lastAccessed: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.gitBranch = gitBranch
        self.isGitRepo = isGitRepo
        self.modifiedFilesCount = modifiedFilesCount
        self.lastAccessed = lastAccessed
    }
    
    public static var defaults: [WorkspaceItem] {
        [
            WorkspaceItem(
                name: "Harness",
                path: "~/Code/Harness",
                gitBranch: "main",
                isGitRepo: true,
                modifiedFilesCount: 0
            ),
            WorkspaceItem(
                name: "BotFleet",
                path: "~/Code/BotFleet",
                gitBranch: "main",
                isGitRepo: true,
                modifiedFilesCount: 2
            ),
            WorkspaceItem(
                name: "ai-fleet-coordinator",
                path: "~/Code/AI-Fleet-Coordinator",
                gitBranch: "main",
                isGitRepo: true,
                modifiedFilesCount: 1
            )
        ]
    }
}
