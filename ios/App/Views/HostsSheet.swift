import SwiftUI

/// Hosts and app settings.
struct HostsSheet: View {
    let store: HostStore

    @Environment(\.dismiss) private var dismiss
    @AppStorage("clutch_theme_preference") private var themePreference: String = "light"
    @State private var isAddingHost = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.hosts) { host in
                        Button {
                            store.activate(host)
                            dismiss()
                        } label: {
                            HostRow(host: host, isActive: host.id == store.activeHost?.id)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                store.remove(host)
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }
                    Button {
                        isAddingHost = true
                    } label: {
                        Label("Add Host", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Hosts")
                } footer: {
                    Text(Copy.gap(
                        "Swipe a host to forget it and sign this device out.",
                        "To pair, run \(Copy.pairCommand) in Terminal on the Mac."
                    ))
                }

                Section("Appearance") {
                    Picker("Theme", selection: $themePreference) {
                        Text("Light").tag("light")
                        Text("System").tag("system")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section("About") {
                    LabeledContent("Version", value: "\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
                    Text(Copy.gap(
                        "Clutch shows the clutch web UI running on your Mac.",
                        "Models, sessions, and tools come from that Mac, so DeepSeek and MiniMax work exactly as they do on the desktop."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Hosts and Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await store.refreshStatuses() }
            .navigationDestination(isPresented: $isAddingHost) {
                PairView(showsIntro: false) { payload in
                    store.pair(payload)
                    dismiss()
                }
                .padding(.top, 16)
                .navigationTitle("Add Host")
            }
        }
    }
}

private struct HostRow: View {
    let host: ClutchHost
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: host.status.symbol)
                .foregroundStyle(color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.body.weight(.semibold))
                Text(host.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(host.status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .font(.body.weight(.semibold))
            }
        }
        .contentShape(Rectangle())
    }

    private var color: Color {
        switch host.status {
        case .online: return .green
        case .notClutch: return .orange
        case .offline: return .red
        case .unknown: return .secondary
        }
    }
}
