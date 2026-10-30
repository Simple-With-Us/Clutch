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
    /// Bumps on every engine switch, so a late answer for the previous
    /// engine is discarded instead of displayed.
    private var generation = 0

    var phase: Phase = .idle

    init(host: ClutchHost) {
        self.host = host
        self.client = SessionsClient(host: host)
    }

    func load() async {
        guard phase != .loading else { return }
        phase = .loading
        generation += 1
        let ticket = generation
        let wanted = engine
        do {
            // Newest first, with an unparseable stamp sinking below the dated
            // rows instead of scrambling the list.
            let listed = try await client.list(engine: wanted)
            // An engine switch that landed mid-flight starts its own load; a
            // ticket pins this answer to its engine, so a late answer for the
            // previous engine is dropped instead of displayed under the new one.
            guard ticket == generation else { return }
            phase = .loaded(AcpSessionInfo.newestFirst(listed))
        } catch {
            guard ticket == generation else { return }
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

    /// Reload for the newly picked engine, even when the previous engine's
    /// list is still in flight: the in-flight answer carries a stale ticket
    /// and is discarded, so the new engine's load is the one that lands.
    func reloadForEngine() async {
        generation += 1
        if phase == .loading { phase = .idle }
        await load()
    }

    var sessions: [AcpSessionInfo] {
        if case .loaded(let sessions) = phase { return sessions }
        return []
    }
}

public struct SessionsView: View {
    let host: ClutchHost
    /// The engine whose threads this list shows.
    ///
    /// Every engine Clutch can run keeps a thread log, so this is whichever
    /// one the owner picked from the menu above the list.
    @State private var engine: String = "mcode"
    @State private var model: SessionsModel
    @State private var selectedId: String?
    @State private var isStartingThread = false
    @State private var isShowingFiles = false
    @State private var searchText = ""
    @State private var pinnedIds: Set<String> = []
    @State private var catalog: EngineCatalog?
    /// True until the catalog has landed.
    ///
    /// A host that serves no catalog still answers the thread list, so a
    /// failed list is only real once the catalog has settled: before that it
    /// may just be the wrong engine for this host.
    @State private var isSettling = true

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
        .task(id: host.id) {
            // A different server means a different thread list, and the model
            // holds the host it was built for, so it is rebuilt rather than
            // reused: otherwise the list keeps showing the previous host's
            // threads.
            model = SessionsModel(host: host)
            selectedId = nil
            pinnedIds = ThreadPinStore.pinnedIDs(forHost: host.id)
            // The list and the catalog are read together: the list must not
            // wait on a host that serves no catalog, and the catalog must not
            // wait on the list.
            model.engine = engine
            isSettling = true
            async let catalogTask = EngineCatalogClient(host: host).fetch()
            await model.load()
            catalog = try? await catalogTask
            isSettling = false
            // The catalog says which engines this host runs, so the list
            // follows it: an engine that is not installed here cannot list
            // its threads.  The catalog stays authoritative whenever one is
            // served — a code server offering Muse Code must not be dragged
            // back to MiniMax Code.  A MiniMax Code server runs one engine
            // and serves no catalog, so only then does it name the engine
            // itself.
            let wanted: String?
            if let descriptor = catalog?.descriptor(engine), descriptor.available == false {
                wanted = catalog?.availableEngines.first(where: { $0.supportsThreads })?.id
            } else if host.isMiniMaxCodeOnly, catalog == nil {
                wanted = "mcode"
            } else {
                wanted = nil
            }
            if let wanted, wanted != engine {
                engine = wanted
                model.engine = wanted
                await model.refresh()
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
                // The files of the folder the open thread works in, the way
                // the web canvas shows them beside the thread list.
                Button {
                    isShowingFiles = true
                } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("Files")
            }
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
        .sheet(isPresented: $isShowingFiles) {
            FilesView(host: host, root: filesRoot)
        }
    }

    /// The folder the file tree is rooted at.
    ///
    /// The open thread's own folder, so the files on screen are the ones the
    /// engine is working in.  A thread that names no folder falls back to
    /// the folder a new thread would work in.
    private var filesRoot: String {
        guard let selectedId,
              let session = model.sessions.first(where: { $0.sessionId == selectedId }),
              let cwd = session.cwd,
              !cwd.isEmpty else { return "" }
        return cwd
    }

    /// Which engine's threads are listed.
    ///
    /// Every engine Clutch can run keeps a thread log, so the picker offers
    /// the ones this host actually has: the DeepSeek and MiniMax threads
    /// come from the dsh host, and the code engines keep their own.  A menu
    /// rather than a segmented control, because four engine names do not fit
    /// across a phone.
    private var engineBar: some View {
        HStack(spacing: 8) {
            if threadEngines.count > 1 {
                Menu {
                    ForEach(threadEngines, id: \.id) { descriptor in
                        Button {
                            selectEngine(descriptor.id)
                        } label: {
                            if descriptor.id == engine {
                                Label(descriptor.label, systemImage: "checkmark")
                            } else {
                                Text(descriptor.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                        Text(engineLabel)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Engine: \(engineLabel)")
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

    /// Show another engine's threads.
    ///
    /// The open thread is dropped, because a thread belongs to the engine
    /// that made it and another engine's transcript is a different thing.
    private func selectEngine(_ id: String) {
        guard id != engine else { return }
        engine = id
        model.engine = id
        selectedId = nil
        Task { await model.reloadForEngine() }
    }

    /// The engines on this host whose threads can be listed.
    private var threadEngines: [EngineDescriptor] {
        (catalog?.engines ?? []).filter { $0.available && $0.supportsThreads }
    }

    private var engineLabel: String {
        catalog?.descriptor(engine)?.label ?? EngineLabels.label(for: engine)
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
            // Each thread gets its own view, so switching threads starts the
            // new one clean: the transcript, the plan and the pending
            // questions belong to the thread they were raised in.
            SessionThreadView(host: host, session: session, engine: engine)
                .id(session.sessionId)
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
        // While the catalog is still landing the failure may only be the
        // wrong engine for this host, so it is not reported yet.
        if isSettling { return nil }
        if case .failed(let message) = model.phase { return message }
        return nil
    }

    /// True only while the first fetch is still outstanding; a reload keeps the
    /// previous list on screen rather than dropping back to a spinner.
    private var isInitialLoad: Bool {
        if isSettling { return true }
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
    @State private var showMuseSignIn = false

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
                    if engine == "muse", EngineAuthenticationAttempt.isRequired(error) {
                        Button("Sign In To Muse") { showMuseSignIn = true }
                            .buttonStyle(.borderedProminent)
                    }
                }

                // The engine is blocked on this request until the answer
                // goes back, so it is held on screen.
                if let request = model.pendingPermission {
                    PermissionCard(request: request) { optionId in
                        model.answerPermission(optionId)
                    }
                }
                if !model.plan.isEmpty {
                    PlanPanel(entries: model.plan)
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
            .sheet(isPresented: $showMuseSignIn) {
                EngineSignInView(host: host) { model.errorText = nil }
            }
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
    /// The permission requests the engine is waiting on, oldest first.
    ///
    /// The engine asks one question at a time, but a second request can land
    /// before the first is answered, so the queue keeps the earlier one on
    /// screen instead of dropping it behind the newer card.
    var pendingPermissions: [AcpPermissionRequest] = []

    /// The request on screen.
    var pendingPermission: AcpPermissionRequest? { pendingPermissions.first }
    /// The engine's execution plan, as it last reported it.
    var plan: [AcpPlanEntry] = []

    init(host: ClutchHost, engine: String = "mcode") {
        self.host = host
        self.engine = engine
    }

    /// Answer the permission request the engine is waiting on.
    ///
    /// The answer goes to the sidecar, which hands it to the engine.
    func answerPermission(_ optionId: String?) {
        guard let request = pendingPermissions.first, let chatId else { return }
        Task {
            let answered = await ChatSessionClient.answerPermission(
                host: host,
                sessionId: chatId,
                requestId: request.requestId,
                optionId: optionId
            )
            if answered {
                // The card only goes away once the answer is on its way, so a
                // failed answer can be tried again.
                pendingPermissions.removeFirst()
            } else {
                errorText = "The permission answer did not reach the engine."
            }
        }
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
                    case .permission(let request):
                        // The engine is blocked on this request until the
                        // answer goes back, so it is held on screen.
                        pendingPermissions.append(request)
                    case .plan(let entries):
                        plan = entries
                    case .done(_, _, let remote):
                        if let remote { remoteSessionId = remote }
                        pendingPermissions.removeAll()
                    case .usage:
                        break // live usage strip is Mac-only
                    case .failed(let message):
                        errorText = message
                        pendingPermissions.removeAll()
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
