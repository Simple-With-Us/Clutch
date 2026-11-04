import SwiftUI

struct RootView: View {
    #if os(macOS)
    @State private var store = HostStore()
    #else
    @State private var store = HostStore.shared
    #endif
    @State private var selectedTab: Int = 0
    /// How the active host stands with this device.
    ///
    /// The native apps ask the sidecar, not the web origin, so this is the
    /// same gate the session list passes.  A host that needs pairing or
    /// cannot be reached gets a card over the app instead of an empty
    /// screen, which is what the web canvas used to draw for it.
    @State private var gate: HostGateState = .ready
    @State private var isShowingHosts = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let host = store.activeHost {
                tabs(for: host)
                    .sheet(isPresented: $isShowingHosts) {
                        HostsSheet(store: store)
                    }
                    .onAppear {
                        // The tab set depends on the host, so the selection
                        // is kept on a tab that exists.
                        selectedTab = HostTabs.clamp(selectedTab, for: host)
                    }
                    .onChange(of: host.id) { _, _ in
                        selectedTab = HostTabs.clamp(selectedTab, for: host)
                    }
                    .onChange(of: host.kind) { _, _ in
                        // A re-pair on the same origin can turn a web host
                        // into a code server without changing its id, so the
                        // kind is watched as well as the id.
                        selectedTab = HostTabs.clamp(selectedTab, for: host)
                    }
                    // The statuses and the gate are read separately: the
                    // probe of the web origin can take seconds, and the gate
                    // must not wait for it.
                    .task(id: host.pairingKey) {
                        await store.refreshStatuses()
                    }
                    .task(id: host.pairingKey) {
                        await checkGate(host)
                    }
                    .onChange(of: scenePhase) { _, phase in
                        // The host may have come back while the app was in the
                        // background, so the gate and the host statuses are
                        // read again when it comes forward.
                        guard phase == .active else { return }
                        Task {
                            await store.refreshStatuses()
                            await checkGate(host)
                        }
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

    @ViewBuilder
    private func tabs(for host: ClutchHost) -> some View {
        TabView(selection: $selectedTab) {
            #if os(macOS)
            gated(ChatView(activeHost: host, store: store, initialSurface: .workspace), host: host)
                .tabItem {
                    Label("Workspace", systemImage: "terminal.fill")
                }
                .tag(0)

            if !host.isMiniMaxCodeOnly {
                gated(ChatView(activeHost: host, store: store, initialSurface: .agent), host: host)
                    .tabItem {
                        Label("Agent Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    .tag(1)
            }
            #else
            gated(SessionsView(host: host), host: host)
                .tabItem {
                    Label("Workspace", systemImage: "terminal.fill")
                }
                .tag(0)

            gated(ChatView(activeHost: host, store: store), host: host)
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(1)
            #endif

            if !host.isMiniMaxCodeOnly {
                DshHostView(host: host)
                    .tabItem {
                        Label("Host", systemImage: "server.rack")
                    }
                    .tag(2)
            }

            FleetRecallView()
                .tabItem {
                    Label("Fleet Recall", systemImage: "sparkles.rectangle.stack.fill")
                }
                .tag(3)
        }
        .tint(.accentColor)
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 560)
        #endif
    }

    /// Puts the gate card in place of a surface that needs the sidecar.
    ///
    /// The Host tab and Fleet Recall do not go through the sidecar, so they
    /// stay reachable while it is down: the owner keeps the tabs that work
    /// and gets a card, not a dead end, on the ones that do not.
    ///
    /// The card replaces the surface rather than covering it.  A surface
    /// behind the card keeps asking a host that is down, so the owner would
    /// watch the workspace and the chat time out at once, and the picker on
    /// that surface would still say the host is online — the state the web
    /// canvas got wrong.
    @MainActor
    private func gated<Content: View>(_ content: Content, host: ClutchHost) -> some View {
        Group {
            if gate.isReady {
                content
            } else {
                HostGateView(
                    host: host,
                    store: store,
                    state: gate,
                    onRetry: { Task { await checkGate(host) } },
                    onSwitchHost: { isShowingHosts = true },
                    onPaired: { payload in store.pair(payload) }
                )
            }
        }
    }

    /// Asks the sidecar whether it will talk to this device.
    ///
    /// The check runs again whenever the pairing changes, so a host that was
    /// unreachable and then came back, or was paired afresh, opens on its own.
    @MainActor
    private func checkGate(_ host: ClutchHost) async {
        let state = await HostGate.check(host: host)
        // A check that was cancelled, or that belongs to a host the owner has
        // since left, must not answer for the host on screen.
        guard !Task.isCancelled, store.activeHost?.id == host.id else { return }
        gate = state
    }
}
