import SwiftUI

public struct ToolsView: View {
    @State private var selectedSegment: Int = 0
    @State private var tools: [ToolItem] = ToolItem.defaults
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented control
                Picker("Category", selection: $selectedSegment) {
                    Text("Composio").tag(0)
                    Text("Fleet RAG").tag(1)
                    Text("MCP").tag(2)
                    Text("Built-in").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                
                Divider()
                
                // Content
                switch selectedSegment {
                case 0:
                    ComposioView()
                case 1:
                    FleetRAGView()
                case 2:
                    MCPListView(tools: tools.filter { $0.category == .mcp })
                case 3:
                    BuiltInToolsListView(tools: tools.filter { $0.category == .builtIn })
                default:
                    EmptyView()
                }
            }
            .navigationTitle("Tools & Extensions")
        }
    }
}

struct BuiltInToolsListView: View {
    let tools: [ToolItem]
    
    var body: some View {
        List {
            Section(header: Text("Core Execution Tools")) {
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: tool.category.iconName)
                                .foregroundColor(.accentColor)
                            Text(tool.name)
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                            Spacer()
                            Text("Active")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.green)
                        }
                        
                        Text(tool.description)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        
                        Text(tool.parametersSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct MCPListView: View {
    let tools: [ToolItem]
    
    var body: some View {
        List {
            Section(header: Text("Mounted MCP Servers")) {
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundColor(.indigo)
                            Text(tool.name)
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                            Spacer()
                            Text("Connected")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.green)
                        }
                        
                        Text(tool.description)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Section(footer: Text("MCP servers are mounted to DSH through cordis overlay patches.&nbsp; Configure custom stdio or SSE servers in your host's cordis.patch.yml.")) {
                NavigationLink(destination: Text("Add MCP Server configuration on host")) {
                    Label("Configure Remote MCP Server", systemImage: "plus.circle")
                }
            }
        }
    }
}
