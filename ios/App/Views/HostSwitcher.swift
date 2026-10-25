import SwiftUI

/// The server picker, shared by every surface that answers to a host.
///
/// Picking a server is something a person does from wherever they are, so
/// the picker belongs in each surface's toolbar rather than in one of them.
/// The phone's chat, thread and host surfaces and the Mac's chat surface all
/// show this one control, so the Mac has no second copy to drift.
public struct HostSwitcher: View {
    let host: ClutchHost
    let store: HostStore
    /// Whether the label is sized for a header strip rather than a toolbar.
    let compact: Bool

    /// The sheet the picker can open.
    private enum Sheet: String, Identifiable {
        case addHost
        case hosts
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?

    public init(host: ClutchHost, store: HostStore, compact: Bool = false) {
        self.host = host
        self.store = store
        self.compact = compact
    }

    public var body: some View {
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
                sheet = .addHost
            } label: {
                Label("Add Host", systemImage: "plus")
            }
            Button {
                sheet = .hosts
            } label: {
                Label("Hosts and Settings", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
                Text(host.name)
                    .font(compact ? .system(size: 11, weight: .semibold) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(compact ? .system(size: 8, weight: .bold) : .caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Host: \(host.name)")
        // One sheet, not two: SwiftUI honours only the last sheet modifier on
        // a view, so the picker picks which one to present.
        .sheet(item: $sheet) { item in
            switch item {
            case .addHost:
                NavigationStack {
                    PairView(showsIntro: false) { payload in
                        store.pair(payload)
                    }
                }
            case .hosts:
                HostsSheet(store: store)
            }
        }
    }

    /// The host's probe result, as one colour.
    private var statusColor: Color {
        switch host.status {
        case .online: return .green
        case .notClutch: return .orange
        case .offline: return .red
        case .unknown: return .gray
        }
    }
}
