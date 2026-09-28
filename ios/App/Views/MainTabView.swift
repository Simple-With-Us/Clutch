import SwiftUI

public struct MainTabView: View {
    @State private var selectedTab: Int = 0

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(0)

            ToolsView()
                .tabItem {
                    Label("Tools", systemImage: "wrench.and.screwdriver.fill")
                }
                .tag(1)

            SessionsView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Sessions", systemImage: "list.bullet.rectangle.portrait")
                }
                .tag(2)

            FleetRAGView()
                .tabItem {
                    Label("Fleet RAG", systemImage: "sparkles.rectangle.stack.fill")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(4)
        }
        .tint(.accentColor)
    }
}
