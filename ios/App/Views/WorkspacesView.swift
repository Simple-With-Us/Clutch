import SwiftUI

public struct WorkspacesView: View {
    @State private var apiClient = HarnessAPIClient.shared
    @State private var isShowingAddWorkspace: Bool = false
    @State private var newWorkspacePath: String = ""
    @Binding public var selectedTab: Int
    
    public init(selectedTab: Binding<Int>) {
        self._selectedTab = selectedTab
    }
    
    public var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Host Workspaces")) {
                    ForEach(apiClient.workspaces) { ws in
                        WorkspaceRow(
                            workspace: ws,
                            isActive: apiClient.activeWorkspace?.id == ws.id,
                            onSelect: {
                                apiClient.activeWorkspace = ws
                            },
                            onNewSession: {
                                apiClient.activeWorkspace = ws
                                _ = apiClient.createSession(
                                    title: "Session in \(ws.name)",
                                    workspacePath: ws.path
                                )
                                selectedTab = 0 // Go to chat
                            }
                        )
                    }
                }
                
                Section {
                    Button(action: {
                        isShowingAddWorkspace = true
                    }) {
                        Label("Add Workspace Directory", systemImage: "folder.badge.plus")
                    }
                }
            }
            .navigationTitle("Workspaces")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        isShowingAddWorkspace = true
                    }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Add Workspace", isPresented: $isShowingAddWorkspace) {
                TextField("~/Code/YourProject", text: $newWorkspacePath)
                    .autocapitalization(.none)
                Button("Cancel", role: .cancel) { newWorkspacePath = "" }
                Button("Add") {
                    guard !newWorkspacePath.isEmpty else { return }
                    let name = newWorkspacePath.components(separatedBy: "/").last ?? newWorkspacePath
                    let item = WorkspaceItem(name: name, path: newWorkspacePath, gitBranch: "main")
                    apiClient.workspaces.append(item)
                    apiClient.activeWorkspace = item
                    newWorkspacePath = ""
                }
            } message: {
                Text("Enter the absolute or relative path to a repository on your connected Harness host.")
            }
        }
    }
}

struct WorkspaceRow: View {
    let workspace: WorkspaceItem
    let isActive: Bool
    let onSelect: () -> Void
    let onNewSession: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundColor(isActive ? .accentColor : .secondary)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(workspace.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                        
                        if isActive {
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text(workspace.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: onNewSession) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.bubble.fill")
                        Text("Session")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            
            if let branch = workspace.gitBranch {
                HStack(spacing: 12) {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    if workspace.modifiedFilesCount > 0 {
                        Text("\(workspace.modifiedFilesCount) modified")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                    } else {
                        Text("Clean")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}
