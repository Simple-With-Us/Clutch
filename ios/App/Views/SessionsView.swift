import SwiftUI

public struct SessionsView: View {
    @State private var apiClient = HarnessAPIClient.shared
    @State private var connectionManager = HostConnectionManager.shared
    @State private var searchText: String = ""
    @State private var isShowingHostManager: Bool = false
    @Binding public var selectedTab: Int
    
    public init(selectedTab: Binding<Int>) {
        self._selectedTab = selectedTab
    }
    
    public var filteredSessions: [Session] {
        if searchText.isEmpty {
            return apiClient.sessions
        }
        return apiClient.sessions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.model.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    public var body: some View {
        NavigationStack {
            List {
                // Active host card
                Section {
                    Button(action: {
                        isShowingHostManager = true
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: connectionManager.activeHost?.status.icon ?? "laptopcomputer")
                                .font(.system(size: 22))
                                .foregroundColor(connectionManager.activeHost?.status == .online ? .green : .orange)
                            
                            VStack(alignment: .leading, spacing: 3) {
                                Text(connectionManager.activeHost?.name ?? "No Active Host")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.primary)
                                
                                Text("\(connectionManager.activeHost?.scheme ?? "http")://\(connectionManager.activeHost?.hostAndPort ?? "—")")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Connected Computer")
                }
                
                // Sessions list
                Section {
                    ForEach(filteredSessions) { session in
                        Button(action: {
                            apiClient.selectSession(session)
                            selectedTab = 0 // Navigate to Chat
                        }) {
                            SessionRowView(
                                session: session,
                                isSelected: apiClient.currentSession?.id == session.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let session = filteredSessions[index]
                            apiClient.deleteSession(session)
                        }
                    }
                } header: {
                    HStack {
                        Text("Sessions (\(filteredSessions.count))")
                        Spacer()
                        Button(action: {
                            _ = apiClient.createSession()
                            selectedTab = 0
                        }) {
                            Label("New", systemImage: "plus")
                                .font(.system(size: 12, weight: .bold))
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search sessions...")
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        _ = apiClient.createSession()
                        selectedTab = 0
                    }) {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $isShowingHostManager) {
                HostManagerSheet()
            }
        }
    }
}

struct SessionRowView: View {
    let session: Session
    let isSelected: Bool
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ModelLogoView(vendor: session.vendor, size: 18)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 15, weight: isSelected ? .bold : .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                }
                
                HStack(spacing: 8) {
                    Text(session.model)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    if let ws = session.workspacePath {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(ws.components(separatedBy: "/").last ?? ws)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Text(timeAgo(session.updatedAt))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    
    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
