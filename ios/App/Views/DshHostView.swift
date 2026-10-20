import SwiftUI

/// The native surface of the dsh host.
///
/// Clutch's web tab is the upstream `dsh web` browser UI inside a WebView.
/// This tab is the other kind of client: it speaks the dsh host's own
/// contract over HTTP and the WebSocket mux, with no WebView and no embedded
/// JavaScript engine.  It is the same client core the iOS and macOS apps
/// share, so a native app on either platform reaches the host the same way.
///
/// The view is deliberately plain: connect, call one endpoint, read the
/// answer.  A native rendering of the host's own UI is the next slice, and it
/// builds on this rather than replacing it.
struct DshHostView: View {
    let host: ClutchHost

    @State private var client = DshHostClient()
    @State private var endpoint: String = "remote.session"
    @State private var resultText: String = ""
    @State private var errorMessage: String?
    @State private var isCalling = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    LabeledContent("Name", value: host.name)
                    LabeledContent("Address", value: host.address)
                    LabeledContent("State", value: stateLabel)
                    Button {
                        Task { await connect() }
                    } label: {
                        Text(client.state == .connected ? "Reconnect" : "Connect")
                    }
                    .disabled(isBusy)
                }

                Section("Call") {
                    TextField("Endpoint", text: $endpoint)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .font(.body.monospaced())
                    Button {
                        Task { await call() }
                    } label: {
                        if isCalling {
                            ProgressView()
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(isBusy || endpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .font(.body)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                if !resultText.isEmpty {
                    Section("Result") {
                        Text(resultText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section("Events") {
                    LabeledContent("Received", value: String(client.events.count))
                }
            }
            .navigationTitle("Host")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task(id: host.id) {
                await connect()
            }
        }
    }

    // MARK: - Actions

    private func connect() async {
        errorMessage = nil
        resultText = ""
        await client.connect(to: host)
        if case .failed(let reason) = client.state {
            errorMessage = reason
        }
    }

    private func call() async {
        let target = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        isCalling = true
        errorMessage = nil
        defer { isCalling = false }
        do {
            let value = try await client.call(method: target)
            resultText = Self.describe(value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Presentation

    private var isBusy: Bool {
        switch client.state {
        case .connecting, .connected: return false
        case .disconnected, .failed: return false
        }
    }

    private var stateLabel: String {
        switch client.state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .failed: return "Failed"
        }
    }

    /// Render a host value as readable text.
    ///
    /// The host's answers are JSON, and a native client shows them as JSON:
    /// reformatting them into prose would hide exactly the structure a caller
    /// is reading.
    private static func describe(_ value: DshJSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return String(describing: value) }
        guard let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return text
    }
}
