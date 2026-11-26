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
    @State private var isShowingProjects = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let host = store.activeHost {
                #if os(macOS)
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
                #else
                // The phone has no tab bar: one surface, one detail.  The
                // Host console and Fleet Recall live in Hosts and Settings,
                // reachable from the home list's gear.
                gated(SessionsView(host: host, onShowProjects: { isShowingProjects = true }), host: host)
                    .sheet(isPresented: $isShowingHosts) {
                        HostsSheet(store: store)
                    }
                    .onAppear {
                        // Keep the shared selection state valid even though
                        // nothing reads it on this platform.
                        selectedTab = HostTabs.clamp(selectedTab, for: host)
                    }
                    .task(id: host.pairingKey) {
                        await store.refreshStatuses()
                    }
                    .task(id: host.pairingKey) {
                        await checkGate(host)
                    }
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        Task {
                            await store.refreshStatuses()
                            await checkGate(host)
                        }
                        // The engines may have worked while the app was
                        // away, so the island and the Lock Screen count are
                        // republished when the app comes forward.
                        ClutchActivityController.shared.refresh()
                    }
                #endif
            } else {
                PairView { payload in
                    store.pair(payload)
                }
            }
        }
        .sheet(isPresented: $isShowingProjects) {
            ThreadProjectsView(hosts: store)
        }
        .onOpenURL { url in
            if let link = ThreadLink.parse(url) {
                // A link that names a thread opens that thread, and the host
                // it belongs to when the link names one.
                if let hostId = link.hostId,
                   let host = store.hosts.first(where: { $0.id == hostId }) {
                    store.activate(host)
                }
                ThreadLinkRouter.shared.request(link)
            } else if ClutchApprovalsLink.matches(url) {
                // A link that names the approvals list opens that list: it
                // is what the Live Activity and the Control Center action
                // use, so the way back into the app is one shape.
                ApprovalsLinkRouter.shared.request()
            } else if case .success(let payload) = PairingLink.parse(url.absoluteString) {
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
                        Label("Quick Chat", systemImage: "bubble.left.and.bubble.right.fill")
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                projectsButton
            }
        }
        #endif
    }

    /// Puts the gate card over a surface that needs the sidecar.
    ///
    /// The Host tab and Fleet Recall do not go through the sidecar, so they
    /// stay reachable while it is down: the owner keeps the tabs that work
    /// and gets a card, not a dead end, on the ones that do not.
    ///
    /// The card is an overlay rather than a replacement now.  Swapping the
    /// surface out used to destroy the open thread's draft and scroll
    /// position whenever a 10-second health check timed out on foreground —
    /// the exact moment a sleeping Mac makes that likely.  The surface stays
    /// mounted underneath, and the card covers it fully, so nothing behind
    /// it can be tapped while the host is down.
    @MainActor
    private func gated<Content: View>(_ content: Content, host: ClutchHost) -> some View {
        ZStack {
            content
            if !gate.isReady {
                HostGateView(
                    host: host,
                    store: store,
                    state: gate,
                    onRetry: { Task { await checkGate(host) } },
                    onSwitchHost: { isShowingHosts = true },
                    onPaired: { payload in store.pair(payload) }
                )
                .safeAreaInset(edge: .bottom) {
                    // A sleeping active host must not hide projects on other hosts.
                    projectsButton.padding(12)
                }
                .transition(.opacity)
            }
        }
    }

    private var projectsButton: some View {
        Button { isShowingProjects = true } label: {
            Label("Projects", systemImage: "folder.badge.plus")
        }
        .accessibilityLabel("Projects")
        .accessibilityIdentifier("clutch-projects")
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
