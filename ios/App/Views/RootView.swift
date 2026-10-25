import SwiftUI

struct RootView: View {
    @State private var store = HostStore.shared
    @State private var selectedTab: Int = 0

    var body: some View {
        Group {
            if let host = store.activeHost {
                TabView(selection: $selectedTab) {
                    ChatView(activeHost: host, store: store)
                        .tabItem {
                            Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                        }
                        .tag(0)

                    SessionsView(host: host)
                        .tabItem {
                            Label("Code", systemImage: "terminal.fill")
                        }
                        .tag(1)

                    if !host.isMiniMaxCodeOnly {
                        ClutchScreen(host: host, store: store)
                            .tabItem {
                                Label("Web Canvas", systemImage: "macwindow")
                            }
                            .tag(2)

                        DshHostView(host: host)
                            .tabItem {
                                Label("Host", systemImage: "server.rack")
                            }
                            .tag(3)
                    }

                    FleetRecallView()
                        .tabItem {
                            Label("Fleet Recall", systemImage: "sparkles.rectangle.stack.fill")
                        }
                        .tag(4)
                }
                .tint(.accentColor)
                .onAppear {
                    // A MiniMax Code server host has no chat relay or web
                    // canvas behind it; land on its threads, not an empty
                    // agent chat.
                    if host.isMiniMaxCodeOnly, selectedTab == 0 { selectedTab = 1 }
                }
            } else {
                PairView { payload in
                    store.pair(payload)
                }
            }
        }
        .onOpenURL { url in
            if case .success(let payload) = PairingLink.parse(url.absoluteString) {
                store.pair(payload)
            }
        }
    }
}

/// The main surface: clutch web for the active host, a slim native toolbar
/// (host switcher, reload, hosts and settings), and native overlays for the
/// pairing-expired and unreachable states.
struct ClutchScreen: View {
    let host: ClutchHost
    let store: HostStore

    @Environment(\.scenePhase) private var scenePhase
    @State private var webState: WebSurfaceState = .loading
    @State private var isShowingHosts = false
    @State private var isShowingSessions = false

    var body: some View {
        NavigationStack {
            ZStack {
                ClutchWebView(
                    host: host,
                    loadKey: "\(host.id.uuidString)#\(store.loadGeneration)",
                    state: $webState,
                    onAuthenticated: { store.consumeLaunchToken(for: $0) }
                )
                .ignoresSafeArea(.container, edges: .bottom)
                #if os(iOS)
                .ignoresSafeArea(.keyboard)
                #endif

                overlay
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) { hostMenu }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    toolbarButtons
                }
                #else
                ToolbarItem(placement: .navigation) { hostMenu }
                ToolbarItemGroup(placement: .primaryAction) {
                    toolbarButtons
                }
                #endif
            }
            .sheet(isPresented: $isShowingHosts) {
                HostsSheet(store: store)
            }
            #if os(iOS)
            .sheet(isPresented: $isShowingSessions) {
                SessionsView(host: host)
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            if case .failed = webState { store.requestReload() }
            Task { await store.refreshStatuses() }
        }
        .task(id: host.id) {
            await store.refreshStatuses()
        }
    }

    @ViewBuilder
    private var toolbarButtons: some View {
        #if os(iOS)
        // The Mac app already reaches MiniMax Code threads through its own
        // sidebar; the phone had no way in without dropping to the web view.
        Button {
            isShowingSessions = true
        } label: {
            Image(systemName: "list.bullet.rectangle")
        }
        .accessibilityLabel("Sessions")
        #endif
        Button {
            store.requestReload()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .accessibilityLabel("Reload")
        Button {
            isShowingHosts = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Hosts and Settings")
    }

    private var hostMenu: some View {
        HostSwitcher(host: host, store: store)
    }

    @ViewBuilder
    private var overlay: some View {
        switch webState {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        case .ready:
            EmptyView()
        case .needsPairing:
            StateCard(
                symbol: "key.horizontal",
                title: "Pair This Device",
                message: Copy.gap(
                    "\(host.name) needs a fresh pairing code.",
                    "On the Mac, run \(Copy.pairCommand) and scan the code, or paste the link it copies."
                )
            ) {
                PairingActions { payload in
                    store.pair(payload)
                }
            }
        case .failed(let reason):
            StateCard(
                symbol: "wifi.exclamationmark",
                title: "Cannot Reach \(host.name)",
                message: Copy.gap(
                    "Make sure Tailscale is connected on this device and clutch is running on the Mac.",
                    reason
                )
            ) {
                VStack(spacing: 12) {
                    Button {
                        store.requestReload()
                    } label: {
                        Text("Try Again").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button {
                        isShowingHosts = true
                    } label: {
                        Text("Switch Host").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
    }
}

/// Full-screen native card covering the web view for non-ready states.
struct StateCard<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.tint)
                    .padding(.top, 48)
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                actions()
                    .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color.clutchBackground)
    }
}
