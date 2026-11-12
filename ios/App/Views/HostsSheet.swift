import SwiftUI

/// Hosts and app settings.
struct HostsSheet: View {
    let store: HostStore

    @Environment(\.dismiss) private var dismiss
    @AppStorage("clutch_theme_preference") private var themePreference: String = "light"
    @AppStorage(MacBusySendMode.storageKey) private var busySendModeRawValue = MacBusySendMode.defaultMode.rawValue
    @AppStorage(MuseLaunchPreferences.storageKey) private var museLaunchPreferencesJSON = ""
    @AppStorage(MuseContextPreferences.storageKey) private var museContextPreferencesJSON = ""
    @State private var isAddingHost = false

    private var busySendMode: MacBusySendMode {
        MacBusySendMode(rawValue: busySendModeRawValue) ?? .queue
    }

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
                        #if os(macOS)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.remove(host)
                            } label: {
                                Label("Forget Host", systemImage: "trash")
                            }
                        }
                        #else
                        .swipeActions {
                            Button(role: .destructive) {
                                store.remove(host)
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                        #endif
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
                        "Forget a host to sign this device out.",
                        "To pair, run \(Copy.pairCommand) in Terminal on the Mac or server host."
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $themePreference) {
                        Text("Light").tag("light")
                        Text("System").tag("system")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                #if os(macOS)
                Section("Messages While Working") {
                    Picker("Default Action", selection: $busySendModeRawValue) {
                        Text("Queue").tag(MacBusySendMode.queue.rawValue)
                        Text("Steer").tag(MacBusySendMode.steer.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Text(busySendMode.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Copy.gap(
                        "This sets the default action while a turn is running.",
                        "Choose another action for an individual message from the composer menu."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                #endif

                if let host = store.activeHost {
                    Section("Muse Code") {
                        Toggle(isOn: museOptionsBinding(host: host, keyPath: \.yolo)) {
                            Text("YOLO: Allow Changes Without Asking")
                        }
                        Text(Copy.gap(
                            "Muse can make changes and run commands without pausing for approval.",
                            "The host sandbox is disabled for that turn."
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Toggle(isOn: museOptionsBinding(host: host, keyPath: \.contributorMode)) {
                            Text("Contributor Mode")
                        }
                        Text("Muse uses contributor mode for new and resumed threads.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Copy.gap(
                            "Changes apply to your next Muse turn.",
                            "Finish other Muse turns before changing these settings."
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Toggle(isOn: contextPolicyBinding(host: host, keyPath: \.autoCompact)) {
                            Text("Compact Early Automatically")
                        }
                        HStack(spacing: 12) {
                            Text("Threshold")
                                .foregroundStyle(.secondary)
                            Slider(value: contextThresholdBinding(host: host), in: 50...95, step: 1)
                                .accessibilityLabel("Automatic Compaction Threshold")
                            Text("\(contextPolicy(host: host).thresholdPercent)%")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                        .disabled(!contextPolicy(host: host).autoCompact)
                        Text(Copy.gap(
                            "Clutch asks Muse to compact before your next message when reported context reaches this threshold.",
                            "Muse's own automatic compaction remains managed by Muse."
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                InfisicalSettingsSection(host: store.activeHost)

                Section("About") {
                    LabeledContent("Version", value: "\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
                    Text(Copy.gap(
                        "Clutch shows the clutch web UI running on your Mac or server host.",
                        "Models, sessions, and tools come from that host, so DeepSeek and MiniMax work as they do there."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Hosts and Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .formStyle(.grouped)
            .frame(minWidth: 560, idealWidth: 680, maxWidth: 820, minHeight: 480, idealHeight: 680)
            #endif
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

    private func museOptionsBinding(
        host: ClutchHost,
        keyPath: WritableKeyPath<MuseLaunchOptions, Bool>
    ) -> Binding<Bool> {
        let hostKey = host.id.uuidString
        return Binding(
            get: {
                MuseLaunchPreferences.options(
                    hostKey: hostKey,
                    preferencesJSON: museLaunchPreferencesJSON
                )[keyPath: keyPath]
            },
            set: { enabled in
                var options = MuseLaunchPreferences.options(
                    hostKey: hostKey,
                    preferencesJSON: museLaunchPreferencesJSON
                )
                options[keyPath: keyPath] = enabled
                museLaunchPreferencesJSON = MuseLaunchPreferences.setting(
                    options,
                    hostKey: hostKey,
                    preferencesJSON: museLaunchPreferencesJSON
                )
            }
        )
    }

    private func contextPolicy(host: ClutchHost) -> MuseContextPolicy {
        MuseContextPreferences.policy(
            hostKey: host.id.uuidString,
            preferencesJSON: museContextPreferencesJSON
        )
    }

    private func contextPolicyBinding(
        host: ClutchHost,
        keyPath: WritableKeyPath<MuseContextPolicy, Bool>
    ) -> Binding<Bool> {
        let hostKey = host.id.uuidString
        return Binding(
            get: { contextPolicy(host: host)[keyPath: keyPath] },
            set: { enabled in
                var policy = contextPolicy(host: host)
                policy[keyPath: keyPath] = enabled
                museContextPreferencesJSON = MuseContextPreferences.setting(
                    policy,
                    hostKey: hostKey,
                    preferencesJSON: museContextPreferencesJSON
                )
            }
        )
    }

    private func contextThresholdBinding(host: ClutchHost) -> Binding<Double> {
        let hostKey = host.id.uuidString
        return Binding(
            get: { Double(contextPolicy(host: host).thresholdPercent) },
            set: { value in
                var policy = contextPolicy(host: host)
                policy.thresholdPercent = MuseContextPolicy.clampedThreshold(Int(value.rounded()))
                museContextPreferencesJSON = MuseContextPreferences.setting(
                    policy,
                    hostKey: hostKey,
                    preferencesJSON: museContextPreferencesJSON
                )
            }
        )
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
                HStack(spacing: 6) {
                    Text(host.name)
                        .font(.body.weight(.semibold))
                    if host.isMiniMaxCodeOnly {
                        Text(host.kindLabel)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.clutchSecondaryBackground, in: Capsule())
                    }
                }
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

/// The app's own version, read from its bundle.
///
/// The web view carried this with it when the canvas went; the settings
/// sheet is the one surface that shows the version, so the helper lives
/// here now.
extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    var buildNumber: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }
}
