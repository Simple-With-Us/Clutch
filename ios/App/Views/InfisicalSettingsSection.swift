import SwiftUI

/// The Infisical panel inside the "Hosts and Settings" sheet.
///
/// One section, both platforms: this file is compiled into the iOS and macOS
/// targets, so it sticks to SwiftUI primitives that behave the same in a Form
/// on each.  All load and save state lives in `InfisicalSettingsModel`; this
/// view only presents it.
struct InfisicalSettingsSection: View {
    @State private var model: InfisicalSettingsModel

    init(host: ClutchHost?) {
        _model = State(initialValue: InfisicalSettingsModel(host: host))
    }

    var body: some View {
        @Bindable var model = model

        Section {
            content(model)
        } header: {
            Text("Infisical")
        } footer: {
            Text(Copy.gap(
                "Infisical is the source of truth for Clutch's settings on the Mac.",
                "Secret values never leave the Mac and are never shown here."
            ))
        }
        .task { await model.loadIfNeeded() }
    }

    // MARK: - Loading and failure

    @ViewBuilder
    private func content(_ model: InfisicalSettingsModel) -> some View {
        if !model.hasHost {
            Text(hostUnavailableText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(hostUnavailableText))
        } else if model.isLoading && model.snapshot == nil {
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading Infisical settings…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text("Loading Infisical settings"))
        } else if let message = model.loadErrorText, model.snapshot == nil {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(message)
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel(Text("Try loading Infisical settings again"))
            }
        } else {
            sourceRows(model)
            identityRows(model)
            managedSettingsRows(model)
        }
    }

    private var hostUnavailableText: String {
        "Pair a Mac to manage Infisical settings.  This section reads and writes that Mac's Infisical identity and managed settings."
    }

    // MARK: - Source

    @ViewBuilder
    private func sourceRows(_ model: InfisicalSettingsModel) -> some View {
        if let snapshot = model.snapshot {
            LabeledContent("Source") {
                Text(snapshot.source.label)
            }
            .accessibilityLabel(Text("Infisical settings source, \(snapshot.source.label)"))

            if let path = snapshot.identityPath, !path.isEmpty {
                LabeledContent("Identity File") {
                    Text(path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text("Machine identity file, \(path)"))
            }

            if snapshot.identity.fromEnv {
                Label {
                    Text("The machine identity is coming from the Mac's environment.  Saving a change here writes the identity file, which the environment still overrides.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await model.reload() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel(Text("Reload Infisical settings from the Mac"))
        }

        if model.needsRestart {
            Label {
                Text(Copy.gap(
                    "Clutch must restart on the Mac to use the new credentials.",
                    "Managed settings stay locked until you restart it and reload here."
                ))
                .font(.footnote)
            } icon: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
            }
            .accessibilityLabel(Text("Clutch must restart on the Mac to use the new credentials"))
        }
    }

    // MARK: - Machine identity

    @ViewBuilder
    private func identityRows(_ model: InfisicalSettingsModel) -> some View {
        subheading("Machine Identity", symbol: "key.horizontal")

        TextField("Project ID", text: $model.projectId)
            .identifierField()
            .accessibilityLabel(Text("Infisical Project ID"))

        TextField("Client ID", text: $model.clientId)
            .identifierField()
            .accessibilityLabel(Text("Infisical Client ID"))
            .accessibilityValue(Text(clientIDAccessibilityValue(model)))

        // The stored secret is never loaded into the app, so this field only
        // ever holds what the operator typed this session.
        SecureField(model.clientSecretPlaceholder, text: $model.clientSecret)
            .identifierField()
            .accessibilityLabel(Text("Infisical Client Secret"))

        Text(clientSecretHelpText(model))
            .font(.footnote)
            .foregroundStyle(.secondary)

        Button {
            Task { await model.saveIdentity() }
        } label: {
            if model.isSavingIdentity {
                Label("Saving Machine Identity", systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label("Save Machine Identity", systemImage: "checkmark.circle")
            }
        }
        .disabled(!model.canSaveIdentity)
        .accessibilityLabel(Text("Save Machine Identity"))
    }

    private func clientIDAccessibilityValue(_ model: InfisicalSettingsModel) -> String {
        guard let hint = model.identity?.clientIdHint, !hint.isEmpty else { return "Not set" }
        return "Ending in \(hint)"
    }

    private func clientSecretHelpText(_ model: InfisicalSettingsModel) -> String {
        model.hasStoredClientSecret
            ? "A client secret is saved on the Mac.  Leave this empty to keep it."
            : "No client secret is saved on the Mac yet."
    }

    // MARK: - Managed settings

    @ViewBuilder
    private func managedSettingsRows(_ model: InfisicalSettingsModel) -> some View {
        subheading("Managed Settings", symbol: "slider.horizontal.3")

        let keys = model.snapshot?.keys ?? []
        if keys.isEmpty {
            Text("This Mac reports no managed settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Picker("Setting", selection: selectionBinding(model)) {
                ForEach(keys) { entry in
                    Text(entry.key).tag(entry.key)
                }
            }
            .accessibilityLabel(Text("Managed setting to edit"))

            if let entry = model.selectedSetting {
                settingDescriptionRow(entry)

                if entry.kind.showsStoredValue {
                    TextField("Value", text: $model.settingValue)
                        .identifierField()
                        .accessibilityLabel(Text("Value for \(entry.key)"))
                } else {
                    SecureField(model.secretValuePlaceholder(for: entry), text: $model.settingValue)
                        .identifierField()
                        .accessibilityLabel(Text("Value for \(entry.key)"))
                }

                Text(valueHelpText(entry))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await model.saveSetting() }
                } label: {
                    if model.isSavingSetting {
                        Label("Saving Setting", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Save Setting", systemImage: "checkmark.circle")
                    }
                }
                .disabled(!model.canSaveSetting)
                .accessibilityLabel(Text("Save \(entry.key)"))
            }
        }
    }

    private func selectionBinding(_ model: InfisicalSettingsModel) -> Binding<String> {
        Binding(
            get: { model.selectedKey },
            set: { model.selectSetting($0) }
        )
    }

    @ViewBuilder
    private func settingDescriptionRow(_ entry: InfisicalManagedKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(entry.description)
                    .font(.footnote)
            } icon: {
                Image(systemName: entry.kind.symbol)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(entry.kind.label)
                Text("·")
                Text(entry.isSet ? "Set on this Mac" : "Not set")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(entry.key), \(entry.kind.label), \(entry.isSet ? "set" : "not set")"))
    }

    private func valueHelpText(_ entry: InfisicalManagedKey) -> String {
        if entry.kind.showsStoredValue {
            return "Saving writes this value to Infisical and updates the Mac's settings cache."
        }
        if entry.isSet {
            return "A value is saved on the Mac.  Clutch never shows a stored secret, so enter a new one to replace it."
        }
        return "No value is set on this Mac.  Leave it empty to keep it that way — saving an empty secret would clear it."
    }

    // MARK: - Shared

    private func subheading(_ title: String, symbol: String) -> some View {
        Label {
            Text(title)
                .font(.footnote.weight(.semibold))
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Field hygiene for the identifier-shaped text in this section.
///
/// `textInputAutocapitalization` exists only on iOS, and this file is compiled
/// into the macOS target as well, so the modifier is applied where SwiftUI has
/// it rather than dropped everywhere.
private extension View {
    @ViewBuilder
    func identifierField() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}