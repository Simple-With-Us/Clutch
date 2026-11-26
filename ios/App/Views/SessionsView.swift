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
    /// The newest threads asked for so far.
    ///
    /// The sidecar serves the newest threads in one page, so a wider page is
    /// how the older ones are reached.
    var limit: Int = SessionsClient.SessionListLimit.initial
    /// True when the sidecar says older threads exist beyond the page on
    /// screen.
    ///
    /// The sidecar never says how many, so nothing here may claim a total.
    var hasMore = false
    /// True while a wider page is on the way.
    var isLoadingMore = false

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
        let requested = limit
        do {
            // Newest first, with an unparseable stamp sinking below the dated
            // rows instead of scrambling the list.
            let page = try await client.listPage(engine: wanted, limit: requested)
            // An engine switch that landed mid-flight starts its own load; a
            // ticket pins this answer to its engine, so a late answer for the
            // previous engine is dropped instead of displayed under the new one.
            guard ticket == generation else { return }
            limit = page.limit
            hasMore = page.hasMore
            phase = .loaded(AcpSessionInfo.newestFirst(page.sessions))
        } catch {
            guard ticket == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Widen the list:  the older threads are appended to what is on screen.
    ///
    /// The sidecar answers with the newest threads in one list, so a wider
    /// page holds every row already on screen and the older ones besides.
    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        guard let next = SessionsClient.SessionListLimit.next(after: limit) else { return }
        isLoadingMore = true
        // The ticket pins this answer to the engine and the load it belongs
        // to, so a load that started later owns the list and this answer is
        // dropped instead of merging into a list that has moved on.
        let ticket = generation
        let wanted = engine
        defer { isLoadingMore = false }
        do {
            let page = try await client.listPage(engine: wanted, limit: next)
            guard ticket == generation else { return }
            limit = page.limit
            hasMore = page.hasMore
            if case .loaded(let shown) = phase {
                phase = .loaded(AcpSessionInfo.newestFirst(page.merging(into: shown)))
            }
        } catch {
            // The list on screen stays as it is, and the row stays with it,
            // so a retry is one tap away.
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
        // A widened page belongs to the engine it was widened on; the new
        // engine starts again at its newest threads.
        limit = SessionsClient.SessionListLimit.initial
        hasMore = false
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
    ///
    /// The engine is the one the surface that asked for the thread named, so
    /// a Muse approval opens Muse while the sidebar stays on MiniMax Code.
    /// A row tapped in the list names none and follows the sidebar's engine.
    case thread(String, engine: String?)
    /// The conversation without a project.
    case quickChat
    /// The approvals waiting on this host.
    case approvals
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

    /// The path, not the leaf name: two folders can end in the same name,
    /// and the list must keep them apart.
    var id: String { path }
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
    /// The thread a link asked for, waiting for this surface to take it.
    @State private var threadLinkRouter = ThreadLinkRouter.shared
    /// The approvals list a link asked for, waiting for this surface to
    /// take it.
    @State private var approvalsLinkRouter = ApprovalsLinkRouter.shared
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

    private let onShowProjects: (() -> Void)?

    public init(host: ClutchHost, onShowProjects: (() -> Void)? = nil) {
        self.host = host
        self.onShowProjects = onShowProjects
        _model = State(initialValue: SessionsModel(host: host))
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onChange(of: threadLinkRouter.pending) { _, _ in
            openPendingThread()
        }
        .onChange(of: approvalsLinkRouter.pending) { _, _ in
            openPendingApprovals()
        }
        .onAppear {
            // A link can arrive before this surface exists, so the thread it
            // names is opened when the surface appears as well as when the
            // link changes.
            openPendingThread()
            openPendingApprovals()
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
            if let onShowProjects {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onShowProjects) {
                        Label("Projects", systemImage: "folder.badge.plus")
                    }
                    .accessibilityLabel("Projects")
                    .accessibilityIdentifier("clutch-projects")
                }
            }
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
            NewThreadSheet(host: host, engine: engine, initialFolder: newThreadFolder, seedFolders: model.sessions.compactMap(\.cwd)) { created in
                isStartingThread = false
                Task {
                    await model.refresh()
                    selection = .thread(created.sessionId, engine: engine)
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
            if !pendingApprovals.isEmpty {
                Section("Needs You") {
                    ForEach(pendingApprovals) { approval in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(ClutchColor.warning)
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
                        .tag(HomeSelection.thread(approval.sessionId, engine: approval.engine))
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
                        .tag(HomeSelection.thread(run.sessionId, engine: run.engine))
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
            // Quick Chat sits last, below every project and folder: it is the
            // The list renders the filtered rows, so the row that says how
            // much of it is on screen has to count the rows the user can
            // actually see.  Gate on the unfiltered store (model.sessions)
            // so a search that matches nothing still offers Load More when
            // older pages exist; the caption itself stays filtered.
            if model.hasMore && !model.sessions.isEmpty {
                Section {
                    loadMoreRow
                }
            }

            // Quick Chat sits last, below every project and folder: it is the
            // conversation without a project, not the first thing to read.
            quickChatRow
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

    /// The Quick Chat row: the conversation without a project, the one that
    /// used to be its own tab.  iOS only — the Mac keeps its own Quick Chat
    /// tab.  The row is selection-tagged like the thread rows above it.
    @ViewBuilder
    private var quickChatRow: some View {
        #if os(iOS)
        Section {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quick Chat")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Without a Project")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .tag(HomeSelection.quickChat)
            // The row is one thing to VoiceOver, not three:  the icon, the
            // title and the subtitle are combined into a single element with
            // one name, the way a thread row names itself.  The row behaves
            // as a button because tapping it opens the quick conversation.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Quick Chat, Without a Project")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("quick-chat-row")
        }
        #endif
    }

    /// The caption under the list:  how many threads are on screen.
    ///
    /// The sidecar says that older threads exist and never how many, so the
    /// count is the rows on screen and nothing more.  A filter narrows those
    /// rows to the ones that match, and the wording says so.
    private var loadMoreCaption: String {
        let count = visibleSessions.count
        let isFiltering = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isFiltering {
            return count == 1 ? "Showing 1 matching thread." : "Showing \(count) matching threads."
        }
        return count == 1 ? "Showing the newest 1 thread." : "Showing the newest \(count) threads."
    }

    /// The row that says the list stops short, and the button that widens it.
    ///
    /// The sidecar says that older threads exist and never how many, so the
    /// row says how many are on screen and nothing more.
    private var loadMoreRow: some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.tight) {
            Text(loadMoreCaption)
                .font(ClutchFont.caption)
                .foregroundStyle(.secondary)
            if SessionsClient.SessionListLimit.next(after: model.limit) != nil {
                Button("Load More") {
                    Task { await model.loadMore() }
                }
                .font(ClutchFont.captionStrong)
                .disabled(model.isLoadingMore)
            } else {
                // The sidecar caps a page, so there is nowhere wider to go.
                Text("Older threads are not listed.")
                    .font(ClutchFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, ClutchSpacing.tight)
    }

    /// One thread row with its context menu, shared by the pinned and folder
    /// sections.  The row renders without its own button: the List's
    /// selection binding is what opens the thread on a phone.
    private func threadRow(_ session: AcpSessionInfo) -> some View {
        let isSelected: Bool = {
            if case .thread(let id, let selectionEngine) = selection {
                // A thread opened on another engine is not this row:  the
                // two engines number their own sessions, so the same raw id
                // in this list is a different thread.
                return id == session.sessionId && (selectionEngine == nil || selectionEngine == engine)
            }
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
        .tag(HomeSelection.thread(session.sessionId, engine: nil))
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

    /// The threads this list already shows, by the host, engine and id that
    /// identify them.
    ///
    /// A listed thread of one engine does not hide another engine's thread
    /// that happens to carry the same raw id:  the list on screen is one
    /// engine's, and the other engine's approval still needs a row.
    private var listedThreads: Set<TurnThreadKey> {
        Set(visibleSessions.map {
            TurnThreadKey(hostId: host.id, engine: engine, sessionId: $0.sessionId)
        })
    }

    /// Approvals this device has seen on the host on screen, minus the ones
    /// already listed as rows, so a thread never appears twice in one list.
    ///
    /// The activity store holds every host this device talks to, so it is
    /// read by host: another host's approval is not this host's business.
    private var pendingApprovals: [TurnActivityApproval] {
        TurnActivity.approvalsForHomeList(
            TurnActivity.shared.approvals,
            hostId: host.id,
            listed: listedThreads
        )
    }

    /// Runs this device is streaming on the host on screen, minus the ones
    /// already listed.
    private var runningTurns: [TurnActivityRun] {
        let listed = listedThreads
        return TurnActivity.shared.runs.filter { $0.hostId == host.id && !listed.contains($0.thread) }
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
        // The bucket key is the whole path: two folders that end in the
        // same name are two folders, and merging them would file a thread
        // under a path it does not work in.
        var buckets: [String: (name: String, sessions: [AcpSessionInfo])] = [:]
        for session in unpinned {
            let path = session.cwd ?? ""
            let name = path.isEmpty ? "" : (path as NSString).lastPathComponent
            var bucket = buckets[path] ?? (name, [])
            bucket.sessions.append(session)
            buckets[path] = bucket
        }
        return buckets
            .map { path, bucket in
                HomeFolderGroup(
                    name: bucket.name.isEmpty ? "No Folder" : bucket.name,
                    path: path,
                    sessions: AcpSessionInfo.newestFirst(bucket.sessions)
                )
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.sessions.compactMap(\.updated).max() ?? .distantPast
                let rhsDate = rhs.sessions.compactMap(\.updated).max() ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.path < rhs.path
            }
    }

    /// The folder the file tree is rooted at.
    ///
    /// The open thread's own folder, so the files on screen are the ones the
    /// engine is working in.  A thread that names no folder falls back to
    /// the folder a new thread would work in.
    private var filesRoot: String {
        guard case .thread(let id, let selectionEngine) = selection else { return "" }
        // The tree starts where the open thread works, and the list holds one
        // engine's sessions:  another engine's thread with the same raw id is
        // a different thread, so its folder is not this thread's and the tree
        // opens at the host's own root rather than in the wrong place.
        let threadEngine = selectionEngine ?? engine
        guard threadEngine == engine,
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
                    // Primary throughout: the picked engine is the bar's
                    // subject, not a hint, and grey here reads as disabled.
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                        Text(engineLabel)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.primary)
                }
                .accessibilityLabel("Engine: \(engineLabel)")
            } else {
                Text(engineLabel)
                    .font(.system(size: 12, weight: .semibold))
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

    /// Every engine this host advertises, available or not.
    ///
    /// A link is validated against this rather than against the engines that
    /// can start a thread right now:  an engine whose binary is missing this
    /// morning is still an engine of this host, and an older link to one of
    /// its threads must not stop opening because of it.
    private var hostEngineIds: Set<String> {
        Set((catalog?.engines ?? []).map(\.id))
    }

    private var engineLabel: String {
        catalog?.descriptor(engine)?.label ?? EngineLabels.label(for: engine)
    }

    /// Opens the thread a link asked for.
    ///
    /// The link is taken rather than read, so the thread is opened once and
    /// not again by whatever surface happens to be on screen next.
    private func openPendingThread() {
        guard let link = threadLinkRouter.take() else { return }
        // A link that names an engine this host does not offer is dropped
        // here rather than opened, because opening its id on the sidebar's
        // engine would open a different thread than the one it named.  A
        // link that names none is not refused:  it is an older link, and it
        // opens on the engine this surface is already showing.
        guard !link.isRefused(known: hostEngineIds) else { return }
        // A link that names an engine opens on that engine, so an approval
        // Muse raised opens Muse while the sidebar is still on MiniMax Code.
        // An older link names none, and it resolves to the engine this device
        // has seen activity for only when exactly one engine has it; when
        // none or several do, the sidebar's own engine stands rather than a
        // guess at which of them the link meant.
        let opened = ThreadLink.resolveEngine(
            named: link.engine,
            activityEngines: TurnActivity.shared.enginesWithActivity(
                hostId: host.id,
                sessionId: link.sessionId
            ),
            known: hostEngineIds
        )
        selection = .thread(link.sessionId, engine: opened)
    }

    /// Opens the approvals list a link asked for.
    ///
    /// The request is taken rather than read, so the list is opened once and
    /// not again by whatever surface happens to be on screen next.
    private func openPendingApprovals() {
        guard approvalsLinkRouter.take() else { return }
        selection = .approvals
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .thread(let id, let selectionEngine):
            // Each thread gets its own view, so switching threads starts the
            // new one clean: the transcript, the plan and the pending
            // questions belong to the thread they were raised in.  A thread
            // tapped from Needs You or Running that the loaded pages do not
            // carry still opens: the load call needs only the id.
            //
            // The engine is the one the selection named, so a Muse approval
            // opens Muse while the sidebar stays where the owner left it.  The
            // view is keyed by the thread rather than by the raw id, because
            // two engines can number a session the same and those are two
            // threads.
            let threadEngine = selectionEngine ?? engine
            // The list is the sidebar engine's, so its entry is this thread's
            // only when the thread runs on that engine:  two engines number
            // their own sessions, and another engine's title and folder would
            // be the wrong thread's.
            let listed = threadEngine == engine
                ? model.sessions.first { $0.sessionId == id }
                : nil
            let session = listed ?? AcpSessionInfo(sessionId: id)
            SessionThreadView(host: host, session: session, engine: threadEngine)
                .id("\(threadEngine)|\(id)")
        case .quickChat:
            #if os(iOS)
            ChatView(activeHost: host, store: HostStore.shared)
            #endif
        case .approvals:
            // The list the Live Activity and the Control Center action
            // open:  the approvals waiting on this host, each one a way
            // into the thread that has to answer it.
            ApprovalsView(host: host) { thread in
                selection = .thread(thread.sessionId, engine: thread.engine)
            }
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
    /// Folders the caller already knows, such as the host's threads' working
    /// folders, offered as recents when the owner picked none yet.
    private let seedFolders: [String]
    let onCreated: (AcpSessionInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: NewThreadModel
    @State private var showMuseSignIn = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var isDropTargeted = false
    @State private var isShowingFolderPicker = false
    @State private var recentFolders: [String] = []
    @State private var showPathEditor = false
    @State private var pathDraft = ""
    @State private var catalog: EngineCatalog?
    @State private var selectedModelId: String?
    @State private var selectedEffort: String?

    init(
        host: ClutchHost,
        engine: String = "mcode",
        initialFolder: String = "",
        seedFolders: [String] = [],
        onCreated: @escaping (AcpSessionInfo) -> Void
    ) {
        self.host = host
        self.engine = engine
        self.initialFolder = initialFolder
        self.seedFolders = seedFolders
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
                        .foregroundStyle(ClutchColor.danger)
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
                        canAnswer: model.canAnswerPermissions,
                        answerFailures: model.permissionAnswerFailures,
                        staleAnswers: model.permissionStaleAnswers
                    ) { answer in
                        model.answerPermission(answer)
                    }
                }
                if !model.plan.isEmpty {
                    PlanPanel(entries: model.plan)
                }

                if !model.attachments.isEmpty {
                    attachmentStrip
                }
                modelBar
                HStack(alignment: .bottom, spacing: 8) {
                    // One attach control: photo, file, and paste share a
                    // sheet, so the field keeps its width on a phone.
                    Button {
                        showAttachMenu = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.title3)
                            .foregroundStyle(Color.secondary)
                    }
                    .disabled(model.isSending)
                    .accessibilityLabel("Attach Image Or File")
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
                                .foregroundStyle(ClutchColor.danger)
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
                .confirmationDialog("Attach", isPresented: $showAttachMenu, titleVisibility: .hidden) {
                    // The pickers open after the dialog dismisses:
                    // presenting synchronously from the action can drop the
                    // second presentation while the dismissal is in flight.
                    Button("Choose Photo") { DispatchQueue.main.async { showPhotoPicker = true } }
                    Button("Choose File") { DispatchQueue.main.async { showFilePicker = true } }
                    Button("Paste Image Or File") { Task { await pasteClipboard() } }
                    Button("Cancel", role: .cancel) {}
                }
                .photosPicker(
                    isPresented: $showPhotoPicker,
                    selection: $pickedPhoto,
                    matching: .images,
                    photoLibrary: .shared()
                )
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
                RecentFolderStore.seed(seedFolders, forHost: host.id)
                recentFolders = RecentFolderStore.recent(forHost: host.id)
                // The folder lives on the model, since send() reads it there;
                // the sheet's own state is just what the menu edits.
                model.workingFolder = workingFolder
                model.modelId = selectedModelId
                model.effort = selectedEffort
            }
            .task {
                await loadCatalog()
            }
            .onChange(of: workingFolder) { _, folder in
                model.workingFolder = folder
            }
            .onChange(of: selectedModelId) { _, id in
                model.modelId = id
            }
            .onChange(of: selectedEffort) { _, effort in
                model.effort = effort
            }
            .onDisappear {
                // A sheet that goes away mid-turn leaves the engine running
                // with nobody on screen to stop it, so the turn is stopped
                // with the sheet.
                model.stop()
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

    /// The engine and model the first turn will run on, above the field so
    /// they are on screen while the prompt is typed.  The thread view shows
    /// the same bar, so a model picked here is the model the thread opens
    /// with.
    private var modelBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(ClutchFont.micro)
                Text(engineLabel)
                    .font(ClutchFont.captionStrong)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.clutchSecondaryBackground, in: Capsule())
            .accessibilityLabel("Engine: \(engineLabel)")

            Menu {
                if models.isEmpty {
                    Text("Not reported")
                } else {
                    ForEach(models) { entry in
                        Button {
                            selectedModelId = entry.id
                        } label: {
                            if entry.id == selectedModelId {
                                Label(entry.displayLabel, systemImage: "checkmark")
                            } else {
                                Text(entry.displayLabel)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(modelLabel)
                        .font(ClutchFont.captionStrong)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(ClutchFont.microStrong)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.clutchSecondaryBackground, in: Capsule())
            }
            .disabled(models.isEmpty)
            .accessibilityLabel("Model: \(modelLabel)")

            if !effortLevels.isEmpty {
                Menu {
                    ForEach(effortLevels, id: \.self) { level in
                        Button {
                            selectedEffort = level
                        } label: {
                            if level == selectedEffort {
                                Label(level.capitalized, systemImage: "checkmark")
                            } else {
                                Text(level.capitalized)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.dots.needle.50percent")
                            .font(ClutchFont.micro)
                        Text((selectedEffort ?? "default").capitalized)
                            .font(ClutchFont.captionStrong)
                        Image(systemName: "chevron.down")
                            .font(ClutchFont.microStrong)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.clutchSecondaryBackground, in: Capsule())
                }
                .accessibilityLabel("Effort: \((selectedEffort ?? "default").capitalized)")
            }

            Spacer(minLength: 0)
        }
    }

    /// The engine's models, as the catalog published them.
    private var models: [EngineModel] {
        catalog?.descriptor(engine)?.models ?? []
    }

    /// The engine's effort levels, as the catalog published them.
    private var effortLevels: [String] {
        catalog?.descriptor(engine)?.effortLevels ?? []
    }

    private var engineLabel: String {
        catalog?.descriptor(engine)?.label ?? EngineLabels.label(for: engine)
    }

    /// What the model picker shows: the picked model, a plain "Default"
    /// when none is picked (the turn runs on the sidecar's own default,
    /// which the catalog order cannot name), or an honest "Not reported"
    /// when the host published nothing — never an invented name.
    private var modelLabel: String {
        if let id = selectedModelId,
           let found = catalog?.model(engineId: engine, modelId: id) {
            return found.displayLabel
        }
        if !models.isEmpty {
            return "Default"
        }
        return "Not reported"
    }

    /// Loads the catalog so the bar shows what this host really offers.  A
    /// failure falls back to what the host published last; the thread still
    /// works either way, on the sidecar's default.
    @MainActor
    private func loadCatalog() async {
        let client = EngineCatalogClient(host: host)
        if let loaded = try? await client.fetch(engine: engine) {
            catalog = loaded
        } else if let last = await client.lastKnownCatalog() {
            catalog = last
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
            Button {
                pathDraft = workingFolder
                showPathEditor = true
            } label: {
                Label("Enter Path…", systemImage: "pencil")
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
        .alert("Working Folder", isPresented: $showPathEditor) {
            TextField("Absolute Path", text: $pathDraft)
#if os(iOS)
                .autocapitalization(.none)
#endif
                .autocorrectionDisabled()
            Button("Use Folder") { useTypedPath() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type the folder on the host, starting with a slash — for example /mnt/fleet-extra/Code/Clutch.")
        }
    }

    /// Takes a typed folder path: browsing starts at the sidecar's home
    /// directory and cannot climb out of it, so a folder anywhere else —
    /// `/mnt` on a server, for example — is typed, not browsed to.
    private func useTypedPath() {
        let trimmed = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.hasPrefix("/") else {
            model.errorText = "Type an absolute folder path, starting with a slash."
            return
        }
        model.errorText = nil
        workingFolder = trimmed
        RecentFolderStore.add(trimmed, forHost: host.id)
        recentFolders = RecentFolderStore.recent(forHost: host.id)
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
    /// The model the owner picked for the first turn; nil sends the
    /// sidecar's default, the way an untouched thread keeps its own.
    var modelId: String?
    /// The reasoning effort the owner picked; nil sends the default.
    var effort: String?
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
    var pendingPermissions = PermissionRequests()
    /// How many answers did not reach the engine.
    ///
    /// The card offers the request again when this count moves, so a failed
    /// answer never leaves the card disabled for good.
    var permissionAnswerFailures = 0
    /// How many answers were dropped because the request they named was no
    /// longer the one on screen.
    var permissionStaleAnswers = 0

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
    func answerPermission(_ answer: AcpPermissionAnswer) {
        guard let request = pendingPermissions.first, let chatId else { return }
        // The request the owner was answering can turn over while they
        // confirm it.  An answer for a request that is no longer the one on
        // screen is dropped, so it cannot approve whatever replaced it.
        guard request.accepts(answer) else {
            permissionStaleAnswers += 1
            return
        }
        Task {
            let answered = await ChatSessionClient.answerPermission(
                host: host,
                sessionId: chatId,
                requestId: answer.requestId,
                optionId: answer.optionId
            )
            if answered {
                // The card only goes away once the answer is on its way, so a
                // failed answer can be tried again.
                //
                // The card that goes is the card the answer named:  the
                // request id says which one it is, so the card on screen
                // and the card the owner answered can never be different by
                // accident.
                pendingPermissions.acknowledge(requestId: answer.requestId)
            } else {
                errorText = "The permission answer did not reach the engine."
                permissionAnswerFailures += 1
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
            model: modelId ?? "",
            sessionId: nil,
            relayReceiverUid: "",
            engine: engine,
            // The chosen folder rides on the first turn: without it the
            // sidecar defaults to $HOME and the thread is stuck there.
            cwd: workingFolder.isEmpty ? nil : workingFolder,
            effort: effort,
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
                        // A request that has already been answered has no
                        // card to answer, so it raises no notification.  A
                        // request that is already on screen still has its
                        // card and still has the engine blocked on it, so
                        // the owner is woken for it again.
                        guard pendingPermissions.arrive(request).leavesACardToAnswer else { break }
                        TurnNotifier.permissionRequest(
                            threadTitle: "New Thread",
                            payload: PermissionNotificationPayload.make(
                                hostId: host.id,
                                sessionId: chatId,
                                engine: engine,
                                requestId: request.requestId,
                                denyOptionId: request.denyOptionId
                            )
                        )
                    case .plan(let entries):
                        plan = entries
                    case .done(_, _, let remote):
                        if let remote { remoteSessionId = remote }
                        pendingPermissions.clearAll()
                        // The folder worked, so the next New Thread starts here.
                        RecentFolderStore.add(workingFolder, forHost: host.id)
                    case .usage:
                        break // live usage strip is Mac-only
                    case .contextControls:
                        break // compaction controls are shown on the Mac workspace
                    case .failed(let message):
                        errorText = message
                        ErrorReporting.turnFailed(engine: engine, message: message)
                        pendingPermissions.clearAll()
                    }
                }
            } catch {
                // A stopped turn is not a failure: the owner asked for it,
                // so the sheet says nothing about it.
                if !Task.isCancelled {
                    errorText = error.localizedDescription
                    ErrorReporting.turnTransportFailed(engine: engine, error: error)
                }
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
        pendingPermissions.clearAll()
        isSending = false
    }
}
