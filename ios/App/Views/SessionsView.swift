import SwiftUI

/// Native session list for the sidecar's MiniMax Code threads, as a real
/// sidebar rather than a sheet: on iPad the rail stays beside the transcript,
/// and on iPhone the same split view collapses into a push.  The Mac chat
/// surface ships the identical list in `ThreadSidebar`, and both order and
/// render rows through the same `AcpSessionInfo.newestFirst` and
/// `ThreadSidebarRow`, so a thread looks the same on every platform.
@MainActor
@Observable
final class SessionsModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded([AcpSessionInfo])
        case failed(String)
    }

    private let host: ClutchHost
    private let client: SessionsClient

    var phase: Phase = .idle

    init(host: ClutchHost) {
        self.host = host
        self.client = SessionsClient(host: host)
    }

    func load() async {
        guard phase != .loading else { return }
        phase = .loading
        do {
            // Newest first, with an unparseable stamp sinking below the dated
            // rows instead of scrambling the list.
            phase = .loaded(AcpSessionInfo.newestFirst(try await client.list()))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Pull-to-refresh keeps the old list on screen while reloading, so a slow
    /// sidecar does not blank a thread the user is reading.
    func refresh() async {
        let previous = phase
        if case .loading = previous { return }
        await load()
    }

    var sessions: [AcpSessionInfo] {
        if case .loaded(let sessions) = phase { return sessions }
        return []
    }
}

public struct SessionsView: View {
    let host: ClutchHost
    @State private var model: SessionsModel
    @State private var selectedId: String?
    @State private var isStartingThread = false

    public init(host: ClutchHost) {
        self.host = host
        _model = State(initialValue: SessionsModel(host: host))
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task { await model.load() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Group {
            if let message = failureText {
                ContentUnavailableView {
                    Label("Couldn't Load Threads", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                }
            } else if model.sessions.isEmpty {
                // Hold the spinner only for the first load.  A refresh over an
                // empty list should land on the empty state, not spin forever,
                // and a refresh with rows on screen keeps those rows visible.
                if isInitialLoad {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Threads Yet",
                        systemImage: "text.bubble",
                        description: Text("Start One With The Button Above.")
                    )
                }
            } else {
                threadList
            }
        }
        .navigationTitle("Threads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selectedId = nil
                    isStartingThread = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New Thread")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh Threads")
            }
        }
        .sheet(isPresented: $isStartingThread) {
            NewThreadSheet(host: host) { created in
                isStartingThread = false
                Task {
                    await model.refresh()
                    selectedId = created.sessionId
                }
            }
        }
    }

    private var threadList: some View {
        List(selection: $selectedId) {
            ForEach(AcpSessionInfo.newestFirst(model.sessions)) { session in
                ThreadSidebarRow(
                    session: session,
                    isSelected: session.sessionId == selectedId,
                    isLoading: false,
                    isDisabled: false,
                    onSelect: { selectedId = $0.sessionId }
                )
                .tag(session.sessionId)
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let session = selectedSession {
            SessionThreadView(host: host, session: session)
        } else {
            ContentUnavailableView(
                "Select A Thread",
                systemImage: "text.bubble",
                description: Text("Pick a thread from the sidebar, or start a new one.")
            )
        }
    }

    private var selectedSession: AcpSessionInfo? {
        guard let selectedId else { return nil }
        return model.sessions.first { $0.sessionId == selectedId }
    }

    /// The load error, if the last attempt failed.
    private var failureText: String? {
        if case .failed(let message) = model.phase { return message }
        return nil
    }

    /// True only while the first fetch is still outstanding; a reload keeps the
    /// previous list on screen rather than dropping back to a spinner.
    private var isInitialLoad: Bool {
        switch model.phase {
        case .idle, .loading: return true
        case .loaded, .failed: return false
        }
    }
}

/// Start a brand-new MiniMax Code thread from the phone.
///
/// The sidecar has no create endpoint: a thread comes into existence when the
/// first turn is sent, and the stream hands back the remote session id to
/// adopt.  This mirrors the Mac rail's New Thread button, which also only
/// resets local state and lets the first message create the session.
struct NewThreadSheet: View {
    let host: ClutchHost
    let onCreated: (AcpSessionInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: NewThreadModel

    init(host: ClutchHost, onCreated: @escaping (AcpSessionInfo) -> Void) {
        self.host = host
        self.onCreated = onCreated
        _model = State(initialValue: NewThreadModel(host: host))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Send The First Message To Start A Thread.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if let error = model.errorText {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message", text: $model.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.clutchSecondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .disabled(model.isSending)
                    Button {
                        model.send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
                    .accessibilityLabel("Send Message")
                }

                if let reply = model.reply {
                    Text(reply)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.clutchSecondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("New Thread")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Sends the opening turn with no session id, then reports the session the
/// sidecar created so the sidebar can adopt and select it.
@MainActor
@Observable
final class NewThreadModel {
    private let host: ClutchHost
    private var chatId: String?
    private var remoteSessionId: String?
    var onCreated: ((AcpSessionInfo) -> Void)?

    var draft = ""
    var reply: String?
    var errorText: String?
    var isSending = false

    init(host: ClutchHost) {
        self.host = host
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }
        draft = ""
        errorText = nil
        reply = nil
        isSending = true

        let client = ChatSessionClient(
            host: host,
            model: "mcode",
            sessionId: nil,
            relayReceiverUid: "",
            engine: "mcode"
        )
        Task {
            var text = ""
            do {
                for try await event in client.stream(prompt: prompt) {
                    switch event {
                    case .started(let id, _):
                        chatId = id
                    case .message(let chunk):
                        text += chunk
                        reply = text
                    case .thought:
                        break
                    case .done(_, _, let remote):
                        if let remote { remoteSessionId = remote }
                    case .failed(let message):
                        errorText = message
                    }
                }
            } catch {
                errorText = error.localizedDescription
            }
            isSending = false
            // Only adopt once the engine has actually minted an id, otherwise
            // the sidebar would select a row that does not exist.
            if let remoteSessionId {
                onCreated?(AcpSessionInfo(sessionId: remoteSessionId))
            }
        }
    }
}
