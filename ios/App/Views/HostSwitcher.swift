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
    /// The state to show, when the surface knows better than the probe does.
    let status: HostStatus?

    /// The sheet the picker can open.
    private enum Sheet: String, Identifiable {
        case addHost
        case hosts
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?

    public init(
        host: ClutchHost,
        store: HostStore,
        compact: Bool = false,
        status: HostStatus? = nil
    ) {
        self.host = host
        self.store = store
        self.compact = compact
        self.status = status
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
                        // Every other host carries its reachability, so the
                        // picker shows which ones can actually answer.
                        Label(candidate.name, systemImage: candidate.status.symbol)
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
                // Status is a symbol in a status colour, never colour
                // alone: the shape still reads in grayscale, and the
                // accessibility value below says the word out loud.
                Image(systemName: shownStatus.symbol)
                    .font(compact ? ClutchFont.microStrong : ClutchFont.captionStrong)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                Text(host.name)
                    .font(compact ? ClutchFont.captionStrong : .subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(ClutchFont.microStrong)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
        .accessibilityLabel("Host: \(host.name)")
        .accessibilityValue(shownStatus.label)
        // One sheet, not two: SwiftUI honours only the last sheet modifier on
        // a view, so the picker picks which one to present.
        .sheet(item: $sheet) { item in
            if item == .addHost {
                NavigationStack {
                    PairView(showsIntro: false) { payload in
                        store.pair(payload)
                        sheet = nil
                    }
                    .padding(.top, 16)
                    .navigationTitle("Add Host")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            // A Mac sheet has no way out without this.
                            Button("Cancel") { sheet = nil }
                        }
                    }
                }
            } else {
                HostsSheet(store: store)
            }
        }
    }

    /// The state on show: the surface's word when it has one, else the probe's.
    private var shownStatus: HostStatus { status ?? host.status }

    /// The host's probe result, in the contrast-tuned status colours.
    private var statusColor: Color {
        switch shownStatus {
        case .online: return ClutchColor.success
        case .notClutch: return ClutchColor.warning
        case .offline: return ClutchColor.danger
        case .unknown: return ClutchColor.textTertiary
        }
    }
}
