import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers

/// Stable device UID for this Mac's 1:1 agent thread (the relay receiver).
/// iOS uses the vendor id; macOS has none, so one is minted once and kept.
enum MacChatIdentity {
    private static let key = "codes.clutch.mac-device-uid"

    static var deviceUid: String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: key), !saved.isEmpty { return saved }
        let uid = "clutch-mac-\(UUID().uuidString.prefix(8).lowercased())"
        defaults.set(uid, forKey: key)
        return uid
    }
}

/// The thread rail's width, persisted so the window reopens the way it was
/// left.  Clamped on read as well as on drag, so a stale or hand-edited value
/// can never open a rail that swallows the chat.
enum MacSidebarWidth {
    private static let key = "codes.clutch.mac-sidebar-width"
    static let fallback: CGFloat = 248
    static let range: ClosedRange<CGFloat> = 180 ... 460

    static var current: CGFloat {
        let saved = UserDefaults.standard.double(forKey: key)
        guard saved > 0 else { return fallback }
        return min(max(saved, range.lowerBound), range.upperBound)
    }

    static func save(_ width: CGFloat) {
        UserDefaults.standard.set(min(max(width, range.lowerBound), range.upperBound), forKey: key)
    }
}

/// One bubble from `GET /clutch/v1/thread`.
struct ThreadBubble: Identifiable, Equatable, Decodable {
    var id: String
    var senderUid: String
    var text: String
    /// Unix milliseconds, as the sidecar sends them.
    var sentAt: Double
    var kind: String

    var date: Date { Date(timeIntervalSince1970: sentAt / 1000) }
}

/// A prompt sent from this Mac, kept client-side: the relay only ever posts
/// agent bubbles to the cloud thread, so user turns would otherwise vanish
/// on relaunch. Capped; same device only.
struct LocalPrompt: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var text: String
    var at: Date
}

/// Minimal client for `GET /clutch/v1/thread` (see `chat-bridge.ts`). Same
/// chat-token gate as the send path; the CometChat key never leaves the
/// sidecar.
struct ChatThreadClient {
    var host: ClutchHost

    func fetch(deviceUid: String, limit: Int = 50) async throws -> [ThreadBubble] {
        guard let token = host.chatToken, !token.isEmpty else { throw ChatClientError.missingToken }
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        comps.path = "/clutch/v1/thread"
        comps.queryItems = [
            URLQueryItem(name: "uid", value: deviceUid),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = comps.url else { throw ChatClientError.badHost }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let status = (resp as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Payload: Decodable { var messages: [ThreadBubble] }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.messages ?? []
    }
}

/// Which backend a Mac chat turn runs through. DeepSeek and MiniMax route
/// by model on the sidecar; MiniMax Code and Muse Code resume a direct
/// thread of that engine.
enum ChatEngine: String, CaseIterable, Identifiable {
    case deepseek
    case minimax
    case mcode
    case muse

    var id: String { rawValue }

    /// The engine id the sidecar knows this one by.
    var sidecarId: String { rawValue }

    var label: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .minimax: return "MiniMax"
        case .mcode: return "MiniMax Code"
        case .muse: return "Muse Code"
        }
    }
}

/// Which conversation the Mac surface shows.
///
/// The workspace is the coding surface: an engine, the threads it owns, and
/// the transcript.  The agent chat is the relay conversation, where a paired
/// agent answers through the sidecar.  They are two kinds of conversation
/// rather than two engines, so the owner picks one and the engine picker
/// then says which engine runs it.
public enum MacSurface: String {
    case workspace
    case agent
}

/// A native macOS conversation surface: the agent thread renders from the sidecar
/// thread endpoint (the CometChat kit SDK is iOS-only), the native input bar
/// owns the send path through `ChatSessionClient`, and the turn streams back
/// live into a pending bubble before the authoritative refresh.
public struct ChatView: View {
    @Environment(\.openWindow) private var openWindow
    private enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        var id: String
        var text: String
        var date: Date
        var fromAgent: Bool
        var isCard: Bool
        var isThought: Bool = false
        /// Non-nil for tool-call rows: `running` / `completed` / `failed`.
        var toolStatus: String? = nil
        /// How deep the call sits under the call that made it.
        var toolDepth: Int = 0
        /// What the tool was asked to do, as the engine wrote it.
        var toolInput: String? = nil
    }

    @State private var phase: Phase = .loading
    @State private var showingMuseSignIn = false
    /// Fixed by the top-level tab, so Workspace and Agent Chat stay distinct.
    private let surface: MacSurface
    @State private var engine: ChatEngine = .deepseek
    @State private var agentBubbles: [ThreadBubble] = []
    @State private var localPrompts: [LocalPrompt] = MacChatStore.loadPrompts()
    @State private var codeChatId: String?
    @State private var codeRemoteId: String?
    @State private var codeCwd: String?
    @State private var codeLoaded: [AcpHistoryEntry] = []
    @State private var codePending: [LocalPrompt] = []
    @State private var showingSessions = false
    @State private var showingSidebar = true
    @State private var sidebarSessions: [AcpSessionInfo] = []
    @State private var sidebarLoading = false
    @State private var sidebarError: String?
    @State private var sidebarLoadingId: String?
    @State private var failedSidebarSession: AcpSessionInfo?
    @State private var sessionLoadTask: Task<Void, Never>?
    @State private var sessionLoadToken = UUID()
    /// User-resized rail width.  Persisted so the window comes back the way it
    /// was left; the drag itself lives in `ThreadSidebar`'s trailing edge.
    @State private var sidebarWidth: CGFloat = MacSidebarWidth.current
    @State private var sidebarProjects: [SessionsClient.Project] = []
    @State private var sidebarFolderScope: String?
    @State private var sidebarFolders: Set<String> = []
    @State private var sidebarLimit = MacThreadFolderScope.pageSize
    @State private var sidebarHasMore = false
    @State private var loadingMoreSidebar = false
    @State private var previewSession: SessionsClient.PreviewSession?
    @State private var previewTarget: AcpSessionInfo?
    @State private var previewLoadingId: String?
    @State private var previewError: String?
    @State private var previewToken = UUID()
    @State private var didConsumeInitialThreadRequest = false
    @State private var runningSessionRegistry = MacRunningSessionRegistry.shared
    @State private var runningRegistryOwner = UUID()
    /// When true the sidebar also lists archived threads so they can be
    /// restored; archiving a thread would otherwise make it unreachable.
    @State private var showArchived = false
    /// Newest real usage record for the open thread, pushed by the sidecar's
    /// SSE stream.  Nil until the engine reports one.
    @State private var activeUsage: AcpSessionUsage?
    @State private var activeContextControls: MuseContextControls?
    @State private var contextControlsRevision = UUID()
    @State private var draft: String = ""
    @State private var sessionId: String?
    @State private var sending: Bool = false
    @State private var liveTurn = ChatTurnBuffer()
    @State private var turnGeneration = UUID()
    @State private var queuedMessages: [QueuedMessage] = []
    @State private var queuePaused = false
    @State private var steering = false
    @State private var steeringSupported = false
    @State private var followLatest = true

    private struct QueuedMessage: Identifiable {
        let id = UUID()
        let text: String
        let images: [ChatAttachment]
        let model: String
        let effort: String?
        let museOptions: MuseLaunchOptions?
        let contextPolicy: MuseContextPolicy?
        let hostId: UUID?
        let engine: ChatEngine
        let surface: MacSurface
        let remoteId: String?
    }
    @State private var thoughtLine: String?
    @State private var sendError: String?
    /// The engine's execution plan, as it last reported it.
    @State private var plan: [AcpPlanEntry] = []
    /// The permission requests the engine is waiting on, oldest first.
    ///
    /// The engine asks one question at a time, but a second request can land
    /// before the first is answered.  The queue keeps the earlier one on
    /// screen instead of dropping it behind the newer card.
    @State private var pendingPermissions: [AcpPermissionRequest] = []

    /// The request on screen.
    private var pendingPermission: AcpPermissionRequest? { pendingPermissions.first }
    /// nil until the first health check lands; drives the header status dot.
    @State private var sidecarReachable: Bool?
    @State private var mcodeAvailable: Bool = true
    @State private var sendTask: Task<Void, Never>?
    @State private var showingCwdEditor = false
    /// Whether the file browser is open.
    @State private var showingFiles = false
    @State private var cwdDraft: String = ""
    @State private var pinnedIds: Set<String> = []
    /// Tool calls from the in-flight turn; folded into the transcript on done.
    private var streamingText: String { liveTurn.text }
    private var liveTools: [ChatTurnBuffer.Tool] { liveTurn.tools }
    @State private var showFind = false
    @State private var findText = ""
    @State private var findFocusId: String?
    @State private var findNonce = 0
    @StateObject private var dictation = DictationController()
    @State private var draftBase = ""
    /// Images attached to the next turn, the way the web canvas attaches
    /// files to a message.
    @State private var attachments: [ChatAttachment] = []
    /// The host's engine catalog: which engines it runs, which models each
    /// offers, and which effort levels it accepts.
    @State private var catalog: EngineCatalog?
    /// The model the owner picked, if any.  Nil means "the engine's own
    /// default": a thread keeps the model it was created with unless the
    /// owner picks another one.
    @State private var selectedModel: String?
    /// The reasoning effort the owner picked, if any.
    @State private var selectedEffort: String?
    @State private var showingModelVisibility = false
    @AppStorage(ModelVisibilityPreferences.storageKey)
    private var modelVisibilityPreferencesJSON = ""
    @AppStorage(MuseLaunchPreferences.storageKey)
    private var museLaunchPreferencesJSON = ""
    @AppStorage(MuseContextPreferences.storageKey)
    private var museContextPreferencesJSON = ""

    let activeHost: ClutchHost?

    /// The paired-host store.  The Mac app pairs the same way the phone
    /// does, so the chat surface can point at another machine — a Linux
    /// server running Muse Code, for example — instead of only this Mac.
    let store: HostStore?
    private let initialThreadRequest: MacThreadWindowRequest?

    public init(
        activeHost: ClutchHost? = nil,
        store: HostStore? = nil,
        initialSurface: MacSurface = .workspace,
        initialThreadRequest: MacThreadWindowRequest? = nil
    ) {
        self.activeHost = activeHost
        self.store = store
        self.surface = initialSurface
        self.initialThreadRequest = initialThreadRequest
    }

    private var deviceUid: String { MacChatIdentity.deviceUid }

    /// True when the coding workspace is showing.
    ///
    /// The workspace keeps an engine's threads and its transcript; the agent
    /// chat keeps the relay conversation instead.  Everything that used to
    /// ask whether an engine had threads now asks this, because every engine
    /// Clutch can run has them.
    private var isWorkspace: Bool { surface == .workspace }

    /// The engines this host can run, from its catalog.  A host that answers
    /// with no catalog falls back to the built-in list, so the picker is
    /// never empty.
    private var availableEngines: [ChatEngine] {
        guard let catalog else { return ChatEngine.allCases }
        let listed = ChatEngine.allCases.filter { candidate in
            guard let descriptor = catalog.descriptor(candidate.sidecarId) else { return false }
            return descriptor.available
        }
        return listed.isEmpty ? ChatEngine.allCases : listed
    }

    /// The engines the engine picker offers right now.
    ///
    /// The workspace offers every engine the host runs, because every one of
    /// them keeps a thread log.  The agent chat offers the hosted engines,
    /// because that is what the relay answers with.
    private var offeredEngines: [ChatEngine] {
        guard !isWorkspace else { return availableEngines }
        let relay = availableEngines.filter { $0 == .deepseek || $0 == .minimax }
        // A host that runs neither hosted engine still gets a picker.
        return relay.isEmpty ? availableEngines : relay
    }

    /// The models the picked engine offers, from the catalog.
    private var engineModels: [EngineModel] {
        catalog?.descriptor(engine.sidecarId)?.models ?? []
    }

    private var visibleEngineModels: [EngineModel] {
        ModelVisibilityPreferences.visibleModels(
            all: engineModels,
            engineID: engine.sidecarId,
            hostKey: modelVisibilityHostKey,
            preferencesJSON: modelVisibilityPreferencesJSON
        )
    }

    private var modelVisibilityHostKey: String {
        activeHost?.id.uuidString ?? "unpaired"
    }

    private var museLaunchOptions: MuseLaunchOptions? {
        guard engine == .muse, activeHost != nil else { return nil }
        return MuseLaunchPreferences.options(
            hostKey: modelVisibilityHostKey,
            preferencesJSON: museLaunchPreferencesJSON
        )
    }

    private var museContextPolicy: MuseContextPolicy? {
        guard engine == .muse, activeHost != nil else { return nil }
        return MuseContextPreferences.policy(
            hostKey: modelVisibilityHostKey,
            preferencesJSON: museContextPreferencesJSON
        )
    }

    private var canManuallyCompactContext: Bool {
        isWorkspace && engine == .muse && codeRemoteId != nil && codeChatId != nil
            && !sending && !isPreviewingThread && activeContextControls?.supportsCompaction == true
    }

    private var sidebarFolderOptions: [String] {
        MacThreadFolderScope.folderOptions(from: sidebarFolders)
    }

    /// The effort levels the picked engine accepts, from the catalog.
    private var engineEfforts: [String] {
        catalog?.descriptor(engine.sidecarId)?.effortLevels ?? []
    }

    /// Load the host's catalog.
    ///
    /// The catalog's first row is only what the picker shows by default; it
    /// is not sent with a turn unless the owner picked it, because a
    /// resumed thread keeps the model and effort it was created with.
    private func loadCatalog(expectedGeneration: UUID? = nil, for requestedEngine: ChatEngine? = nil) async {
        guard let host = activeHost else { return }
        let targetEngine = requestedEngine ?? engine
        let loaded = try? await EngineCatalogClient(host: host).fetch(engine: targetEngine.sidecarId)
        guard activeHost?.id == host.id,
              engine == targetEngine,
              expectedGeneration == nil || turnGeneration == expectedGeneration else { return }
        guard let loaded else { return }
        catalog = loaded
        // A choice that the new host does not offer is dropped rather than
        // sent and refused.
        let descriptor = loaded.descriptor(engine.sidecarId)
        if let selectedModel, descriptor?.models.contains(where: { $0.id == selectedModel }) != true {
            self.selectedModel = nil
        }
        if let selectedEffort, descriptor?.effortLevels.contains(selectedEffort) != true {
            self.selectedEffort = nil
        }
    }

    /// What the model picker shows when the owner has not picked one: the
    /// engine itself.  Naming a model would claim the thread runs it, and
    /// an untouched thread keeps whatever model it was created with —
    /// which the client does not know.
    private var displayModel: String {
        if let selectedModel {
            return engineModels.first(where: { $0.id == selectedModel })?.displayLabel ?? selectedModel
        }
        if let reported = activeUsage?.model ?? sidebarSessions.first(where: { $0.sessionId == codeRemoteId })?.model {
            return engineModels.first(where: { $0.id == reported })?.displayLabel ?? reported
        }
        return "Default Model"
    }

    private var rows: [Row] {
        if isWorkspace { return codeRows }
        let promptRows = localPrompts.map {
            Row(id: $0.id.uuidString, text: $0.text, date: $0.at, fromAgent: false, isCard: false)
        }
        let bubbleRows = agentBubbles.map {
            Row(id: $0.id, text: $0.text, date: $0.date, fromAgent: $0.senderUid != deviceUid, isCard: $0.kind == "card")
        }
        let toolRows = liveTools.map { tool in
            Row(
                id: "live-\(tool.id)",
                text: tool.name,
                date: Date(),
                fromAgent: true,
                isCard: false,
                toolStatus: tool.status,
                toolDepth: ToolCallDepth.depth(of: tool.id, parents: toolParents),
                toolInput: tool.input
            )
        }
        return (promptRows + bubbleRows).sorted { $0.date < $1.date } + toolRows
    }

    /// MiniMax Code rows keep server order (replayed history is already
    /// chronological); in-flight prompts and the live bubble append after.
    private var codeRows: [Row] {
        let parents = toolParents
        var out = codeLoaded.enumerated().map { index, entry in
            Row(
                id: "code-\(index)-\(entry.text.hashValue)",
                text: entry.text,
                date: Date(),
                fromAgent: entry.kind != "user_message_chunk",
                isCard: false,
                isThought: entry.kind == "agent_thought_chunk",
                toolStatus: entry.isTool ? (entry.toolStatus ?? "completed") : nil,
                toolDepth: entry.isTool ? ToolCallDepth.depth(of: entry.toolCallId, parents: parents) : 0,
                toolInput: entry.toolInput
            )
        }
        out += codePending.map {
            Row(id: $0.id.uuidString, text: $0.text, date: $0.at, fromAgent: false, isCard: false)
        }
        out += liveTools.map { tool in
            Row(
                id: "live-\(tool.id)",
                text: tool.name,
                date: Date(),
                fromAgent: true,
                isCard: false,
                toolStatus: tool.status,
                toolDepth: ToolCallDepth.depth(of: tool.id, parents: parents),
                toolInput: tool.input
            )
        }
        return out
    }

    /// Which call each tool call ran under.
    ///
    /// A tool that runs other tools is the parent of them, and the clients
    /// show that as a tree: the children hang under the call that made them.
    private var toolParents: [String: String] {
        var parents: [String: String] = [:]
        for entry in codeLoaded where entry.isTool {
            guard let id = entry.toolCallId, let parent = entry.parentToolCallId else { continue }
            parents[id] = parent
        }
        for tool in liveTools {
            guard let parent = tool.parentId else { continue }
            parents[tool.id] = parent
        }
        return parents
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let maximumSidebarWidth = max(
                    0,
                    min(MacSidebarWidth.range.upperBound, geometry.size.width - 486)
                )
                let visibleSidebarWidth = min(sidebarWidth, maximumSidebarWidth)

                HStack(spacing: 0) {
                    if isWorkspace && showingSidebar {
                        ThreadSidebar(
                            sessions: sidebarSessions,
                            selectedId: previewTarget?.sessionId ?? previewSession?.remoteSessionId ?? codeRemoteId,
                            loading: sidebarLoading,
                            loadingId: previewLoadingId ?? sidebarLoadingId,
                            errorText: sidebarError,
                            projects: sidebarProjects,
                            onLoadDetails: engine == .muse ? { session in
                                guard let host = activeHost else { throw ChatClientError.badHost }
                                return try await SessionsClient(host: host).details(
                                    sessionId: session.sessionId,
                                    cwd: session.cwd
                                )
                            } : nil,
                            onSelect: selectSidebarSession,
                            onNew: { startMcodeThread() },
                            onNewWindow: openNewThreadWindow,
                            onRefresh: { Task { await loadSidebarSessions() } },
                            onRetry: {
                                if let failedSidebarSession {
                                    openSession(failedSidebarSession, fromSidebar: true)
                                } else {
                                    Task { await loadSidebarSessions() }
                                }
                            },
                            onAction: { action, session in handle(action, session) },
                            showArchived: showArchived,
                            onToggleArchived: {
                                showArchived.toggle()
                                Task { await loadSidebarSessions() }
                            },
                            pinnedIds: pinnedIds,
                            onTogglePin: { session in
                                guard let host = activeHost else { return }
                                ThreadPinStore.toggle(session.sessionId, forHost: host.id)
                                pinnedIds = ThreadPinStore.pinnedIDs(forHost: host.id)
                            },
                            folderScope: sidebarFolderScope,
                            folders: sidebarFolderOptions,
                            onChooseFolderScope: { folder in
                                guard folder != sidebarFolderScope else { return }
                                sidebarFolderScope = folder
                                sidebarLimit = MacThreadFolderScope.pageSize
                                sidebarHasMore = false
                                Task { await loadSidebarSessions() }
                            },
                            canLoadMore: sidebarHasMore,
                            isLoadingMore: loadingMoreSidebar,
                            onLoadMore: loadMoreSidebarSessions,
                            fixedWidth: visibleSidebarWidth,
                            onResize: { width in
                                sidebarWidth = min(width, maximumSidebarWidth)
                            },
                            onResizeEnd: { width in
                                // Persist once when the drag finishes; saving on
                                // every drag event hammered UserDefaults per frame.
                                let clampedWidth = min(width, maximumSidebarWidth)
                                sidebarWidth = clampedWidth
                                MacSidebarWidth.save(clampedWidth)
                            }
                        )
                        Divider()
                    }
                    chatPane
                        .frame(minWidth: 480)
                }
            }
            .navigationTitle(isWorkspace ? "Workspace" : "Agent Chat")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showFind.toggle()
                        if !showFind { findText = ""; findFocusId = nil }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel(showFind ? "Hide Find" : "Find In Thread")
                    .help("Find In Thread (⌘F)")
                    .keyboardShortcut("f", modifiers: .command)
                    Menu {
                        Button("Copy Transcript") { copyTranscript() }
                        Button("Save Transcript…") { saveTranscript() }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export Transcript")
                    .help("Export Transcript")
                    if isWorkspace {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showingSidebar.toggle() }
                        } label: {
                            Image(systemName: "sidebar.leading")
                        }
                        .accessibilityLabel(showingSidebar ? "Hide Threads" : "Show Threads")
                        .help(showingSidebar ? "Hide threads" : "Show threads")
                    }
                }
            }
        }
        .task(id: activeHost?.pairingKey) {
            await prepare()
        }
        .task(id: engine) {
            if isWorkspace { await loadSidebarSessions() }
        }
        .sheet(isPresented: $showingMuseSignIn) {
            if let host = activeHost {
                EngineSignInView(host: host) {
                    sendError = nil
                    sidebarError = nil
                    Task {
                        await loadCatalog()
                        await loadSidebarSessions()
                    }
                }
            }
        }
        .sheet(isPresented: $showingSessions) {
            if let host = activeHost {
                MacSessionsSheet(host: host, engine: engine.sidecarId) { _, chatId, remoteId, cwd, history, contextControls in
                    adopt(chatId: chatId, remoteId: remoteId, cwd: cwd, history: history, for: engine, contextControls: contextControls)
                }
            }
        }
        .sheet(isPresented: $showingFiles) {
            if let host = activeHost {
                FilesView(host: host, root: codeCwd ?? "")
                    .frame(minWidth: 480, minHeight: 420)
            }
        }
        .onChange(of: activeHost?.id) { _, _ in
            cancelSessionLoad()
            catalog = nil
            selectedModel = nil
            selectedEffort = nil
            // A different host means a different engine catalog and a
            // different thread list; both are re-read by prepare(), and the
            // stale list goes first so the rail never shows another
            // machine's threads.
            sidebarSessions = []
            sessionId = nil
            codeChatId = nil
            codeRemoteId = nil
            codeLoaded = []
            codePending = []
            previewSession = nil
            previewTarget = nil
            setContextControls(nil)
            previewError = nil
            previewLoadingId = nil
            sidebarFolderScope = nil
            sidebarFolders = []
            sidebarLimit = MacThreadFolderScope.pageSize
            sidebarHasMore = false
            resetTurnState()
            Task { await prepare() }
        }
        .background {
            MacWindowCloseObserver {
                Task { @MainActor in
                    runningSessionRegistry.release(owner: runningRegistryOwner)
                }
            }
            .frame(width: 1, height: 1)
            .opacity(0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }

    private var chatPane: some View {
        VStack(spacing: 0) {
            if !isPreviewingThread {
                modelStrip
            }
            if isWorkspace && !isPreviewingThread {
                cwdBar
            }
            if showFind && !isPreviewingThread {
                findBar
            }
            Divider()
            if hasActivity && !isPreviewingThread {
                MacWorkspacePanels(responseText: streamingText) {
                    threadSurface
                } activity: {
                    activitySurface
                }
            } else {
                threadSurface
            }
            if let request = pendingPermission, !isPreviewingThread {
                PermissionCard(request: request) { optionId in
                    answerPermission(optionId)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            if !queuedMessages.isEmpty && !isPreviewingThread {
                queuedMessagesPanel
            }
            if let previewSession {
                previewActionBar(for: previewSession)
            }
            if canManuallyCompactContext {
                HStack(spacing: 8) {
                    if let occupancy = activeContextControls?.occupancyPercent {
                        Text("Context \(occupancy, specifier: "%.0f")%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Compact Context", systemImage: "arrow.down.right.and.arrow.up.left") {
                        compactContext()
                    }
                    .buttonStyle(.bordered)
                    .help("Ask Muse to compact this thread's context")
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            MacChatInputBar(
                draft: $draft,
                sending: sending,
                onSend: { send(draft) },
                onStop: { stop() },
                onQueue: { queueDraft() },
                onSteer: { steerDraft() },
                canSteer: steeringSupported,
                isSteering: steering,
                isDictating: dictation.isRecording,
                onMic: {
                    if !dictation.isRecording { draftBase = draft }
                    dictation.toggle()
                },
                attachments: attachments,
                onAttach: { attachImage() },
                onRemoveAttachment: { attachment in
                    attachments.removeAll { $0.id == attachment.id }
                }
            )
            .disabled(previewSession != nil || previewLoadingId != nil || previewError != nil)
        }
        .onChange(of: dictation.transcript) { _, text in
            guard dictation.isRecording || !text.isEmpty else { return }
            draft = draftBase + (draftBase.isEmpty || text.isEmpty ? "" : " ") + text
        }
    }

    private var hasActivity: Bool {
        sending || !plan.isEmpty || sendError != nil
    }

    private var isPreviewingThread: Bool {
        previewSession != nil || previewLoadingId != nil || previewError != nil
    }

    private var activitySurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sending {
                if !streamingText.isEmpty {
                    liveBubble
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                }
            }
            if let thought = thoughtLine, !thought.isEmpty {
                thoughtRow(thought)
            }
            Color.clear.frame(height: 1).id("current-response-end")
            if let error = sendError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
            }
            if !plan.isEmpty {
                PlanPanel(entries: plan)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var queuedMessagesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Queued Messages (\(queuedMessages.count))")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if !sending {
                    Button("Send Next") {
                        queuePaused = false
                        sendNextQueuedMessage()
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(queuedMessages) { message in
                        HStack(spacing: 8) {
                            Text(message.text)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                queuedMessages.removeAll { $0.id == message.id }
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove Queued Message")
                        }
                    }
                }
            }
            .frame(height: CGFloat(min(queuedMessages.count, 4)) * 22)
        }
        .padding(10)
        .background(Color.clutchSecondaryBackground)
    }

    // MARK: - Find In Thread

    private var findMatches: [Row] {
        let needle = findText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return rows.filter { $0.text.lowercased().contains(needle) }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find In Thread", text: $findText)
                .textFieldStyle(.plain)
                .onSubmit { stepFind(forward: true) }
            Text(findText.isEmpty ? "" : "\(findMatches.count) match\(findMatches.count == 1 ? "" : "es")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                stepFind(forward: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(findMatches.isEmpty)
            .accessibilityLabel("Previous Match")
            Button {
                stepFind(forward: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(findMatches.isEmpty)
            .accessibilityLabel("Next Match")
            Button {
                showFind = false
                findText = ""
                findFocusId = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Find")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.clutchSecondaryBackground.opacity(0.6))
    }

    private func stepFind(forward: Bool) {
        let matches = findMatches
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex(where: { $0.id == findFocusId })
        let next: Int
        if let current {
            next = (current + (forward ? 1 : -1) + matches.count) % matches.count
        } else {
            next = forward ? 0 : matches.count - 1
        }
        findFocusId = matches[next].id
        findNonce += 1
    }

    // MARK: - Working Directory

    /// Where a new MiniMax Code thread will start, and the folder the open
    /// thread lives in.  MiniMax Code refuses to resume a thread from a
    /// different folder than the one it was created in, so this is shown
    /// always — not buried — and changing it applies to the next new thread.
    private var cwdBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(displayCwd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(displayCwd)
            Spacer(minLength: 0)
            // The files of the working folder, the way the web canvas shows
            // them beside the thread rail.
            Button("Files") { showingFiles = true }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Browse the files in the working folder")
            Button("Choose…") { chooseCwd() }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Choose the working folder for the next new thread")
            Button("Edit") {
                cwdDraft = codeCwd ?? ""
                showingCwdEditor = true
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .help("Type a working directory path")
            .popover(isPresented: $showingCwdEditor) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Working Directory")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("Path", text: $cwdDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 340)
                    Text(Copy.gap(
                        "Applies to the next new thread.",
                        "An open thread keeps the folder it was created in."
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 340, alignment: .leading)
                    HStack {
                        Spacer()
                        Button("Cancel") { showingCwdEditor = false }
                        Button("Use Folder") {
                            let trimmed = cwdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            codeCwd = trimmed.isEmpty ? nil : trimmed
                            showingCwdEditor = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.clutchSecondaryBackground.opacity(0.6))
    }

    private var displayCwd: String {
        if let cwd = codeCwd, !cwd.isEmpty { return cwd }
        if let selected = sidebarSessions.first(where: { $0.sessionId == codeRemoteId })?.cwd, !selected.isEmpty { return selected }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func chooseCwd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: displayCwd)
        if panel.runModal() == .OK, let url = panel.url {
            codeCwd = url.path
        }
    }

    /// Attach an image to the next turn, the way the web canvas attaches a
    /// file.  The bytes travel with the prompt, because the server has no
    /// access to this Mac's filesystem.
    private func attachImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, UTType(filenameExtension: "webp") ?? .image]
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let attachment = ChatAttachment.from(data: data, name: url.lastPathComponent) else { continue }
            attachments.append(attachment)
        }
    }

    // MARK: - Header

    private var modelStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(offeredEngines) { candidate in
                        Button {
                            selectEngine(candidate)
                        } label: {
                            if candidate == engine {
                                Label(candidate.label, systemImage: "checkmark")
                            } else {
                                Text(candidate.label)
                            }
                        }
                        .keyboardShortcut(engineShortcut(for: candidate), modifiers: [.command, .option])
                    }
                } label: {
                    pickerLabel(entryLabel: engine.label, symbol: "cpu")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Engine: \(engine.label)")
                .help("Choose engine (⌘⌥1–4)")

                Spacer(minLength: 8)

                if engine == .muse {
                    Button("Muse Account") { showingMuseSignIn = true }
                        .buttonStyle(.borderless)
                        .help("Open Muse sign-in and account recovery")
                }

                if isWorkspace {
                    Button {
                        Task { await loadSidebarSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Refresh Threads")
                    .help("Refresh Threads")
                }

                if let host = activeHost, let store {
                    HostSwitcher(host: host, store: store, compact: true)
                        .menuStyle(.borderlessButton)
                        .disabled(sending || !queuedMessages.isEmpty)
                        .frame(maxWidth: 220, alignment: .trailing)
                        .help(statusHelp(for: host))
                }
            }

            if !engineModels.isEmpty || !engineEfforts.isEmpty {
                HStack(spacing: 8) {
                    if !engineModels.isEmpty {
                        Menu {
                            Button {
                                selectedModel = nil
                            } label: {
                                if selectedModel == nil {
                                    Label("Default Model", systemImage: "checkmark")
                                } else {
                                    Text("Default Model")
                                }
                            }
                            Divider()
                            ForEach(visibleEngineModels) { entry in
                                Button {
                                    selectedModel = entry.id
                                } label: {
                                    if entry.id == selectedModel {
                                        Label(entry.displayLabel, systemImage: "checkmark")
                                    } else {
                                        Text(entry.displayLabel)
                                    }
                                }
                            }
                            if visibleEngineModels.isEmpty {
                                Text("No Models Visible")
                            }
                            Divider()
                            Button("Choose Models…") {
                                showingModelVisibility = true
                            }
                        } label: {
                            pickerLabel(entryLabel: displayModel, symbol: "cpu")
                        }
                        .accessibilityLabel(selectedModel.map { "Model: \($0)" } ?? "Model: engine default")
                        .menuIndicator(.hidden)
                        .help(selectedModel ?? "Choose a model; the default keeps the engine's thread model")
                    }

                    if !engineEfforts.isEmpty {
                        Menu {
                            ForEach(engineEfforts, id: \.self) { level in
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
                            pickerLabel(entryLabel: (selectedEffort ?? "Default Effort").capitalized, symbol: "gauge.with.dots.needle.50percent")
                        }
                        .accessibilityLabel("Reasoning Effort: \(selectedEffort?.capitalized ?? "Default")")
                        .menuIndicator(.hidden)
                    }

                    Spacer(minLength: 0)
                }
            }

            if engine == .mcode {
                HStack(spacing: 8) {
                    if !mcodeAvailable {
                        Label("MiniMax Code Not Found On Host", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .help("MiniMax Code is not installed or signed in on this host.")
                    }
                    usageStrip
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.clutchBackground)
        .sheet(isPresented: $showingModelVisibility) {
            modelVisibilitySheet
        }
    }

    private var modelVisibilitySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose Models")
                        .font(.headline)
                    Text("Choose which models appear in the \(engine.label) picker.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Defaults") {
                    modelVisibilityPreferencesJSON = ModelVisibilityPreferences.restoringDefaultsJSON(
                        engineID: engine.sidecarId,
                        hostKey: modelVisibilityHostKey,
                        preferencesJSON: modelVisibilityPreferencesJSON
                    ) ?? ""
                }
            }

            List {
                ForEach(engineModels) { model in
                    Toggle(isOn: modelVisibilityBinding(for: model)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayLabel)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            if model.id != model.displayLabel {
                                Text(model.id)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.plain)

            HStack {
                Spacer()
                Button("Done") { showingModelVisibility = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 380)
    }

    private func modelVisibilityBinding(for model: EngineModel) -> Binding<Bool> {
        Binding(
            get: { visibleEngineModels.contains(where: { $0.id == model.id }) },
            set: { isVisible in
                modelVisibilityPreferencesJSON = ModelVisibilityPreferences.settingVisible(
                    isVisible,
                    modelID: model.id,
                    all: engineModels,
                    engineID: engine.sidecarId,
                    hostKey: modelVisibilityHostKey,
                    preferencesJSON: modelVisibilityPreferencesJSON
                )
            }
        )
    }

    private func engineShortcut(for engine: ChatEngine) -> KeyEquivalent {
        switch engine {
        case .deepseek: return "1"
        case .minimax: return "2"
        case .mcode: return "3"
        case .muse: return "4"
        }
    }

    // MARK: - Usage

    /// Live engine facts for the open thread.
    ///
    /// Every value here came from the engine's own accounting record.  When the
    /// engine has not reported one —  a fresh thread, or a bridge that sends no
    /// usage — the strip says so instead of showing a placeholder percentage
    /// derived from a character count.
    @ViewBuilder
    private var usageStrip: some View {
        if engine == .mcode || engine == .muse {
            let rateLabel = ThreadMetricPresentation.usageStripRateLabel(
                engineID: engine.rawValue,
                usage: activeUsage
            )
            let occupancy = currentContextOccupancyLabel
            HStack(spacing: 8) {
                if let rateLabel {
                    metric(icon: "speedometer", value: rateLabel)
                }
                if let occupancy {
                    metric(icon: "chart.pie.fill", value: occupancy)
                }
                if rateLabel == nil && occupancy == nil {
                    Text("Context and response rate not reported yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var currentContextOccupancyLabel: String? {
        if let usage = activeUsage,
           (usage.contextUsedTokens != nil || usage.totalTokens > 0),
           let occupancy = usage.occupancyLabel {
            return occupancy
        }
        guard let controls = activeContextControls,
              let percent = controls.occupancyPercent,
              let used = controls.contextUsedTokens,
              let window = controls.contextWindow else { return nil }
        return String(
            format: "%.0f%% · %@ / %@",
            percent,
            AcpSessionUsage.compact(used),
            AcpSessionUsage.compact(window)
        )
    }

    private func metric(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .help(value)
    }

    private func pickerLabel(entryLabel: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11))
            Text(entryLabel)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.clutchSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func selectEngine(_ next: ChatEngine) {
        guard next != engine else { return }
        guard queuedMessages.isEmpty else {
            sidebarError = "Send or remove queued messages before changing engines."
            return
        }
        guard !sending else {
            sidebarError = "Finish or stop the current turn before changing engines."
            return
        }
        cancelSessionLoad()
        engine = next
        previewSession = nil
        previewTarget = nil
        setContextControls(nil)
        previewError = nil
        previewLoadingId = nil
        sidebarFolderScope = nil
        sidebarFolders = []
        sidebarLimit = MacThreadFolderScope.pageSize
        sidebarHasMore = false
        // Each surface keeps its own engine: the workspace's choice is what
        // a relaunch returns to, and the agent chat's choice never
        // overwrites it.
        if isWorkspace {
            MacEngineStore.save(next)
        } else {
            MacAgentEngineStore.save(next)
        }
        resetTurnState()
        sessionId = nil
        if isWorkspace {
            // The saved thread belongs to the previous engine: restoring it
            // would adopt its engine back over the choice just made, so it
            // is dropped and prepare() starts the new engine empty.  Moving
            // between engines cannot — one slot holds one thread.  Clearing
            // it is what the sidebar's New Thread button is for
            // (startMcodeThread).
            if let host = activeHost,
               let saved = MacMcodeStore.load(for: host),
               saved.engineId != next.sidecarId {
                MacMcodeStore.clear(for: host)
            }
            codeChatId = nil
            codeRemoteId = nil
            codeCwd = nil
            codeLoaded = []
            codePending = []
            Task { await prepare(preferredEngine: next) }
            return
        }
        // The agent engines keep their own model names; a model chosen for
        // another engine does not carry over.
        selectedModel = nil
        Task {
            await loadCatalog()
            await prepare(preferredEngine: next)
        }
    }

    private func statusHelp(for host: ClutchHost) -> String {
        switch sidecarReachable {
        case true: return "\(host.name): sidecar reachable"
        case false: return "\(host.name): sidecar unreachable — check Tailscale and that the chat bridge is running there"
        case nil: return host.name
        }
    }

    private func checkSidecar() async {
        guard let host = activeHost else { return }
        do {
            let health = try await SessionsClient(host: host).health()
            guard activeHost?.id == host.id else { return }
            sidecarReachable = health.ok
            mcodeAvailable = health.mcodeAvailable
        } catch {
            guard activeHost?.id == host.id else { return }
            sidecarReachable = false
        }
    }

    // MARK: - Thread

    @ViewBuilder
    private var threadSurface: some View {
        if activeHost == nil {
            Spacer()
            MacChatSetupCard(
                symbol: "laptopcomputer.and.arrow.down",
                title: "No Host Paired",
                message: "Pair with the local sidecar from the Hosts tab to start chatting."
            )
            Spacer()
        } else {
            if let previewSession {
                previewSurface(previewSession)
            } else if let previewLoadingId {
                VStack(spacing: 10) {
                    ProgressView("Loading Thread Preview…")
                    Text(previewLoadingId)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Return To Current Thread") {
                        returnFromPreview()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let previewError {
                MacChatSetupCard(
                    symbol: "eye.slash",
                    title: "Preview Unavailable",
                    message: previewError
                )
                if let previewTarget {
                    Button("Resume Thread") { resumePreviewTarget(previewTarget) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canResumePreviewTarget(previewTarget))
                        .help(previewResumeHelp(for: previewTarget))
                }
                Button("Return To Current Thread") {
                    returnFromPreview()
                }
                Spacer()
            } else {
                switch phase {
            case .loading:
                Spacer()
                ProgressView("Loading thread…")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
            case .failed(let message):
                Spacer()
                MacChatSetupCard(
                    symbol: "bubble.left.and.exclamationmark",
                    title: "Chat Unavailable",
                    message: message
                )
                Spacer()
            case .ready:
                if rows.isEmpty {
                    Spacer()
                    if isWorkspace {
                        MacChatSetupCard(
                            symbol: "terminal",
                            title: engine.label,
                            message: "Resume an existing thread or type below to start one in this Mac's workspace."
                        )
                        Button("Resume Thread…") { showingSessions = true }
                            .padding(.top, 4)
                    } else {
                        MacChatSetupCard(
                            symbol: "bubble.left.and.bubble.right",
                            title: "Start the Thread",
                            message: "Send the first prompt below — the turn streams back live."
                        )
                    }
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(rows) { row in
                                    MacChatRow(row: row, isMatch: showFind && !findText.isEmpty && row.text.lowercased().contains(findText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
                                        .id(row.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            Color.clear.frame(height: 1).id("transcript-end")
                        }
                        .contextMenu {
                            Toggle("Follow Latest Activity", isOn: $followLatest)
                        }
                        .onChange(of: rows.count) {
                            if followLatest { proxy.scrollTo("transcript-end", anchor: .bottom) }
                        }
                        .onChange(of: liveTools) {
                            if followLatest { proxy.scrollTo("transcript-end", anchor: .bottom) }
                        }
                        .onChange(of: codeLoaded) {
                            if followLatest { proxy.scrollTo("transcript-end", anchor: .bottom) }
                        }
                        .onChange(of: findNonce) {
                            if let focus = findFocusId { proxy.scrollTo(focus, anchor: .center) }
                        }
                        .onAppear {
                            if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                        .refreshable {
                            await refreshThread()
                        }
                    }
                }
                }
            }
        }
    }

    private var liveBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(streamingText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 8, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.clutchSecondaryBackground, in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 48)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func previewSurface(_ preview: SessionsClient.PreviewSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title ?? "Untitled Session")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let cwd = preview.cwd, !cwd.isEmpty {
                            Label(cwd, systemImage: "folder")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let model = preview.model, !model.isEmpty {
                            Text(model).lineLimit(1).truncationMode(.middle)
                        }
                        if preview.running {
                            Label("Running In Clutch", systemImage: "circle.fill")
                                .foregroundStyle(.orange)
                                .help("This Clutch sidecar reports an active turn; other processes may not be visible.")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if preview.truncated {
                Label("Showing The Most Recent Messages", systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(preview.history.enumerated()), id: \.offset) { index, entry in
                        if entry.isVisible || entry.isTool {
                            MacChatRow(row: Row(
                                id: "preview-\(index)",
                                text: entry.text,
                                date: Date(),
                                fromAgent: !entry.isUser,
                                isCard: false,
                                isThought: false,
                                toolStatus: entry.isTool ? (entry.toolStatus ?? "completed") : nil
                            ))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private func previewActionBar(for preview: SessionsClient.PreviewSession) -> some View {
        HStack(spacing: 8) {
            Label("Preview Only", systemImage: "eye")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Resume to send messages in this thread.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            Spacer()
            Button(codeRemoteId == nil ? "New Thread" : "Current Thread") {
                returnFromPreview()
            }
            .buttonStyle(.bordered)
            Button("Open In New Window") {
                openPreviewInNewWindow(preview)
            }
            .buttonStyle(.bordered)
            Button("Resume") { resumePreview(preview) }
                .buttonStyle(.borderedProminent)
                .disabled(!queuedMessages.isEmpty || preview.running || isSessionRunning(preview.remoteSessionId))
                .help(
                    !queuedMessages.isEmpty
                        ? "Send or remove queued messages before resuming another thread"
                        : preview.running || isSessionRunning(preview.remoteSessionId)
                            ? "This thread is already running in another window"
                            : "Resume this thread"
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.clutchSecondaryBackground.opacity(0.7))
    }

    private func thoughtRow(_ thought: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.7)
            Text(thought)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Flow

    /// Start a fresh thread on the current engine.
    ///
    /// The engine is not changed: the sidebar's New Thread button must not
    /// move a Muse Code thread over to MiniMax Code.
    private func startMcodeThread() {
        guard isWorkspace else { return }
        guard queuedMessages.isEmpty else {
            sidebarError = "Send or remove queued messages before starting another thread."
            return
        }
        guard !sending else {
            sidebarError = "Finish or stop the current turn before starting another thread."
            return
        }
        cancelSessionLoad()
        previewSession = nil
        previewTarget = nil
        previewError = nil
        previewLoadingId = nil
        setContextControls(nil)
        MacEngineStore.save(engine)
        resetTurnState()
        // A fresh conversation keeps the user's current model, effort, and
        // working-directory choices; only thread-owned content is cleared.
        sessionId = nil
        codeChatId = nil
        codeRemoteId = nil
        codeLoaded = []
        codePending = []
        plan = []
        pendingPermissions.removeAll()
        queuePaused = false
        draft = ""
        draftBase = ""
        attachments = []
        showFind = false
        findText = ""
        findFocusId = nil
        findNonce += 1
        phase = .ready
        if let host = activeHost {
            MacMcodeStore.clear(for: host)
        }
        if !showingSidebar { showingSidebar = true }
    }

    /// Adopt a freshly loaded code-engine thread into the chat pane.
    private func adopt(chatId: String, remoteId: String, cwd: String?, history: [AcpHistoryEntry], for engine: ChatEngine, model: String? = nil, provider: String? = nil, contextControls: MuseContextControls? = nil) {
        self.engine = engine
        MacEngineStore.save(engine)
        resetTurnState()
        // The picked model and effort belong to the thread that was open,
        // so they are cleared here: a new thread must not inherit the
        // previous thread's choice.
        selectedModel = nil
        selectedEffort = nil
        codeChatId = chatId
        codeRemoteId = remoteId
        if let index = sidebarSessions.firstIndex(where: { $0.sessionId == remoteId }) {
            sidebarSessions[index].model = model ?? sidebarSessions[index].model
            sidebarSessions[index].provider = provider ?? sidebarSessions[index].provider
        }
        codeCwd = cwd
        codeLoaded = history
        codePending = []
        setContextControls(contextControls)
        previewSession = nil
        previewTarget = nil
        previewError = nil
        previewLoadingId = nil
        // The plan belongs to the thread that was open, so the thread being
        // adopted brings its own: the last one the engine reported in that
        // thread's history, and none when that thread never had one.
        plan = history.last(where: { $0.isPlan })?.plan ?? []
        phase = .ready
        if let host = activeHost {
            MacMcodeStore.save(remoteId: remoteId, cwd: cwd, engine: engine.sidecarId, for: host)
            if contextControls == nil && engine == .muse {
                let expectedRevision = contextControlsRevision
                Task {
                    guard let controls = try? await SessionsClient(host: host).contextControls(sessionId: chatId),
                          contextControlsRevision == expectedRevision,
                          activeHost?.id == host.id,
                          self.engine == engine,
                          codeRemoteId == remoteId,
                          codeChatId == chatId else { return }
                    setContextControls(controls)
                }
            }
        }
    }

    /// Resume one thread.  `cwd` must travel with the session id: the sidecar
    /// defaults a missing cwd to `$HOME`, and the ACP bridge then refuses any
    /// thread whose persisted workspace is elsewhere.
    private func openSession(_ session: AcpSessionInfo, fromSidebar: Bool) {
        guard let host = activeHost else { return }
        guard !isSessionRunning(session.sessionId, engineID: engine.sidecarId, hostID: host.id) else {
            sidebarError = "This thread is already running in another window."
            return
        }
        guard queuedMessages.isEmpty else {
            sidebarError = "Send or remove queued messages before opening another thread."
            return
        }
        guard !sending else {
            sidebarError = "Finish or stop the current turn before opening another thread."
            return
        }
        guard sidebarLoadingId != session.sessionId else { return }
        cancelSessionLoad()
        let token = sessionLoadToken
        if fromSidebar {
            sidebarLoadingId = session.sessionId
            sidebarError = nil
        }
        let target = engine
        // A resumed thread keeps the model and effort it was created with,
        // so the load carries none.  The local picks are cleared only once
        // the load succeeds (in `adopt`), so a failed load leaves the
        // visible thread's choices untouched.
        sessionLoadTask = Task {
            defer {
                if sessionLoadToken == token {
                    sidebarLoadingId = nil
                    sessionLoadTask = nil
                }
            }
            do {
                let loaded = try await SessionsClient(host: host).load(
                    sessionId: session.sessionId,
                    cwd: session.cwd,
                    engine: target.sidecarId
                )
                guard !Task.isCancelled, sessionLoadToken == token,
                      activeHost?.id == host.id, engine == target else { return }
                adopt(chatId: loaded.chatId, remoteId: loaded.remoteSessionId, cwd: loaded.cwd, history: loaded.history, for: target, model: loaded.model, provider: loaded.provider, contextControls: loaded.contextControls)
            } catch {
                guard !Task.isCancelled, sessionLoadToken == token else { return }
                if fromSidebar {
                    failedSidebarSession = session
                    sidebarError = codeLoadErrorMessage(error, session: session)
                } else {
                    sendError = codeLoadErrorMessage(error, session: session)
                }
            }
        }
    }

    private func selectSidebarSession(_ session: AcpSessionInfo) {
        guard let host = activeHost else { return }
        if sending {
            openWindow(value: MacThreadWindowRequest(
                hostID: host.id,
                engineID: engine.sidecarId,
                sessionID: session.sessionId,
                cwd: session.cwd,
                title: session.title
            ))
            return
        }
        Task { await loadPreview(session) }
    }

    private func loadPreview(_ session: AcpSessionInfo) async {
        guard let host = activeHost else { return }
        let requestedEngine = engine
        previewToken = UUID()
        let token = previewToken
        previewSession = nil
        previewTarget = session
        previewError = nil
        previewLoadingId = session.sessionId
        do {
            let preview = try await SessionsClient(host: host).preview(
                sessionId: session.sessionId,
                cwd: session.cwd,
                engine: requestedEngine.sidecarId,
                limit: 200
            )
            guard previewToken == token, activeHost?.id == host.id, engine == requestedEngine else { return }
            previewSession = preview
            previewLoadingId = nil
        } catch {
            guard previewToken == token, activeHost?.id == host.id, engine == requestedEngine else { return }
            previewLoadingId = nil
            previewError = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
        }
    }

    private func resumePreview(_ preview: SessionsClient.PreviewSession) {
        guard queuedMessages.isEmpty, !isSessionRunning(preview.remoteSessionId) else { return }
        openSession(
            AcpSessionInfo(
                sessionId: preview.remoteSessionId,
                cwd: MacThreadPreviewWorkspace.cwd(
                    previewCwd: preview.cwd,
                    previewSessionID: preview.remoteSessionId,
                    targetSessionID: previewTarget?.sessionId,
                    targetCwd: previewTarget?.cwd
                ),
                title: preview.title,
                provider: preview.provider,
                model: preview.model,
                usage: preview.usage
            ),
            fromSidebar: true
        )
    }

    private func canResumePreviewTarget(_ target: AcpSessionInfo) -> Bool {
        queuedMessages.isEmpty && !sending && !isSessionRunning(target.sessionId)
    }

    private func previewResumeHelp(for target: AcpSessionInfo) -> String {
        if !queuedMessages.isEmpty { return "Send or remove queued messages before resuming another thread" }
        if sending { return "Finish or stop the current turn before resuming another thread" }
        if isSessionRunning(target.sessionId) { return "This thread is already running in another window" }
        return "Resume this thread"
    }

    private func resumePreviewTarget(_ target: AcpSessionInfo) {
        guard canResumePreviewTarget(target) else { return }
        openSession(target, fromSidebar: true)
    }

    private func returnFromPreview() {
        previewToken = UUID()
        previewSession = nil
        previewTarget = nil
        previewLoadingId = nil
        previewError = nil
    }

    private func isSessionRunning(_ sessionID: String, engineID: String? = nil, hostID: UUID? = nil) -> Bool {
        guard let host = activeHost else { return false }
        return runningSessionRegistry.isRunning(
            hostID: hostID ?? host.id,
            engineID: engineID ?? engine.sidecarId,
            sessionID: sessionID
        )
    }

    private func openNewThreadWindow() {
        guard let host = activeHost else { return }
        openWindow(value: MacThreadWindowRequest(
            hostID: host.id,
            engineID: engine.sidecarId,
            cwd: previewSession?.cwd ?? codeCwd
        ))
    }

    private func openSessionInNewWindow(_ session: AcpSessionInfo) {
        guard let host = activeHost else { return }
        openWindow(value: MacThreadWindowRequest(
            hostID: host.id,
            engineID: engine.sidecarId,
            sessionID: session.sessionId,
            cwd: session.cwd,
            title: session.title
        ))
    }

    private func openPreviewInNewWindow(_ preview: SessionsClient.PreviewSession) {
        guard let host = activeHost else { return }
        openWindow(value: MacThreadWindowRequest(
            hostID: host.id,
            engineID: engine.sidecarId,
            sessionID: preview.remoteSessionId,
            cwd: MacThreadPreviewWorkspace.cwd(
                previewCwd: preview.cwd,
                previewSessionID: preview.remoteSessionId,
                targetSessionID: previewTarget?.sessionId,
                targetCwd: previewTarget?.cwd
            ),
            title: preview.title
        ))
    }

    private func cancelSessionLoad() {
        sessionLoadTask?.cancel()
        sessionLoadTask = nil
        sessionLoadToken = UUID()
        sidebarLoadingId = nil
        failedSidebarSession = nil
        sidebarError = nil
    }

    private func loadSidebarSessions() async {
        guard let host = activeHost, isWorkspace else { return }
        let requestedEngine = engine
        let requestedArchived = showArchived
        let requestedFolder = sidebarFolderScope
        let requestedLimit = sidebarLimit
        sidebarLoading = true
        defer {
            if activeHost?.id == host.id,
               engine == requestedEngine,
               showArchived == requestedArchived,
               sidebarFolderScope == requestedFolder,
               sidebarLimit == requestedLimit {
                sidebarLoading = false
            }
        }
        do {
            let client = SessionsClient(host: host)
            let listed = try await client.list(
                engine: requestedEngine.sidecarId,
                limit: requestedLimit,
                includingArchived: requestedArchived,
                folder: requestedFolder,
                includeDescendants: true
            )
            guard activeHost?.id == host.id, engine == requestedEngine,
                  showArchived == requestedArchived,
                  sidebarFolderScope == requestedFolder,
                  sidebarLimit == requestedLimit else { return }
            sidebarSessions = listed
            sidebarHasMore = requestedLimit < 1000 && listed.count >= requestedLimit
            sidebarFolders.formUnion(listed.compactMap { session in
                guard let cwd = session.cwd, !cwd.isEmpty else { return nil }
                return cwd
            })
            sidebarError = nil
            // Project names live only in the metadata store, so the sidebar
            // needs its own read.  A failure here must not blank the thread
            // list, which is the thing the user actually asked for.
            if let meta = try? await client.meta() {
                guard activeHost?.id == host.id, engine == requestedEngine else { return }
                sidebarProjects = meta.projects
            }
        } catch {
            guard activeHost?.id == host.id,
                  engine == requestedEngine,
                  showArchived == requestedArchived,
                  sidebarFolderScope == requestedFolder,
                  sidebarLimit == requestedLimit else { return }
            // Keep whatever list we already have; a retry is one click away.
            if sidebarSessions.isEmpty {
                sidebarError = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
            }
        }
    }

    private func loadMoreSidebarSessions() {
        guard let nextLimit = MacThreadFolderScope.nextLimit(after: sidebarLimit), !loadingMoreSidebar else { return }
        sidebarLimit = nextLimit
        loadingMoreSidebar = true
        Task {
            await loadSidebarSessions()
            loadingMoreSidebar = false
        }
    }

    // MARK: - Sidebar actions

    private func handle(_ action: ThreadSidebarAction, _ session: AcpSessionInfo) {
        switch action {
        case let .revealInFinder(session):
            if let cwd = session.cwd, !cwd.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
            }
        case let .renameThread(session):
            guard let title = ThreadSidebar.promptForThreadTitle(currentTitle: session.title) else { return }
            Task { await applyMeta(sessionId: session.sessionId, title: title) }
        case let .openInNewWindow(session):
            openSessionInNewWindow(session)
        case let .assignProject(session, projectId):
            // `.some(projectId)` keeps the key on the wire even when the inner
            // value is nil (unassign sends null); a plain nil would mean
            // "leave the assignment alone".
            Task { await applyMeta(sessionId: session.sessionId, projectId: .some(projectId), archived: nil) }

        case let .createProject(name, session):
            Task { await createProject(name: name, assigning: session.sessionId) }

        case let .setArchived(session, archived):
            // No projectId argument: archiving must not touch the assignment.
            Task { await applyMeta(sessionId: session.sessionId, archived: archived) }
        }
    }

    private func applyMeta(sessionId: String, projectId: String?? = nil, archived: Bool? = nil, title: String?? = nil) async {
        guard let host = activeHost else { return }
        do {
            let meta = try await SessionsClient(host: host).updateMeta(
                sessionId: sessionId,
                projectId: projectId,
                archived: archived,
                title: title
            )
            sidebarProjects = meta.projects
            await loadSidebarSessions()
        } catch {
            sidebarError = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
        }
    }

    private func createProject(name: String, assigning sessionId: String) async {
        guard let host = activeHost else { return }
        let client = SessionsClient(host: host)
        do {
            let result = try await client.createProject(name: name)
            // Assign through the returned id whether the project was just
            // created or already existed, and take the sidecar's project list
            // from the response instead of appending locally — appending an
            // already-existing project duplicated it in the sidebar.
            let meta = try await client.updateMeta(sessionId: sessionId, projectId: result.project.id)
            sidebarProjects = meta.projects
            await loadSidebarSessions()
        } catch {
            sidebarError = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Keep a failed resume actionable without surfacing an engine's raw ACP
    /// reason, which can contain an entire prompt or other long payload.
    private func codeLoadErrorMessage(_ error: Error, session: AcpSessionInfo) -> String {
        let detail = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
        if engine == .muse && EngineAuthenticationAttempt.isRequired(detail) {
            return Copy.gap("Sign in to Muse to open this thread.", "Open Muse Account above, then select the thread again.")
        }
        if engine == .muse, detail.range(of: "open in another process", options: .caseInsensitive) != nil {
            return "This Muse thread is open in another process; choose another thread or wait until it is released."
        }
        let title = session.displayTitle
        let boundedTitle = title.count > 70 ? String(title.prefix(69)) + "…" : title
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return Copy.gap("Opening \"\(boundedTitle)\" timed out.", "Retry to open this thread again.")
        }
        return Copy.gap(
            "Could not resume \"\(boundedTitle)\".",
            "Retry to open this thread again."
        )
    }

    private func resetTurnState() {
        turnGeneration = UUID()
        runningSessionRegistry.release(owner: runningRegistryOwner)
        setContextControls(nil)
        sendTask?.cancel()
        sendTask = nil
        sending = false
        steering = false
        steeringSupported = false
        liveTurn = ChatTurnBuffer()
        activeUsage = nil
        thoughtLine = nil
        sendError = nil
    }

    private func setContextControls(_ controls: MuseContextControls?) {
        contextControlsRevision = UUID()
        activeContextControls = controls
    }

    private func prepare(preferredEngine: ChatEngine? = nil) async {
        guard let host = activeHost else { return }
        let generation = turnGeneration
        pinnedIds = ThreadPinStore.pinnedIDs(forHost: host.id)
        // The catalog can take a while on a cold server, so the thread list
        // and the health check do not wait for it.
        await checkSidecar()
        guard turnGeneration == generation, activeHost?.id == host.id else { return }
        // Select a known window or restored-thread engine before requesting
        // its catalog, so an unrelated cold engine probe cannot delay it.
        // An explicitly supplied engine still has first priority.
        let requestEngine = isWorkspace && !didConsumeInitialThreadRequest
            ? initialThreadRequest.flatMap { ChatEngine(rawValue: $0.engineID) }
            : nil
        let restoredEngine = isWorkspace
            ? MacMcodeStore.load(for: host).flatMap { ChatEngine(rawValue: $0.engine ?? "mcode") }
            : nil
        let storedEngine = isWorkspace ? MacEngineStore.load() : MacAgentEngineStore.load()
        if let target = preferredEngine ?? requestEngine ?? restoredEngine ?? storedEngine {
            engine = target
        }
        async let catalogTask = loadCatalog(expectedGeneration: generation, for: engine)
        _ = await catalogTask
        guard turnGeneration == generation, activeHost?.id == host.id else { return }
        // The host's catalog decides which engines this Mac can offer: a
        // server with Muse Code but no MiniMax Code shows Muse Code only.
        if !offeredEngines.contains(where: { $0 == engine }), let first = offeredEngines.first {
            engine = first
            await loadCatalog(expectedGeneration: generation, for: first)
        }
        if isWorkspace {
            if let request = initialThreadRequest {
                guard !didConsumeInitialThreadRequest else {
                    phase = .ready
                    return
                }
                didConsumeInitialThreadRequest = true
                if let requestedEngine = ChatEngine(rawValue: request.engineID), offeredEngines.contains(requestedEngine) {
                    engine = requestedEngine
                    await loadCatalog(expectedGeneration: generation, for: requestedEngine)
                }
                codeCwd = request.cwd
                phase = .ready
                if let sessionID = request.sessionID {
                    await loadPreview(AcpSessionInfo(
                        sessionId: sessionID,
                        cwd: request.cwd,
                        title: request.title
                    ))
                }
                return
            }
            // Show the last thread after relaunch without taking ownership.
            // Sending in it requires an explicit Resume action.
            if let saved = MacMcodeStore.load(for: host) {
                let savedEngine = ChatEngine(rawValue: saved.engine ?? "mcode") ?? .mcode
                if offeredEngines.contains(savedEngine) {
                    engine = savedEngine
                    await loadCatalog(expectedGeneration: generation, for: savedEngine)
                    codeCwd = saved.cwd
                    phase = .ready
                    await loadPreview(AcpSessionInfo(
                        sessionId: saved.remoteId,
                        cwd: saved.cwd,
                        title: sidebarSessions.first(where: { $0.sessionId == saved.remoteId })?.title
                    ))
                    guard turnGeneration == generation,
                          activeHost?.id == host.id,
                          MacMcodeStore.load(for: host)?.remoteId == saved.remoteId else { return }
                    return
                }
            }
            guard turnGeneration == generation, activeHost?.id == host.id else { return }
            codeChatId = nil
            codeRemoteId = nil
            codeLoaded = []
            codePending = []
            phase = .ready
            return
        }
        phase = .loading
        do {
            let loaded = try await ChatThreadClient(host: host).fetch(deviceUid: deviceUid)
            guard turnGeneration == generation, activeHost?.id == host.id else { return }
            agentBubbles = loaded
            phase = .ready
        } catch {
            guard turnGeneration == generation, activeHost?.id == host.id else { return }
            phase = .failed(chatErrorMessage(error))
        }
    }

    private func refreshThread() async {
        guard let host = activeHost, phase == .ready, !sending else { return }
        let generation = turnGeneration
        let requestedEngine = engine
        if isWorkspace {
            guard let remoteId = codeRemoteId else { return }
            let requestedChatId = codeChatId
            let requestedCwd = codeCwd
            do {
                let loaded = try await SessionsClient(host: host).load(
                    sessionId: remoteId,
                    cwd: requestedCwd,
                    engine: requestedEngine.sidecarId
                )
                guard turnGeneration == generation,
                      activeHost?.id == host.id,
                      engine == requestedEngine,
                      codeRemoteId == remoteId,
                      codeChatId == requestedChatId,
                      codeCwd == requestedCwd else { return }
                codeChatId = loaded.chatId
                codeCwd = loaded.cwd
                codeLoaded = loaded.history
                codePending = []
                if requestedEngine == .muse, let controls = loaded.contextControls {
                    setContextControls(controls)
                }
            } catch {
                // Keep the in-view thread; the next send or pull retries.
            }
            return
        }
        do {
            let loaded = try await ChatThreadClient(host: host).fetch(deviceUid: deviceUid)
            guard turnGeneration == generation,
                  activeHost?.id == host.id,
                  engine == requestedEngine else { return }
            agentBubbles = loaded
        } catch {
            // Keep the existing thread on a failed refresh; the next send or
            // pull retries. A failed first load reports through prepare().
        }
    }

    private func chatErrorMessage(_ error: Error) -> String {
        if let clientError = error as? ChatClientError {
            switch clientError {
            case .missingToken:
                return Copy.gap(
                    "Chat is not paired on this Mac yet.",
                    "Reopen Clutch after the sidecar restarts, or run \(Copy.pairCommand) and paste the link it copies."
                )
            case .http(401):
                return "The sidecar rejected this chat token — reopen Clutch or pair again to refresh it."
            case .http(501):
                return "The sidecar has no chat relay configured yet — MiniMax Code threads work now; DeepSeek and MiniMax threads need the relay."
            default:
                return clientError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func queueDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard sending else { send(text); return }
        guard queuedMessages.count < 16 else {
            sendError = "The queue is full; remove a queued message before adding another."
            return
        }
        // A newly created queue resumes automatic delivery; a paused queue
        // that still contains messages keeps its explicit review boundary.
        if queuedMessages.isEmpty { queuePaused = false }
        queuedMessages.append(QueuedMessage(
            text: text,
            images: attachments,
            model: selectedModel ?? "",
            effort: selectedEffort,
            museOptions: museLaunchOptions,
            contextPolicy: museContextPolicy,
            hostId: activeHost?.id,
            engine: engine,
            surface: surface,
            remoteId: isWorkspace ? codeRemoteId : sessionId
        ))
        draft = ""
        attachments = []
    }

    private func compactContext() {
        guard canManuallyCompactContext else { return }
        let savedDraft = draft
        let savedAttachments = attachments
        draft = "/compact"
        attachments = []
        send("/compact")
        draft = savedDraft
        attachments = savedAttachments
    }

    private func sendNextQueuedMessage() {
        guard !sending, !queuePaused, !queuedMessages.isEmpty else { return }
        let message = queuedMessages[0]
        guard message.hostId == activeHost?.id, message.engine == engine, message.surface == surface else {
            sendError = "Return to the original host and engine to send this queued message."
            queuePaused = true
            return
        }
        if let expected = message.remoteId, expected != (isWorkspace ? codeRemoteId : sessionId) {
            sendError = "Return to the original thread to send this queued message."
            queuePaused = true
            return
        }
        send(message.text, queued: message)
        if sending { queuedMessages.removeFirst() }
    }

    private func steerDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !steering else { return }
        guard sending else { send(text); return }
        guard steeringSupported else {
            sendError = "This engine has not enabled steering for this turn; queue the message instead."
            return
        }
        guard attachments.isEmpty else {
            sendError = "Queue image attachments for the next turn; steering currently accepts text."
            return
        }
        guard let host = activeHost, let chatId = isWorkspace ? codeChatId : sessionId else {
            sendError = "Wait for the turn to connect before steering."
            return
        }
        let generation = turnGeneration
        steering = true
        Task {
            defer { if generation == turnGeneration { steering = false } }
            do {
                try await ChatSessionClient.steer(host: host, sessionId: chatId, text: text)
                guard generation == turnGeneration, sending else { return }
                retainTurnOutput(finishing: false)
                if isWorkspace {
                    codeLoaded.append(AcpHistoryEntry(sessionId: "local", kind: "user_message_chunk", text: text))
                } else {
                    localPrompts.append(LocalPrompt(text: text, at: Date()))
                    MacChatStore.savePrompts(localPrompts)
                }
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
                sendError = nil
            } catch {
                guard generation == turnGeneration else { return }
                sendError = error.localizedDescription
            }
        }
    }

    private func send(_ text: String, queued: QueuedMessage? = nil) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard previewSession == nil, previewLoadingId == nil, previewError == nil else { return }
        guard !prompt.isEmpty, !sending else { return }
        guard sidebarLoadingId == nil else {
            sendError = "Wait for the selected thread to open before sending."
            return
        }
        guard let host = activeHost else { return }
        guard host.chatToken?.isEmpty == false else {
            sendError = chatErrorMessage(ChatClientError.missingToken)
            return
        }
        if isWorkspace, let remoteID = codeRemoteId {
            guard runningSessionRegistry.claim(
                hostID: host.id,
                engineID: engine.sidecarId,
                sessionID: remoteID,
                owner: runningRegistryOwner
            ) else {
                sendError = "This thread is already running in another window."
                return
            }
        }
        let outgoingImages = queued?.images ?? attachments
        if queued == nil {
            draft = ""
            attachments = []
        }
        sendError = nil
        sending = true
        steering = false
        steeringSupported = false
        liveTurn = ChatTurnBuffer()
        turnGeneration = UUID()
        let generation = turnGeneration
        plan = []
        if isWorkspace {
            codePending.append(LocalPrompt(text: prompt, at: Date()))
        } else {
            localPrompts.append(LocalPrompt(text: prompt, at: Date()))
            MacChatStore.savePrompts(localPrompts)
        }
        let currentTurnHistoryStartIndex = codeLoaded.count
        let client = ChatSessionClient(
            host: host,
            model: queued?.model ?? selectedModel ?? "",
            sessionId: isWorkspace ? codeChatId : sessionId,
            relayReceiverUid: deviceUid,
            // The engine always rides along: without it the sidecar routes
            // by model name, and a MiniMax turn with no model named would
            // land on DeepSeek.
            engine: engine.sidecarId,
            cwd: isWorkspace ? codeCwd : nil,
            effort: queued == nil ? selectedEffort : queued?.effort,
            museOptions: queued == nil ? museLaunchOptions : queued?.museOptions,
            contextPolicy: queued == nil ? museContextPolicy : queued?.contextPolicy,
            images: outgoingImages
        )
        sendTask = Task {
            do {
                for try await event in client.stream(prompt: prompt) {
                    guard !Task.isCancelled, turnGeneration == generation else { return }
                    switch event {
                    case .started(let id, _):
                        if isWorkspace {
                            codeChatId = id
                        } else {
                            sessionId = id
                        }
                    case .capabilities(let supportsSteering):
                        steeringSupported = supportsSteering
                    case .message(let chunk):
                        thoughtLine = nil
                        liveTurn.append(chunk)
                    case .thought(let text):
                        thoughtLine = String(text.prefix(220))
                    case .tool(let call):
                        if let index = ChatTurnBuffer.latestToolIndex(
                            in: codeLoaded,
                            matching: call.id,
                            from: currentTurnHistoryStartIndex
                        ) {
                            codeLoaded[index].toolStatus = call.status
                            if !call.name.isEmpty { codeLoaded[index].text = call.name }
                            if let parent = call.parentId { codeLoaded[index].parentToolCallId = parent }
                            if let input = call.input { codeLoaded[index].toolInput = input }
                        } else {
                            liveTurn.updateTool(
                                id: call.id,
                                name: call.name,
                                status: call.status,
                                parentId: call.parentId,
                                input: call.input
                            )
                        }
                    case .permission(let request):
                        // The engine is blocked on this request until the
                        // answer goes back, so it is held on screen.
                        pendingPermissions.append(request)
                    case .plan(let entries):
                        plan = entries
                    case .contextControls(let controls):
                        setContextControls(controls)
                    case .done(let stop, let id, let remoteId):
                        if isWorkspace {
                            codeChatId = id
                            if let remoteId, !remoteId.isEmpty {
                                codeRemoteId = remoteId
                                MacMcodeStore.save(remoteId: remoteId, cwd: codeCwd, engine: engine.sidecarId, for: host)
                            }
                        } else {
                            sessionId = id
                        }
                        retainTurnOutput()
                        TurnNotifier.turnFinished(threadTitle: isWorkspace ? (sidebarSessions.first(where: { $0.sessionId == codeRemoteId })?.displayTitle ?? engine.label) : (selectedModel ?? engine.label))
                        if stop != "endTurn" && stop != "end_turn" && stop != "cancelled" {
                            sendError = "Turn ended: \(stop)"
                        } else if !isWorkspace {
                            await refreshThread()
                        }
                        if stop == "endTurn" || stop == "end_turn" {
                            sendNextQueuedMessage()
                        } else {
                            queuePaused = true
                        }
                        return
                    case .usage(let usage):
                        activeUsage = usage
                        if engine == .muse, var controls = activeContextControls {
                            controls.contextUsedTokens = usage.contextUsedTokens ?? controls.contextUsedTokens
                            controls.contextWindow = usage.contextWindow ?? controls.contextWindow
                            setContextControls(controls)
                        }
                        if let index = sidebarSessions.firstIndex(where: { $0.sessionId == codeRemoteId }) {
                            sidebarSessions[index].usage = usage
                            sidebarSessions[index].model = usage.model ?? sidebarSessions[index].model
                            sidebarSessions[index].provider = usage.provider ?? sidebarSessions[index].provider
                        }
                    case .failed(let message):
                        retainTurnOutput()
                        queuePaused = true
                        sendError = message
                        TurnNotifier.turnFinished(threadTitle: isWorkspace ? engine.label : (selectedModel ?? engine.label), failed: true)
                        return
                    }
                }
                guard !Task.isCancelled, turnGeneration == generation else { return }
                retainTurnOutput()
                queuePaused = true
                sendError = "The connection closed before a completion update arrived."
            } catch {
                guard !Task.isCancelled, turnGeneration == generation else { return }
                retainTurnOutput()
                queuePaused = true
                sendError = error.localizedDescription
            }
        }
    }

    private func retainTurnOutput(finishing: Bool = true) {
        if finishing {
            runningSessionRegistry.release(owner: runningRegistryOwner)
        }
        let output: ChatTurnBuffer.Snapshot
        if finishing {
            guard let finished = liveTurn.finish() else { return }
            output = finished
        } else {
            output = liveTurn.drain()
        }
        if isWorkspace {
            codeLoaded += codePending.map {
                AcpHistoryEntry(sessionId: "local", kind: "user_message_chunk", text: $0.text)
            }
            codePending = []
            for tool in output.tools {
                // The relation and the input travel with the call, so a turn
                // that has finished still shows its tree.
                codeLoaded.append(AcpHistoryEntry(
                    sessionId: "local",
                    kind: "tool_call",
                    text: tool.name,
                    toolCallId: tool.id,
                    toolStatus: tool.status,
                    parentToolCallId: tool.parentId,
                    toolInput: tool.input
                ))
            }
            if !output.text.isEmpty {
                codeLoaded.append(AcpHistoryEntry(sessionId: "local", kind: "agent_message_chunk", text: output.text))
            }
        } else if !output.text.isEmpty {
            agentBubbles.append(ThreadBubble(id: "local-\(turnGeneration)", senderUid: "agent", text: output.text, sentAt: Date().timeIntervalSince1970 * 1000, kind: "text"))
        }
        if finishing {
            sending = false
            steering = false
            turnGeneration = UUID()
            thoughtLine = nil
            pendingPermissions.removeAll()
        }
    }

    private var transcriptMarkdown: String {
        let entries = rows.map { row in
            TranscriptExport.Entry(
                role: row.toolStatus != nil ? .tool : row.isThought ? .thought : row.fromAgent ? .assistant : .user,
                text: row.text
            )
        }
        let title = isWorkspace
            ? (sidebarSessions.first(where: { $0.sessionId == codeRemoteId })?.displayTitle ?? "\(engine.label) Thread")
            : "\(selectedModel ?? engine.label) Thread"
        return TranscriptExport.markdown(title: title, cwd: isWorkspace ? displayCwd : nil, entries: entries)
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptMarkdown, forType: .string)
    }

    private func saveTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "minimax-code-thread.md"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? transcriptMarkdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Stop the in-flight turn: tell the sidecar to cancel the ACP session,
    /// then drop the local stream (whose close cancels a second time on the
    /// server, harmlessly).  The partial reply stays out of the transcript —
    /// a stopped turn is not a finished answer.
    /// Answer the permission request the engine is waiting on.
    ///
    /// The answer goes to the sidecar, which hands it to the engine.  The
    /// card is cleared either way: a request the sidecar could not answer
    /// is not one the engine will take an answer for later.
    private func answerPermission(_ optionId: String?) {
        guard let request = pendingPermissions.first, let host = activeHost else { return }
        // Without a chat id the sidecar has nothing to answer against, so the
        // card stays and the turn keeps waiting rather than losing the answer.
        guard let chatId = isWorkspace ? codeChatId : sessionId, !chatId.isEmpty else { return }
        Task {
            let answered = await ChatSessionClient.answerPermission(
                host: host,
                sessionId: chatId,
                requestId: request.requestId,
                optionId: optionId
            )
            if answered {
                // The card only goes away once the answer is on its way, so a
                // failed answer can be tried again instead of stranding the
                // engine on a question nobody can see any more.
                pendingPermissions.removeFirst()
            } else {
                sendError = "The permission answer did not reach the engine."
            }
        }
    }

    private func stop() {
        guard sending else { return }
        queuePaused = true
        if let host = activeHost, let chatId = isWorkspace ? codeChatId : sessionId {
            Task { await ChatSessionClient.cancel(host: host, sessionId: chatId) }
        }
        sendTask?.cancel()
        sendTask = nil
        retainTurnOutput()
        turnGeneration = UUID()
        // A stopped turn cannot answer a question any more, so the card goes
        // with it rather than sitting there inviting an answer that lands
        // nowhere.
        pendingPermissions.removeAll()
    }
}

private struct MacWindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> MacWindowCloseObservingView {
        let view = MacWindowCloseObservingView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: MacWindowCloseObservingView, context: Context) {
        view.onClose = onClose
    }
}

private final class MacWindowCloseObservingView: NSView {
    var onClose: (() -> Void)?
    private weak var observedWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keep observing the owning window when SwiftUI temporarily detaches an inactive tab's view; a new window replaces the old registration, and its close notification releases the lease.
        guard let window, observedWindow !== window else { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        observedWindow = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.onClose?()
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}

/// MiniMax Code thread browser: list, resume, and hand the replayed
/// history back to the Chat tab.
struct MacSessionsSheet: View {
    var host: ClutchHost
    /// The engine whose threads the sheet lists.
    var engine: String = "mcode"
    /// Carries the listed session so the resume can send its own `cwd`.
    var onLoaded: (AcpSessionInfo, String, String, String?, [AcpHistoryEntry], MuseContextControls?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [AcpSessionInfo]?
    @State private var error: String?
    @State private var loadingId: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The banner sits above the list rather than replacing it: the
                // old error lived in an else-if branch that a loaded session
                // list made unreachable, so a failed resume looked like a
                // click that did nothing at all.
                if let error, !error.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Retry") {
                            self.error = nil
                            Task { await refresh() }
                        }
                        .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12))
                    Divider()
                }

                Group {
                    if let sessions {
                        if sessions.isEmpty {
                            Text("No MiniMax Code threads yet — start one from the Chat tab.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                                .frame(maxHeight: .infinity)
                        } else {
                            List(sessions) { session in
                                Button {
                                    Task { await load(session) }
                                } label: {
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.displayTitle)
                                                .font(.body.weight(.semibold))
                                                .lineLimit(1)
                                            if let cwd = session.cwd {
                                                Text(cwd)
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                        }
                                        if loadingId == session.sessionId {
                                            // Resuming takes several seconds;
                                            // without this the row just goes dead.
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(loadingId != nil)
                            }
                        }
                    } else if error == nil {
                        ProgressView("Loading threads…")
                            .frame(maxHeight: .infinity)
                    } else {
                        Text("No threads loaded.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle("\(EngineLabels.label(for: engine)) Threads")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 340)
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        error = nil
        do {
            sessions = try await SessionsClient(host: host).list(engine: engine)
        } catch {
            self.error = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
        }
    }

    private func load(_ session: AcpSessionInfo) async {
        loadingId = session.sessionId
        error = nil
        defer { loadingId = nil }
        do {
            let loaded = try await SessionsClient(host: host).load(
                sessionId: session.sessionId,
                cwd: session.cwd,
                engine: engine
            )
            onLoaded(session, loaded.chatId, loaded.remoteSessionId, loaded.cwd, loaded.history, loaded.contextControls)
            dismiss()
        } catch {
            self.error = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

/// Thread bubble and user prompt rows.
struct MacChatRow: View {
    var row: ChatView.Row
    var isMatch: Bool = false

    @State private var expanded = false
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        if let toolStatus = row.toolStatus {
            ThreadToolCard(
                name: row.text,
                status: toolStatus,
                depth: row.toolDepth,
                input: row.toolInput
            )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isMatch ? Color.accentColor : Color.clear, lineWidth: 2)
                )
        } else if row.isThought {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse Thinking" : "Expand Thinking")
                Text(row.text)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(expanded ? nil : 3)
                Spacer(minLength: 48)
            }
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                if !row.fromAgent { Spacer(minLength: 48) }
                if row.fromAgent, hovering || copied {
                    copyButton
                }
                VStack(alignment: row.fromAgent ? .leading : .trailing, spacing: 3) {
                    Text(row.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            row.fromAgent
                                ? Color.clutchSecondaryBackground
                                : Color.accentColor.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isMatch ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    HStack(spacing: 6) {
                        Text(row.date, style: .time)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        if row.isCard {
                            Text("TOOL SUMMARY")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if !row.fromAgent, hovering || copied {
                    copyButton
                }
                if row.fromAgent { Spacer(minLength: 48) }
            }
            .onHover { hovering = $0 }
        }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy Message")
        .help(copied ? "Copied" : "Copy Message")
    }
}

struct MacChatSetupCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }
}

/// Last MiniMax Code thread per host, so a finished turn survives relaunch:
/// the sidecar only keeps turns in memory, and a fresh turn's only durable
/// id is the remote session id the `done` event carries.
enum MacMcodeStore {
    private static let key = "codes.clutch.mcode-remote.v1"

    struct Saved: Codable {
        var remoteId: String
        var cwd: String?
        /// The engine the thread belongs to.  Absent in records written before Muse
        /// Code existed: those are MiniMax Code.
        var engine: String?

        /// The engine id to resume with.
        var engineId: String { engine ?? "mcode" }
    }

    private static func map() -> [String: Saved] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Saved].self, from: data) else { return [:] }
        return decoded
    }

    static func load(for host: ClutchHost) -> Saved? {
        map()[host.id.uuidString]
    }

    static func save(remoteId: String, cwd: String?, engine: String = "mcode", for host: ClutchHost) {
        var current = map()
        current[host.id.uuidString] = Saved(remoteId: remoteId, cwd: cwd, engine: engine)
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear(for host: ClutchHost) {
        var current = map()
        current.removeValue(forKey: host.id.uuidString)
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Persisted chat engine, so relaunch returns to MiniMax Code with its
/// thread instead of dropping back to an empty DeepSeek tab.
enum MacEngineStore {
    private static let key = "codes.clutch.mac-engine.v1"

    static func save(_ engine: ChatEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: key)
    }

    static func load() -> ChatEngine? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        return ChatEngine(rawValue: raw)
    }
}

/// The agent chat's engine, kept apart from the workspace's.
///
/// The two surfaces are separate conversations, so the engine the owner
/// picks for one is not the engine of the other: the agent chat runs on the
/// hosted engines, and writing its choice into the workspace's record would
/// silently move the workspace to another engine.
enum MacAgentEngineStore {
    private static let key = "codes.clutch.mac-agent-engine.v1"

    static func save(_ engine: ChatEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: key)
    }

    static func load() -> ChatEngine? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        return ChatEngine(rawValue: raw)
    }
}
/// Local prompt persistence (see `LocalPrompt`).
enum MacChatStore {
    private static let key = "codes.clutch.mac-prompts.v1"
    private static let cap = 200

    static func loadPrompts() -> [LocalPrompt] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([LocalPrompt].self, from: data) else { return [] }
        return decoded
    }

    static func savePrompts(_ prompts: [LocalPrompt]) {
        let capped = Array(prompts.suffix(cap))
        if let data = try? JSONEncoder().encode(capped) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
