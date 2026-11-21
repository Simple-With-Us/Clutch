import SwiftUI
import UniformTypeIdentifiers
#if canImport(PhotosUI)
import PhotosUI
#endif

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

/// Where the home surface's detail pane is pointed.
enum HomeSelection: Hashable {
    /// The thread with this session id.
    case thread(String)
    /// The always-there agent conversation.
    case agentChat
    /// Nothing yet — the detail pane explains itself.
    case none
}

/// One working folder's threads in the home list.
struct HomeFolderGroup: Identifiable {
    let name: String
    /// The full path a "New Thread Here" button preselects; empty means the
    /// sidecar's home-directory default.
    let path: String
    let sessions: [AcpSessionInfo]

    var id: String { name }
}

public struct SessionsView: View {
    let host: ClutchHost
    /// The engine whose threads this list shows.
    ///
    /// Every engine Clutch can run keeps a thread log, so this is whichever
    /// one the owner picked from the menu above the list.
    @State private var engine: String = "mcode"
    @State private var model: SessionsModel
    /// Where the detail pane is pointed: a thread, the agent conversation,
    /// or nothing.  The agent conversation is a destination now, not a tab.
    @State private var selection: HomeSelection = .none
    @State private var isStartingThread = false
    @State private var newThreadFolder: String = ""
    @State private var isShowingFiles = false
    @State private var isShowingHosts = false
    @State private var searchText = ""
    @State private var pinnedIds: Set<String> = []
    @State private var catalog: EngineCatalog?
    @State private var catalogRequestGeneration = 0
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
        .task(id: host.pairingKey) {
            catalogRequestGeneration += 1
            catalog = nil
            // A different server means a different thread list, and the model
            // holds the host it was built for, so it is rebuilt rather than
            // reused: otherwise the list keeps showing the previous host's
            // threads.
            model = SessionsModel(host: host)
            selection = .none
            pinnedIds = ThreadPinStore.pinnedIDs(forHost: host.id)
            // The list and the catalog are read together: the list must not
            // wait on a host that serves no catalog, and the catalog must not
            // wait on the list.
            model.engine = engine
            isSettling = true
            async let catalogTask = refreshCatalog(for: engine)
            await model.load()
            await catalogTask
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
                await refreshCatalog(for: wanted)
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
            } else if model.sessions.isEmpty && !hasActivity {
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
                        description: Text("Start one with the button above.")
                    )
                }
            } else {
                homeList
            }
        }
        .navigationTitle("Clutch")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .top, spacing: 0) {
            engineBar
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingHosts = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Hosts And Settings")
            }
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
                    newThreadFolder = ""
                    selection = .none
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
            NewThreadSheet(host: host, engine: engine, initialFolder: newThreadFolder) { created in
                isStartingThread = false
                Task {
                    await model.refresh()
                    selection = .thread(created.sessionId)
                }
            }
        }
        .sheet(isPresented: $isShowingFiles) {
            FilesView(host: host, root: filesRoot)
        }
        .sheet(isPresented: $isShowingHosts) {
            HostsSheet(store: HostStore.shared)
        }
    }

    /// The home list: what needs the owner first, then the folders their
    /// threads work in.  The tab bar used to split these across two tabs;
    /// they are one question — "what is going on" — so they are one list.
    ///
    /// Selection drives the detail: a compact-width split view only pushes
    /// its detail column for a selection change, so every row that opens
    /// something is tagged and the List owns the tap (plain buttons here
    /// would swallow it and the thread would never open).
    @ViewBuilder
    private var homeList: some View {
        List(selection: Binding(
            get: { selection == .none ? nil : selection },
            set: { selection = $0 ?? .none }
        )) {
            agentChatRow
            if !pendingApprovals.isEmpty {
                Section("Needs You") {
                    ForEach(pendingApprovals) { approval in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(approval.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text("Wants approval")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44)
                        .tag(HomeSelection.thread(approval.sessionId))
                        .accessibilityLabel("Approval wanted by \(approval.title)")
                    }
                }
            }
            if !runningTurns.isEmpty {
                Section("Running") {
                    ForEach(runningTurns) { run in
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                            Text(run.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44)
                        .tag(HomeSelection.thread(run.sessionId))
                        .accessibilityLabel("Running: \(run.title)")
                    }
                }
            }
            if !pinnedIds.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedSessions) { session in
                        threadRow(session)
                    }
                }
            }
            ForEach(folderGroups) { folder in
                Section(folder.name) {
                    ForEach(folder.sessions) { session in
                        threadRow(session)
                    }
                    Button {
                        newThreadFolder = folder.path
                        selection = .none
                        isStartingThread = true
                    } label: {
                        Label(
                            folder.path.isEmpty ? "New Thread In Home Directory" : "New Thread In \(folder.name)",
                            systemImage: "square.and.pencil"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .frame(minHeight: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Filter Threads")
        .refreshable { await model.refresh() }
        .overlay {
            if visibleSessions.isEmpty && !hasActivity && !model.sessions.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    /// The agent conversation row: the always-there thread that used to be
    /// its own tab.  iOS only — the Mac keeps its own Agent Chat tab.  The
    /// row is selection-tagged like the thread rows above it.
    @ViewBuilder
    private var agentChatRow: some View {
        #if os(iOS)
        Section {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent Chat")
                        .font(.system(size: 12, weight: .semibold))
                    Text("The always-there conversation")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .tag(HomeSelection.agentChat)
            .accessibilityLabel("Agent Chat")
        }
        #endif
    }

    /// One thread row with its context menu, shared by the pinned and folder
    /// sections.  The row renders without its own button: the List's
    /// selection binding is what opens the thread on a phone.
    private func threadRow(_ session: AcpSessionInfo) -> some View {
        let isSelected: Bool = {
            if case .thread(let id) = selection { return id == session.sessionId }
            return false
        }()
        return ThreadSidebarRow(
            session: session,
            isSelected: isSelected,
            isLoading: false,
            isDisabled: false,
            onSelect: { _ in },
            isListSelectable: true
        )
        .tag(HomeSelection.thread(session.sessionId))
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
            #if os(iOS)
            Button {
                UIPasteboard.general.string = session.sessionId
            } label: {
                Label("Copy Session ID", systemImage: "doc.on.doc")
            }
            #endif
        }
    }

    // MARK: - Home sections

    private var visibleSessions: [AcpSessionInfo] {
        AcpSessionInfo.filtered(AcpSessionInfo.newestFirst(model.sessions), query: searchText)
    }

    /// Approvals this device has seen, minus the ones already listed as
    /// rows, so a thread never appears twice in one list.
    private var pendingApprovals: [TurnActivityApproval] {
        let listed = Set(visibleSessions.map(\.sessionId))
        return TurnActivity.shared.approvals.filter { !listed.contains($0.sessionId) }
    }

    /// Runs this device is streaming, minus the ones already listed.
    private var runningTurns: [TurnActivityRun] {
        let listed = Set(visibleSessions.map(\.sessionId))
        return TurnActivity.shared.runs.filter { !listed.contains($0.sessionId) }
    }

    private var hasActivity: Bool {
        !pendingApprovals.isEmpty || !runningTurns.isEmpty
    }

    private var pinnedSessions: [AcpSessionInfo] {
        visibleSessions.filter { pinnedIds.contains($0.sessionId) }
    }

    /// One group per working folder, the folder's leaf name as the title,
    /// sorted by the newest thread each folder holds.  A thread with no
    /// folder lands in "No Folder" rather than vanishing.
    private var folderGroups: [HomeFolderGroup] {
        let pinned = Set(pinnedIds)
        let unpinned = visibleSessions.filter { !pinned.contains($0.sessionId) }
        var buckets: [String: (path: String, sessions: [AcpSessionInfo])] = [:]
        for session in unpinned {
            let path = session.cwd ?? ""
            let name = path.isEmpty ? "" : (path as NSString).lastPathComponent
            var bucket = buckets[name] ?? (path, [])
            bucket.sessions.append(session)
            buckets[name] = bucket
        }
        return buckets
            .map { name, bucket in
                HomeFolderGroup(
                    name: name.isEmpty ? "No Folder" : name,
                    path: bucket.path,
                    sessions: AcpSessionInfo.newestFirst(bucket.sessions)
                )
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.sessions.compactMap(\.updated).max() ?? .distantPast
                let rhsDate = rhs.sessions.compactMap(\.updated).max() ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.name < rhs.name
            }
    }

    /// The folder the file tree is rooted at.
    ///
    /// The open thread's own folder, so the files on screen are the ones the
    /// engine is working in.  A thread that names no folder falls back to
    /// the folder a new thread would work in.
    private var filesRoot: String {
        guard case .thread(let id) = selection,
              let session = model.sessions.first(where: { $0.sessionId == id }),
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
        // The open thread is dropped, because a thread belongs to the engine
        // that made it and another engine's transcript is a different thing.
        selection = .none
        Task {
            async let catalogTask = refreshCatalog(for: id)
            await model.reloadForEngine()
            await catalogTask
        }
    }

    @MainActor
    private func refreshCatalog(for requestedEngine: String) async {
        catalogRequestGeneration += 1
        let ticket = catalogRequestGeneration
        let requestedHost = host
        let loaded = try? await EngineCatalogClient(host: requestedHost).fetch(engine: requestedEngine)
        guard ticket == catalogRequestGeneration,
              requestedHost.id == host.id,
              engine == requestedEngine else { return }
        if let loaded { catalog = loaded }
        isSettling = false
    }

    /// The engines on this host whose threads can be listed.
    private var threadEngines: [EngineDescriptor] {
        (catalog?.engines ?? []).filter { $0.available && $0.supportsThreads }
    }

    private var engineLabel: String {
        catalog?.descriptor(engine)?.label ?? EngineLabels.label(for: engine)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .thread(let id):
            // Each thread gets its own view, so switching threads starts the
            // new one clean: the transcript, the plan and the pending
            // questions belong to the thread they were raised in.  A thread
            // tapped from Needs You or Running that the loaded pages do not
            // carry still opens: the load call needs only the id.
            let session = model.sessions.first { $0.sessionId == id } ?? AcpSessionInfo(sessionId: id)
            SessionThreadView(host: host, session: session, engine: engine)
                .id(id)
        case .agentChat:
            #if os(iOS)
            ChatView(activeHost: host, store: HostStore.shared)
            #endif
        case .none:
            ContentUnavailableView(
                "Pick A Thread",
                systemImage: "text.bubble",
                description: Text("Pick a thread from the list, or start one.")
            )
        }
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
///
/// The sheet names the working folder before the first turn: a thread
/// created without one lands in the sidecar's `$HOME` default, and the ACP
/// bridge then refuses to resume it anywhere else.
struct NewThreadSheet: View {
    let host: ClutchHost
    /// The engine the new thread runs on.
    let engine: String
    /// The folder the first turn works in, preselected by the caller (a
    /// folder section's "New Thread Here" button) or chosen in the sheet.
    @State private var workingFolder: String = ""
    /// The folder the sheet was opened with; folded into `workingFolder` on
    /// appear so a caller that preselects also sees it as chosen.
    private let initialFolder: String
    let onCreated: (AcpSessionInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: NewThreadModel
    @State private var showMuseSignIn = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showFilePicker = false
    @State private var isDropTargeted = false
    @State private var isShowingFolderPicker = false
    @State private var recentFolders: [String] = []

    init(
        host: ClutchHost,
        engine: String = "mcode",
        initialFolder: String = "",
        onCreated: @escaping (AcpSessionInfo) -> Void
    ) {
        self.host = host
        self.engine = engine
        self.initialFolder = initialFolder
        self.onCreated = onCreated
        _model = State(initialValue: NewThreadModel(host: host, engine: engine))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Send the first message to start a thread.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                workingFolderRow

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
                    PermissionCard(
                        request: request,
                        queuedCount: max(model.pendingPermissions.count - 1, 0),
                        canAnswer: model.canAnswerPermissions
                    ) { optionId in
                        model.answerPermission(optionId)
                    }
                }
                if !model.plan.isEmpty {
                    PlanPanel(entries: model.plan)
                }

                if !model.attachments.isEmpty {
                    attachmentStrip
                }
                HStack(alignment: .bottom, spacing: 8) {
                    PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "paperclip")
                            .font(.title3)
                            .foregroundStyle(Color.secondary)
                    }
                    .disabled(model.isSending)
                    .accessibilityLabel("Attach Image")
                    Button {
                        showFilePicker = true
                    } label: {
                        Image(systemName: "folder")
                            .font(.title3)
                            .foregroundStyle(Color.secondary)
                    }
                    .disabled(model.isSending)
                    .accessibilityLabel("Attach File")
                    Button {
                        Task { await pasteClipboard() }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.title3)
                            .foregroundStyle(Color.secondary)
                    }
                    .disabled(model.isSending)
                    .accessibilityLabel("Paste Image Or File")
                    TextField("Message", text: $model.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.clutchSecondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .disabled(model.isSending)
                    if model.isSending {
                        Button {
                            model.stop()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Stop")
                    } else {
                        Button {
                            model.send()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
                        .accessibilityLabel("Send Message")
                    }
                }
                // The paste command is macOS-only; on iOS the paste button
                // reads the clipboard instead.
                #if os(macOS)
                .onPasteCommand(of: [.image, .fileURL], perform: handlePasteProviders)
                #endif
                .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                    handlePasteProviders(providers)
                    return !providers.isEmpty
                }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.accentColor, lineWidth: 2)
                    }
                }
                .fileImporter(
                    isPresented: $showFilePicker,
                    allowedContentTypes: [.data],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result {
                        let outcome = AttachmentPaste.outcomeForFileURLs(urls)
                        Task { @MainActor in applyOutcome(outcome) }
                    }
                }
                .onChange(of: pickedPhoto) { _, item in
                    guard let item else { return }
                    pickedPhoto = nil
                    Task { await loadAttachment(item) }
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
            .sheet(isPresented: $isShowingFolderPicker) {
                FolderPickerView(host: host, root: "") { chosen in
                    workingFolder = chosen
                    RecentFolderStore.add(chosen, forHost: host.id)
                    recentFolders = RecentFolderStore.recent(forHost: host.id)
                }
            }
            .onAppear {
                if workingFolder.isEmpty && !initialFolder.isEmpty {
                    workingFolder = initialFolder
                }
                recentFolders = RecentFolderStore.recent(forHost: host.id)
                // The folder lives on the model, since send() reads it there;
                // the sheet's own state is just what the menu edits.
                model.workingFolder = workingFolder
            }
            .onChange(of: workingFolder) { _, folder in
                model.workingFolder = folder
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

    /// The folder the first turn will run in: recents, browse, or the
    /// caller's preselection.  Empty deliberately means the sidecar's own
    /// default — the label says that out loud rather than hiding it.
    @ViewBuilder
    private var workingFolderRow: some View {
        Menu {
            Button {
                workingFolder = ""
            } label: {
                Label("Default (Home Directory)", systemImage: workingFolder.isEmpty ? "checkmark" : "house")
            }
            ForEach(recentFolders, id: \.self) { folder in
                Button {
                    workingFolder = folder
                } label: {
                    Label(folder, systemImage: workingFolder == folder ? "checkmark" : "folder")
                }
            }
            Button {
                isShowingFolderPicker = true
            } label: {
                Label("Browse…", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(workingFolder.isEmpty
                        ? "Working Folder: Default (Home Directory)"
                        : "Working In \((workingFolder as NSString).lastPathComponent)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.clutchSecondaryBackground, in: Capsule())
        }
        .accessibilityLabel("Working Folder")
    }

    /// The images waiting on the first turn, each removable.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.system(size: 10))
                        Text(attachment.displayName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Button {
                            model.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.displayName)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.clutchSecondaryBackground, in: Capsule())
                }
            }
        }
    }

    /// Take providers from a paste command or a drop.
    private func handlePasteProviders(_ providers: [NSItemProvider]) {
        Task {
            let outcome = await AttachmentPaste.outcomeForProviders(providers)
            await MainActor.run { applyOutcome(outcome) }
        }
    }

    /// Paste whatever the clipboard holds: screenshots and copied photos
    /// attach as images, copied files attach or inline by type.
    private func pasteClipboard() async {
        let outcome = await AttachmentPaste.pasteFromClipboard()
        await MainActor.run { applyOutcome(outcome) }
    }

    /// Fold a paste, drop, or pick into the composer: images join the first
    /// turn, text files splice into the draft, failures say so out loud.
    @MainActor
    private func applyOutcome(_ outcome: PasteOutcome) {
        if !outcome.images.isEmpty {
            model.attachments.append(contentsOf: outcome.images)
        }
        for insert in outcome.textInserts {
            if model.draft.isEmpty {
                model.draft = insert
            } else {
                model.draft += "\n\n" + insert
            }
        }
        if !outcome.errors.isEmpty {
            model.errorText = outcome.errors.joined(separator: " ")
        } else if !outcome.images.isEmpty || !outcome.textInserts.isEmpty {
            model.errorText = nil
        }
    }

    /// Read a picked photo into an attachment.
    private func loadAttachment(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run { model.errorText = "Could not read that photo." }
            return
        }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
        let outcome: PasteOutcome
        switch AttachmentPaste.fate(data: data, name: "attachment.\(ext)") {
        case .image(let attachment):
            outcome = PasteOutcome(images: [attachment])
        case .text(let insert):
            outcome = PasteOutcome(textInserts: [insert])
        case .rejected(let message):
            outcome = PasteOutcome(errors: [message])
        }
        await MainActor.run { applyOutcome(outcome) }
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
    private var remoteSessionId: String?
    var onCreated: ((AcpSessionInfo) -> Void)?

    var draft = ""
    var reply: String?
    var errorText: String?
    var isSending = false
    /// The working folder the first turn runs in; empty means the sidecar's
    /// `$HOME` default, which the ACP bridge then pins the thread to.
    var workingFolder: String = ""
    /// The sidecar chat id the first turn created; the permission answer
    /// rides on it, so the card is unanswerable until it exists.
    var chatId: String?
    var canAnswerPermissions: Bool { chatId != nil }
    private var sendTask: Task<Void, Never>?
    /// Images attached to the first turn, the way the thread surface
    /// attaches files to a message.
    var attachments: [ChatAttachment] = []
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
            engine: engine,
            // The chosen folder rides on the first turn: without it the
            // sidecar defaults to $HOME and the thread is stuck there.
            cwd: workingFolder.isEmpty ? nil : workingFolder,
            museOptions: engine == "muse" ? MuseLaunchPreferences.options(for: host) : nil,
            contextPolicy: engine == "muse" ? MuseContextPreferences.policy(for: host) : nil,
            images: attachments
        )
        attachments = []
        sendTask = Task {
            var text = ""
            do {
                for try await event in client.stream(prompt: prompt) {
                    switch event {
                    case .capabilities:
                        break
                    case .started(let id, _):
                        chatId = id
                    case .message(let chunk):
                        text += chunk
                        reply = text
                    case .thought, .tool:
                        break
                    case .permission(let request):
                        // The engine is blocked on this request until the
                        // answer goes back, so it is held on screen and the
                        // owner is woken for it.
                        pendingPermissions.append(request)
                        TurnNotifier.permissionRequest(threadTitle: "New Thread")
                    case .plan(let entries):
                        plan = entries
                    case .done(_, _, let remote):
                        if let remote { remoteSessionId = remote }
                        pendingPermissions.removeAll()
                        // The folder worked, so the next New Thread starts here.
                        RecentFolderStore.add(workingFolder, forHost: host.id)
                    case .usage:
                        break // live usage strip is Mac-only
                    case .contextControls:
                        break // compaction controls are shown on the Mac workspace
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
                onCreated?(AcpSessionInfo(sessionId: remoteSessionId, cwd: workingFolder.isEmpty ? nil : workingFolder))
            }
        }
    }

    /// Cancels the first turn: the sidecar is told first, then the local
    /// stream is dropped, so a sheet that is dismissed mid-turn stops the
    /// engine instead of abandoning it.
    func stop() {
        guard isSending else { return }
        if let chatId {
            let host = self.host
            Task { await ChatSessionClient.cancel(host: host, sessionId: chatId) }
        }
        sendTask?.cancel()
        sendTask = nil
        pendingPermissions.removeAll()
        isSending = false
    }
}
