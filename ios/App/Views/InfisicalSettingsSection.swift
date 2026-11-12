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
                "Token values are sent to the paired Mac for storage and are never returned after saving."
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
            credentialsRows(model)
            managedSettingsRows(model)
        }
    }

    private var hostUnavailableText: String {
        Copy.gap(
            "Pair a Mac to manage Infisical settings.",
            "This section reads and writes that Mac's service tokens and managed settings."
        )
    }

    // MARK: - Source

    @ViewBuilder
    private func sourceRows(_ model: InfisicalSettingsModel) -> some View {
        if let snapshot = model.snapshot {
            LabeledContent("Source") {
                Text(snapshot.source.label)
            }
            .accessibilityLabel(Text("Infisical settings source, \(snapshot.source.label)"))

            if let path = snapshot.credentialsPath, !path.isEmpty {
                LabeledContent("Credentials File") {
                    Text(path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text("Service-token file, \(path)"))
            }

            if snapshot.credentials.readTokenFromEnv || snapshot.credentials.writeTokenFromEnv {
                Label {
                    Text(Copy.gap(
                        "A service token is coming from the Mac's environment.",
                        "Environment tokens take precedence over the credentials file."
                    ))
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
                    "Clutch must restart on the Mac to use the new service tokens.",
                    "Managed settings stay locked until you restart it and reload here."
                ))
                .font(.footnote)
            } icon: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
            }
            .accessibilityLabel(Text("Clutch must restart on the Mac to use the new service tokens"))
        }
    }

    // MARK: - Service tokens

    @ViewBuilder
    private func credentialsRows(_ model: InfisicalSettingsModel) -> some View {
        subheading("Service Tokens", symbol: "key.horizontal")

        TextField("Project ID", text: $model.projectId)
            .identifierField()
            .accessibilityLabel(Text("Infisical Project ID"))

        SecureField(model.readTokenPlaceholder, text: $model.readToken)
            .identifierField()
            .accessibilityLabel(Text("Infisical Read Service Token"))

        Text(model.hasStoredReadToken
             ? Copy.gap("A read-only service token is available on the Mac.", "Leave empty to keep it.")
             : "No read service token is available on the Mac yet.")
            .font(.footnote)
            .foregroundStyle(.secondary)

        SecureField(model.writeTokenPlaceholder, text: $model.writeToken)
            .identifierField()
            .accessibilityLabel(Text("Infisical Write Service Token"))

        Text(model.hasStoredWriteToken
             ? Copy.gap("A separate write service token is available on the Mac.", "Leave empty to keep it.")
             : Copy.gap("A separate write token is required for managed-setting edits.", "Reads never use write access."))
            .font(.footnote)
            .foregroundStyle(.secondary)

        if model.hasStoredWriteToken {
            Toggle("Remove Separate Write Token", isOn: $model.clearWriteToken)
                .accessibilityLabel(Text("Remove Separate Write Token"))
        }

        Button {
            Task { await model.saveCredentials() }
        } label: {
            if model.isSavingCredentials {
                Label("Saving Service Tokens", systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label("Save Service Tokens", systemImage: "checkmark.circle")
            }
        }
        .disabled(!model.canSaveCredentials)
        .accessibilityLabel(Text("Save Service Tokens"))
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
            if model.snapshot?.credentials.hasWriteToken != true {
                Label("Add a separate write service token to edit managed settings.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
            return Copy.gap(
                "A value is saved on the Mac.",
                "Clutch never shows a stored secret, so enter a new one to replace it."
            )
        }
        return Copy.gap(
            "No value is set on this Mac.",
            "Leave it empty to keep it that way — saving an empty secret would clear it."
        )
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
