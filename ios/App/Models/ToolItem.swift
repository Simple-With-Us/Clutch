import Foundation

public enum ToolCategory: String, Codable, CaseIterable, Identifiable {
    case computerUse = "Computer Use"
    case composio = "Composio"
    case fleetRAG = "Fleet RAG"
    case builtIn = "Built-in"
    case mcp = "MCP Servers"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .computerUse: return "display.2"
        case .composio: return "puzzlepiece.extension.fill"
        case .fleetRAG: return "externaldrive.badge.icloud"
        case .builtIn: return "terminal.fill"
        case .mcp: return "server.rack"
        }
    }
}

public struct ToolItem: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    public var category: ToolCategory
    public var description: String
    public var parametersSummary: String
    public var isEnabled: Bool
    public var connectedAccount: String?
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        category: ToolCategory,
        description: String,
        parametersSummary: String = "()",
        isEnabled: Bool = true,
        connectedAccount: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.description = description
        self.parametersSummary = parametersSummary
        self.isEnabled = isEnabled
        self.connectedAccount = connectedAccount
    }
    
    public static var defaults: [ToolItem] {
        [
            ToolItem(
                name: "computer_control",
                category: .computerUse,
                description: "Native GUI interaction: take screenshots, move/click cursor, type keystrokes, and interact with desktop windows.",
                parametersSummary: "(action: 'screenshot'|'mouse_click'|'key'|'cursor_position', ...)"
            ),
            ToolItem(
                name: "computer_host_local",
                category: .computerUse,
                description: "Direct host machine execution for This Mac: shell commands, file reads, writes, and unified patch edits.",
                parametersSummary: "(mount: 'local', cwd: string, timeoutMs: 60000)"
            ),
            ToolItem(
                name: "computer_cloud_box",
                category: .computerUse,
                description: "ASCII.dev isolated remote cloud Linux sandbox container with network egress and computer proxy.",
                parametersSummary: "(mount: 'box', apiKeyEnv: 'BOX_API_KEY')"
            ),
            ToolItem(
                name: "computer_cloud_vps",
                category: .computerUse,
                description: "Dedicated self-hosted VPS / cloud virtual machine running full GUI desktop via Cua Driver.",
                parametersSummary: "(mount: 'vps', endpoint: string, auth: 'bearer')"
            ),
            ToolItem(
                name: "computer_local_vm",
                category: .computerUse,
                description: "Local microVM container running on Apple Silicon hypervisor with isolated filesystem.",
                parametersSummary: "(mount: 'vm', cpu: 4, memoryMb: 8192)"
            ),
            ToolItem(
                name: "bash",
                category: .builtIn,
                description: "Execute safe shell commands on the host machine with timeout and process-group isolation.",
                parametersSummary: "(command: string, cwd?: string)"
            ),
            ToolItem(
                name: "file_editor",
                category: .builtIn,
                description: "View, edit, or create files on the remote filesystem.",
                parametersSummary: "(path: string, operation: 'read'|'write'|'edit')"
            ),
            ToolItem(
                name: "composio_github",
                category: .composio,
                description: "Interact with GitHub issues, pull requests, commits, and releases via Composio.",
                parametersSummary: "(action: string, params: object)",
                connectedAccount: "jaywedgeworth22"
            ),
            ToolItem(
                name: "composio_slack",
                category: .composio,
                description: "Read and post coordination messages into #agent-sync channel.",
                parametersSummary: "(channel: string, text: string)",
                connectedAccount: "Fleet Bot"
            ),
            ToolItem(
                name: "composio_linear",
                category: .composio,
                description: "Manage engineering issues, triage bugs, and cycle state via Composio.",
                parametersSummary: "(issueId: string, status: string)",
                connectedAccount: "Team Lead"
            ),
            ToolItem(
                name: "recall_search",
                category: .fleetRAG,
                description: "Search shared fleet memory across all agent lessons, architectural decisions, and bugfixes.",
                parametersSummary: "(query: string, limit?: number, app?: string)"
            ),
            ToolItem(
                name: "recall_contribute",
                category: .fleetRAG,
                description: "Contribute a reusable finding or architectural lesson into the shared fleet-agents corpus.",
                parametersSummary: "(lesson: string, category: string, app: string)"
            ),
            ToolItem(
                name: "recall_stats",
                category: .fleetRAG,
                description: "Inspect total indexed chunks, query counts, and collection health across fleet RAG.",
                parametersSummary: "()"
            ),
            ToolItem(
                name: "mcp_datadog",
                category: .mcp,
                description: "Query metrics, traces, and monitor alerts via Datadog MCP server.",
                parametersSummary: "(service: string, query: string)"
            ),
            ToolItem(
                name: "mcp_sentry",
                category: .mcp,
                description: "Inspect active crash reports, issue traces, and release health in Sentry.",
                parametersSummary: "(org: string, project: string)"
            )
        ]
    }
}
