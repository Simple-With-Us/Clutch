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
    /// The engine whose threads are listed.
    var engine: String = "mcode"

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
            phase = .loaded(AcpSessionInfo.newestFirst(try await client.list(engine: engine)))
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
    /// The engine whose threads this list shows (`mcode` for MiniMax Code,
    /// `muse` for Muse Code).  A host that runs both can switch between
    /// them from the picker above the list.
    @State private var engine: String = "mcode"
    @State private var model: SessionsModel
    @State private var selectedId: String?
    @State private var isStartingThread = false
    @State private var searchText = ""
    @State private var pinnedIds: Set<String> = []
    @State private var catalog: EngineCatalog?

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
        .task {
            pinnedIds = ThreadPinStore.pinnedIDs(forHost: host.id)
            // The catalog can take a while on a cold server, so the thread
            // list does not wait for it.
            async let catalogTask = EngineCatalogClient(host: host).fetch()
            model.engine = engine
            await model.load()
            catalog = try? await catalogTask
            // A host that runs Muse Code but no MiniMax Code starts on
            // Muse, not on an engine that is not installed there.
            if let descriptor = catalog?.descriptor(engine), descriptor.available == false {
                if let first = catalog?.availableEngines.first(where: { $0.supportsThreads }) {
                    engine = first.id
                    model.engine = first.id
                    await model.refresh()
                }
            }
        }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            engineBar
        }
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
            NewThreadSheet(host: host, engine: engine) { created in
                isStartingThread = false
                Task {
                    await model.refresh()
                    selectedId = created.sessionId
                }
            }
        }
    }

    /// Which engine's threads are listed.  A host can run MiniMax Code and
    /// Muse Code side by side, so the list says which one it is showing.
    private var engineBar: some View {
        HStack(spacing: 8) {
            if threadEngines.count > 1 {
                Picker("Engine", selection: $engine) {
                    ForEach(threadEngines, id: \.id) { descriptor in
                        Text(descriptor.label).tag(descriptor.id)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: engine) { _, next in
                    model.engine = next
                    selectedId = nil
                    Task { await model.refresh() }
                }
            } else {
                Text(engineLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // The server picker sits beside the engine picker: both answer
            // "which threads am I looking at".
            HostSwitcher(host: host, store: HostStore.shared, compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.clutchSecondaryBackground.opacity(0.6))
    }

    /// The engines on this host whose threads can be listed.
    private var threadEngines: [EngineDescriptor] {
        (catalog?.engines ?? []).filter { $0.available && $0.supportsThreads }
    }

    private var engineLabel: String {
        catalog?.descriptor(engine)?.label ?? (engine == "muse" ? "Muse Code" : "MiniMax Code")
    }

    private var visibleSessions: [AcpSessionInfo] {
        AcpSessionInfo.filtered(AcpSessionInfo.newestFirst(model.sessions), query: searchText)
    }

    private var threadList: some View {
        List(selection: $selectedId) {
            ForEach(AcpSessionInfo.grouped(visibleSessions, pinned: pinnedIds)) { group in
                Section(group.title) {
                    ForEach(group.sessions) { session in
                        ThreadSidebarRow(
                            session: session,
                            isSelected: session.sessionId == selectedId,
                            isLoading: false,
                            isDisabled: false,
                            onSelect: { selectedId = $0.sessionId }
                        )
                        .tag(session.sessionId)
                        .contextMenu {
                            Button {
                                ThreadPinStore.toggle(session.sessionId, forHost: host.id)
                                pinnedIds = ThreadPinStore.pinnedIDs(forHost: host.id)
                            } label: {
                                Label(
                                    pinnedIds.contains(session.sessionId) ? "Unpin Thread" : "Pin Thread",
                                    systemImage: pinnedIds.contains(session.sessionId) ? "pin.slash" : "pin"
                                )
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Filter Threads")
        .refreshable { await model.refresh() }
        .overlay {
            if visibleSessions.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let session = selectedSession {
            SessionThreadView(host: host, session: session, engine: engine)
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
    /// The engine the new thread runs on.
    let engine: String
    let onCreated: (AcpSessionInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: NewThreadModel

    init(host: ClutchHost, engine: String = "mcode", onCreated: @escaping (AcpSessionInfo) -> Void) {
        self.host = host
        self.engine = engine
        self.onCreated = onCreated
        _model = State(initialValue: NewThreadModel(host: host, engine: engine))
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
    /// The engine the new thread runs on.
    private let engine: String
    private var chatId: String?
    private var remoteSessionId: String?
    var onCreated: ((AcpSessionInfo) -> Void)?

    var draft = ""
    var reply: String?
    var errorText: String?
    var isSending = false

    init(host: ClutchHost, engine: String = "mcode") {
        self.host = host
        self.engine = engine
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
            model: "",
            sessionId: nil,
            relayReceiverUid: "",
            engine: engine
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
                    case .thought, .tool:
                        break
                    case .done(_, _, let remote):
                        if let remote { remoteSessionId = remote }
                    case .usage:
                        break // live usage strip is Mac-only
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
