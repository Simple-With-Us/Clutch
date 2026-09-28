import SwiftUI

public struct MainTabView: View {
    @State private var selectedTab: Int = 0
    @State private var isShowingSettings: Bool = false
    
    public init() {}
    
    public var body: some View {
        TabView(selection: $selectedTab) {
            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(0)
            
            SessionsView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Sessions", systemImage: "list.bullet.rectangle.portrait")
                }
                .tag(1)
            
            WorkspacesView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Workspaces", systemImage: "folder.fill")
                }
                .tag(2)
            
            ToolsView()
                .tabItem {
                    Label("Tools", systemImage: "wrench.and.screwdriver.fill")
                }
                .tag(3)
            
            WebParityView()
                .tabItem {
                    Label("Web", systemImage: "globe")
                }
                .tag(4)
        }
        .tint(.accentColor)
    }
}
