import SwiftUI

/// First run shows pairing; after that the active host's harness web UI.
struct RootView: View {
    @State private var store = HostStore.shared

    var body: some View {
        Group {
            if let host = store.activeHost {
                HarnessScreen(host: host, store: store)
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

/// The main surface: harness web for the active host, a slim native toolbar
/// (host switcher, reload, hosts and settings), and native overlays for the
/// pairing-expired and unreachable states.
struct HarnessScreen: View {
    let host: HarnessHost
    let store: HostStore

    @Environment(\.scenePhase) private var scenePhase
    @State private var webState: WebSurfaceState = .loading
    @State private var isShowingHosts = false
    @State private var isShowingAddHost = false

    var body: some View {
        NavigationStack {
            ZStack {
                HarnessWebView(
                    host: host,
                    loadKey: "\(host.id.uuidString)#\(store.loadGeneration)",
                    state: $webState,
                    onAuthenticated: { store.consumeLaunchToken(for: $0) }
                )
                .ignoresSafeArea(.container, edges: .bottom)
                .ignoresSafeArea(.keyboard)

                overlay
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { hostMenu }
                ToolbarItemGroup(placement: .topBarTrailing) {
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
            }
            .sheet(isPresented: $isShowingHosts) {
                HostsSheet(store: store)
            }
            .sheet(isPresented: $isShowingAddHost) {
                NavigationStack {
                    PairView(showsIntro: false) { payload in
                        store.pair(payload)
                        isShowingAddHost = false
                    }
                    .padding(.top, 16)
                    .navigationTitle("Add Host")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isShowingAddHost = false }
                        }
                    }
                }
            }
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

    private var hostMenu: some View {
        Menu {
            ForEach(store.hosts) { candidate in
                Button {
                    store.activate(candidate)
                } label: {
                    if candidate.id == host.id {
                        Label(candidate.name, systemImage: "checkmark")
                    } else {
                        Text(candidate.name)
                    }
                }
            }
            Divider()
            Button {
                isShowingAddHost = true
            } label: {
                Label("Add Host", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(host.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Host: \(host.name)")
    }

    private var statusColor: Color {
        switch webState {
        case .ready: return .green
        case .loading: return host.status == .offline ? .orange : .gray
        case .needsPairing: return .orange
        case .failed: return .red
        }
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
                    "Make sure Tailscale is connected on this device and harness is running on the Mac.",
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
        .background(Color(.systemBackground))
    }
}
