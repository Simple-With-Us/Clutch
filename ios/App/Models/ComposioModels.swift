import Foundation

public struct ComposioApp: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    public var iconName: String
    public var isConnected: Bool
    public var toolsCount: Int
    public var description: String
    public var authType: String
    
    public init(
        id: String,
        name: String,
        iconName: String,
        isConnected: Bool = false,
        toolsCount: Int = 0,
        description: String = "",
        authType: String = "OAuth"
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.isConnected = isConnected
        self.toolsCount = toolsCount
        self.description = description
        self.authType = authType
    }
    
    public static var defaults: [ComposioApp] {
        [
            ComposioApp(
                id: "github",
                name: "GitHub",
                iconName: "chevron.left.forwardslash.chevron.right",
                isConnected: true,
                toolsCount: 42,
                description: "Interact with GitHub repos, pull requests, issues, commits, and workflows."
            ),
            ComposioApp(
                id: "slack",
                name: "Slack",
                iconName: "bubble.left.and.bubble.right.fill",
                isConnected: true,
                toolsCount: 28,
                description: "Post messages, monitor channels, manage threads, and coordinate with team members."
            ),
            ComposioApp(
                id: "linear",
                name: "Linear",
                iconName: "square.stack.3d.up.fill",
                isConnected: true,
                toolsCount: 19,
                description: "Issue tracking, cycle management, project roadmaps, and triage workflows."
            ),
            ComposioApp(
                id: "notion",
                name: "Notion",
                iconName: "doc.text.fill",
                isConnected: false,
                toolsCount: 35,
                description: "Read, write, search, and manage Notion workspace pages and databases."
            ),
            ComposioApp(
                id: "gmail",
                name: "Google Mail",
                iconName: "envelope.fill",
                isConnected: false,
                toolsCount: 15,
                description: "Draft, send, search, and parse emails via Google Workspace APIs."
            ),
            ComposioApp(
                id: "discord",
                name: "Discord",
                iconName: "person.2.fill",
                isConnected: false,
                toolsCount: 22,
                description: "Send alerts, interact with community servers, and trigger bot actions."
            )
        ]
    }
}

public struct ComposioAction: Identifiable, Codable, Hashable {
    public var id: String
    public var appName: String
    public var name: String
    public var description: String
    public var parametersJson: String
    
    public init(
        id: String = UUID().uuidString,
        appName: String,
        name: String,
        description: String,
        parametersJson: String = "{}"
    ) {
        self.id = id
        self.appName = appName
        self.name = name
        self.description = description
        self.parametersJson = parametersJson
    }
}
