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

    /// True for the engines whose threads can be listed and resumed.
    var supportsThreads: Bool {
        self == .mcode || self == .muse
    }

    var label: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .minimax: return "MiniMax"
        case .mcode: return "MiniMax Code"
        case .muse: return "Muse Code"
        }
    }
}

/// The native Chat tab for macOS: the agent thread renders from the sidecar
/// thread endpoint (the CometChat kit SDK is iOS-only), the native input bar
/// owns the send path through `ChatSessionClient`, and the turn streams back
/// live into a pending bubble before the authoritative refresh.
public struct ChatView: View {
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
    }

    @State private var phase: Phase = .loading
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
    /// User-resized rail width.  Persisted so the window comes back the way it
    /// was left; the drag itself lives in `ThreadSidebar`'s trailing edge.
    @State private var sidebarWidth: CGFloat = MacSidebarWidth.current
    @State private var sidebarProjects: [SessionsClient.Project] = []
    /// When true the sidebar also lists archived threads so they can be
    /// restored; archiving a thread would otherwise make it unreachable.
    @State private var showArchived = false
    /// Newest real usage record for the open thread, pushed by the sidecar's
    /// SSE stream.  Nil until the engine reports one.
    @State private var activeUsage: AcpSessionUsage?
    @State private var draft: String = ""
    @State private var sessionId: String?
    @State private var sending: Bool = false
    @State private var streamingText: String = ""
    @State private var thoughtLine: String?
    @State private var sendError: String?
    /// nil until the first health check lands; drives the header status dot.
    @State private var sidecarReachable: Bool?
    @State private var mcodeAvailable: Bool = true
    @State private var sendTask: Task<Void, Never>?
    @State private var showingCwdEditor = false
    @State private var cwdDraft: String = ""
    @State private var pinnedIds: Set<String> = []
    /// Tool calls from the in-flight turn; folded into the transcript on done.
    @State private var liveTools: [LiveTool] = []
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

    struct LiveTool: Identifiable, Equatable {
        var id: String
        var name: String
        var status: String
    }

    let activeHost: ClutchHost?

    /// The paired-host store.  The Mac app pairs the same way the phone
    /// does, so the chat surface can point at another machine — a Linux
    /// server running Muse Code, for example — instead of only this Mac.
    let store: HostStore?

    public init(activeHost: ClutchHost? = nil, store: HostStore? = nil) {
        self.activeHost = activeHost
        self.store = store
    }

    private var deviceUid: String { MacChatIdentity.deviceUid }

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

    /// The models the picked engine offers, from the catalog.
    private var engineModels: [EngineModel] {
        catalog?.descriptor(engine.sidecarId)?.models ?? []
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
    private func loadCatalog() async {
        guard let host = activeHost else { return }
        let loaded = try? await EngineCatalogClient(host: host).fetch()
        catalog = loaded
        guard let loaded else { return }
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
    /// engine's own default, named but not sent.
    private var displayModel: String {
        if let selectedModel { return selectedModel }
        return engineModels.first?.displayLabel ?? engine.label
    }

    private var rows: [Row] {
        if engine.supportsThreads { return codeRows }
        let promptRows = localPrompts.map {
            Row(id: $0.id.uuidString, text: $0.text, date: $0.at, fromAgent: false, isCard: false)
        }
        let bubbleRows = agentBubbles.map {
            Row(id: $0.id, text: $0.text, date: $0.date, fromAgent: $0.senderUid != deviceUid, isCard: $0.kind == "card")
        }
        let toolRows = liveTools.map {
            Row(id: "live-\($0.id)", text: $0.name, date: Date(), fromAgent: true, isCard: false, toolStatus: $0.status)
        }
        return (promptRows + bubbleRows).sorted { $0.date < $1.date } + toolRows
    }

    /// MiniMax Code rows keep server order (replayed history is already
    /// chronological); in-flight prompts and the live bubble append after.
    private var codeRows: [Row] {
        var out = codeLoaded.enumerated().map { index, entry in
            Row(
                id: "code-\(index)-\(entry.text.hashValue)",
                text: entry.text,
                date: Date(),
                fromAgent: entry.kind != "user_message_chunk",
                isCard: false,
                isThought: entry.kind == "agent_thought_chunk",
                toolStatus: entry.isTool ? (entry.toolStatus ?? "completed") : nil
            )
        }
        out += codePending.map {
            Row(id: $0.id.uuidString, text: $0.text, date: $0.at, fromAgent: false, isCard: false)
        }
        out += liveTools.map {
            Row(id: "live-\($0.id)", text: $0.name, date: Date(), fromAgent: true, isCard: false, toolStatus: $0.status)
        }
        return out
    }

    public var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if engine.supportsThreads && showingSidebar {
                    ThreadSidebar(
                        sessions: sidebarSessions,
                        selectedId: codeRemoteId,
                        loading: sidebarLoading,
                        loadingId: sidebarLoadingId,
                        errorText: sidebarError,
                        projects: sidebarProjects,
                        onSelect: { session in openSession(session, fromSidebar: true) },
                        onNew: { startMcodeThread() },
                        onRefresh: { Task { await loadSidebarSessions() } },
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
                        fixedWidth: sidebarWidth,
                        onResize: { width in
                            sidebarWidth = width
                        },
                        onResizeEnd: { width in
                            // Persist once when the drag finishes; saving on
                            // every drag event hammered UserDefaults per frame.
                            MacSidebarWidth.save(width)
                        }
                    )
                    Divider()
                }
                chatPane
            }
            .navigationTitle("Chat")
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
                    if engine.supportsThreads {
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
        .task(id: activeHost?.id) {
            await prepare()
        }
        .task(id: engine) {
            if engine.supportsThreads { await loadSidebarSessions() }
        }
        .sheet(isPresented: $showingSessions) {
            if let host = activeHost {
                MacSessionsSheet(host: host, engine: engine.sidecarId) { _, chatId, remoteId, cwd, history in
                    adopt(chatId: chatId, remoteId: remoteId, cwd: cwd, history: history, for: engine)
                }
            }
        }
        .onChange(of: activeHost?.id) { _, _ in
            // A different host means a different engine catalog and a
            // different thread list; both are re-read by prepare(), and the
            // stale list goes first so the rail never shows another
            // machine's threads.
            sidebarSessions = []
            codeChatId = nil
            codeRemoteId = nil
            codeLoaded = []
            codePending = []
            resetTurnState()
            Task { await prepare() }
        }
    }

    private var chatPane: some View {
        VStack(spacing: 0) {
            modelStrip
            if engine.supportsThreads {
                cwdBar
            }
            if showFind {
                findBar
            }
            Divider()
            threadSurface
            if sending, !streamingText.isEmpty {
                liveBubble
            }
            if let thought = thoughtLine, !thought.isEmpty {
                thoughtRow(thought)
            }
            if let error = sendError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            MacChatInputBar(
                draft: $draft,
                sending: sending,
                onSend: { send(draft) },
                onStop: { stop() },
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
        }
        .onChange(of: dictation.transcript) { _, text in
            guard dictation.isRecording || !text.isEmpty else { return }
            draft = draftBase + (draftBase.isEmpty || text.isEmpty ? "" : " ") + text
        }
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
        HStack(spacing: 8) {
            Picker("Engine", selection: engineBinding) {
                ForEach(availableEngines) { candidate in
                    Text(candidate.label).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 264)

            // The model picker, straight from the host's catalog.  This is
            // the web canvas's picker: whatever the engine advertises right
            // now, so a new provider model appears without a Mac release.
            if !engineModels.isEmpty {
                Menu {
                    ForEach(engineModels) { entry in
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
                } label: {
                    pickerLabel(entryLabel: displayModel, symbol: "cpu")
                }
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
                    pickerLabel(entryLabel: (selectedEffort ?? "default").capitalized, symbol: "gauge.with.dots.needle.50percent")
                }
            }

            if engine == .mcode && !mcodeAvailable {
                Label("mcode Not Found On Host", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("The sidecar answered, but MiniMax Code is not installed or not signed in on that host.")
            }

            Spacer()

            usageStrip

            if engine.supportsThreads {
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
                // The shared host picker: the Mac and the phone pick a server
                // the same way, so a code server on another machine is one
                // click away on either.
                HostSwitcher(host: host, store: store, compact: true)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(statusHelp(for: host))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.clutchBackground)
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
        if engine == .mcode {
            HStack(spacing: 8) {
                if let usage = activeUsage {
                    if let rate = usage.rateLabel {
                        metric(icon: "speedometer", value: rate)
                    }
                    if let occupancy = usage.occupancyLabel {
                        metric(icon: "chart.pie.fill", value: occupancy)
                    }
                } else {
                    Text("Usage not reported yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
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

    private var engineBinding: Binding<ChatEngine> {
        Binding(
            get: { engine },
            set: { selectEngine($0) }
        )
    }

    private func pickerLabel(entryLabel: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11))
            Text(entryLabel)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
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
        engine = next
        MacEngineStore.save(next)
        resetTurnState()
        sessionId = nil
        if next.supportsThreads {
            // Resume, not reset: prepare() reopens the last thread for this
            // host.  Clearing it is what the sidebar's New Thread button is
            // for (startMcodeThread).
            Task { await prepare() }
            return
        }
        // The agent engines keep their own model names; a model chosen for
        // another engine does not carry over.
        selectedModel = nil
        Task {
            await loadCatalog()
            await prepare()
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
            sidecarReachable = health.ok
            mcodeAvailable = health.mcodeAvailable
        } catch {
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
                    if engine.supportsThreads {
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
                        }
                        .onChange(of: rows.count) {
                            if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
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
        guard engine.supportsThreads else {
            selectEngine(.mcode)
            return
        }
        MacEngineStore.save(engine)
        resetTurnState()
        sessionId = nil
        codeChatId = nil
        codeRemoteId = nil
        codeCwd = nil
        codeLoaded = []
        codePending = []
        phase = .ready
        if let host = activeHost {
            MacMcodeStore.clear(for: host)
        }
        if !showingSidebar { showingSidebar = true }
    }

    /// Adopt a freshly loaded code-engine thread into the chat pane.
    private func adopt(chatId: String, remoteId: String, cwd: String?, history: [AcpHistoryEntry], for engine: ChatEngine) {
        self.engine = engine
        MacEngineStore.save(engine)
        resetTurnState()
        codeChatId = chatId
        codeRemoteId = remoteId
        codeCwd = cwd
        codeLoaded = history
        codePending = []
        phase = .ready
        if let host = activeHost {
            MacMcodeStore.save(remoteId: remoteId, cwd: cwd, engine: engine.sidecarId, for: host)
        }
    }

    /// Resume one thread.  `cwd` must travel with the session id: the sidecar
    /// defaults a missing cwd to `$HOME`, and the ACP bridge then refuses any
    /// thread whose persisted workspace is elsewhere.
    private func openSession(_ session: AcpSessionInfo, fromSidebar: Bool) {
        guard let host = activeHost else { return }
        if fromSidebar {
            sidebarLoadingId = session.sessionId
            sidebarError = nil
        }
        let target = engine
        Task {
            defer { if fromSidebar { sidebarLoadingId = nil } }
            do {
                let loaded = try await SessionsClient(host: host).load(
                    sessionId: session.sessionId,
                    cwd: session.cwd,
                    engine: target.sidecarId,
                    model: selectedModel,
                    effort: selectedEffort
                )
                adopt(chatId: loaded.chatId, remoteId: loaded.remoteSessionId, cwd: loaded.cwd, history: loaded.history, for: target)
            } catch {
                if fromSidebar {
                    sidebarError = codeLoadErrorMessage(error, session: session)
                } else {
                    sendError = codeLoadErrorMessage(error, session: session)
                }
            }
        }
    }

    private func loadSidebarSessions() async {
        guard let host = activeHost, engine.supportsThreads else { return }
        sidebarLoading = true
        defer { sidebarLoading = false }
        do {
            let client = SessionsClient(host: host)
            sidebarSessions = try await client.list(engine: engine.sidecarId, includingArchived: showArchived)
            sidebarError = nil
            // Project names live only in the metadata store, so the sidebar
            // needs its own read.  A failure here must not blank the thread
            // list, which is the thing the user actually asked for.
            if let meta = try? await client.meta() {
                sidebarProjects = meta.projects
            }
        } catch {
            // Keep whatever list we already have; a retry is one click away.
            if sidebarSessions.isEmpty {
                sidebarError = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: - Sidebar actions

    private func handle(_ action: ThreadSidebarAction, _ session: AcpSessionInfo) {
        switch action {
        case let .revealInFinder(session):
            if let cwd = session.cwd, !cwd.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
            }

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

    private func applyMeta(sessionId: String, projectId: String?? = nil, archived: Bool? = nil) async {
        guard let host = activeHost else { return }
        do {
            let meta = try await SessionsClient(host: host).updateMeta(
                sessionId: sessionId,
                projectId: projectId,
                archived: archived
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

    /// The sidecar answers a failed resume with a bare ACP reason, so name the
    /// thread and say what to try rather than showing a raw params error.
    private func codeLoadErrorMessage(_ error: Error, session: AcpSessionInfo) -> String {
        let detail = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
        let name = session.title ?? session.sessionId
        return Copy.gap(
            "Could not resume \"\(name)\".",
            "\(detail) Refresh the list, or start a new thread."
        )
    }

    private func resetTurnState() {
        sending = false
        streamingText = ""
        thoughtLine = nil
        sendError = nil
    }

    private func prepare() async {
        guard let host = activeHost else { return }
        pinnedIds = ThreadPinStore.pinnedIDs(forHost: host.id)
        // The catalog can take a while on a cold server, so the thread list
        // and the health check do not wait for it.
        async let catalogTask = loadCatalog()
        await checkSidecar()
        // The saved engine wins, so a relaunch returns to the thread the
        // owner was working in instead of an empty tab.  Whether the host
        // actually runs it is settled once the catalog lands.
        if let saved = MacEngineStore.load() {
            engine = saved
        }
        _ = await catalogTask
        // The host's catalog decides which engines this Mac can offer: a
        // server with Muse Code but no MiniMax Code shows Muse Code only.
        if !availableEngines.contains(where: { $0 == engine }), let first = availableEngines.first {
            engine = first
        }
        if engine.supportsThreads {
            // Reopen the last thread for this host when there is one, so a
            // finished turn survives relaunch instead of going nowhere.
            if let saved = MacMcodeStore.load(for: host) {
                let savedEngine = ChatEngine(rawValue: saved.engine ?? "mcode") ?? .mcode
                do {
                    let loaded = try await SessionsClient(host: host).load(
                        sessionId: saved.remoteId,
                        cwd: saved.cwd,
                        engine: savedEngine.sidecarId
                    )
                    adopt(chatId: loaded.chatId, remoteId: loaded.remoteSessionId, cwd: loaded.cwd, history: loaded.history, for: savedEngine)
                    return
                } catch {
                    MacMcodeStore.clear(for: host)
                }
            }
            codeChatId = nil
            codeRemoteId = nil
            codeLoaded = []
            codePending = []
            phase = .ready
            return
        }
        phase = .loading
        do {
            agentBubbles = try await ChatThreadClient(host: host).fetch(deviceUid: deviceUid)
            phase = .ready
        } catch {
            phase = .failed(chatErrorMessage(error))
        }
    }

    private func refreshThread() async {
        guard let host = activeHost, phase == .ready else { return }
        if engine.supportsThreads {
            guard let remoteId = codeRemoteId else { return }
            do {
                let loaded = try await SessionsClient(host: host).load(
                    sessionId: remoteId,
                    cwd: codeCwd,
                    engine: engine.sidecarId
                )
                codeChatId = loaded.chatId
                codeCwd = loaded.cwd
                codeLoaded = loaded.history
                codePending = []
            } catch {
                // Keep the in-view thread; the next send or pull retries.
            }
            return
        }
        do {
            agentBubbles = try await ChatThreadClient(host: host).fetch(deviceUid: deviceUid)
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

    private func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !sending else { return }
        guard let host = activeHost else { return }
        guard host.chatToken?.isEmpty == false else {
            sendError = chatErrorMessage(ChatClientError.missingToken)
            return
        }
        draft = ""
        sendError = nil
        sending = true
        streamingText = ""
        liveTools = []
        if engine.supportsThreads {
            codePending.append(LocalPrompt(text: prompt, at: Date()))
        } else {
            localPrompts.append(LocalPrompt(text: prompt, at: Date()))
            MacChatStore.savePrompts(localPrompts)
        }
        let client = ChatSessionClient(
            host: host,
            model: selectedModel ?? "",
            sessionId: engine.supportsThreads ? codeChatId : sessionId,
            relayReceiverUid: deviceUid,
            // The engine always rides along: without it the sidecar routes
            // by model name, and a MiniMax turn with no model named would
            // land on DeepSeek.
            engine: engine.sidecarId,
            cwd: engine.supportsThreads ? codeCwd : nil,
            effort: selectedEffort,
            images: attachments
        )
        attachments = []
        sendTask = Task {
            do {
                for try await event in client.stream(prompt: prompt) {
                    switch event {
                    case .started(let id, _):
                        if engine.supportsThreads {
                            codeChatId = id
                        } else {
                            sessionId = id
                        }
                    case .message(let chunk):
                        thoughtLine = nil
                        streamingText += chunk
                    case .thought(let text):
                        thoughtLine = String(text.prefix(220))
                    case .tool(let id, let name, let status):
                        let key = id.isEmpty ? name : id
                        if let index = liveTools.firstIndex(where: { $0.id == key }) {
                            liveTools[index].status = status
                            if !name.isEmpty { liveTools[index].name = name }
                        } else {
                            liveTools.append(LiveTool(id: key, name: name.isEmpty ? "Tool call" : name, status: status))
                        }
                    case .done(let stop, let id, let remoteId):
                        if engine.supportsThreads {
                            codeChatId = id
                            if let remoteId, !remoteId.isEmpty {
                                codeRemoteId = remoteId
                                MacMcodeStore.save(remoteId: remoteId, cwd: codeCwd, engine: engine.sidecarId, for: host)
                            }
                            if !streamingText.isEmpty {
                                codeLoaded.append(AcpHistoryEntry(sessionId: "local", kind: "agent_message_chunk", text: streamingText))
                            }
                            for tool in liveTools {
                                codeLoaded.append(AcpHistoryEntry(sessionId: "local", kind: "tool_call", text: tool.name, toolCallId: tool.id, toolStatus: tool.status))
                            }
                        } else {
                            sessionId = id
                        }
                        liveTools = []
                        TurnNotifier.turnFinished(threadTitle: engine.supportsThreads ? (sidebarSessions.first(where: { $0.sessionId == codeRemoteId })?.displayTitle ?? engine.label) : (selectedModel ?? engine.label))
                        sending = false
                        streamingText = ""
                        thoughtLine = nil
                        if stop != "endTurn" && stop != "end_turn" && stop != "cancelled" {
                            sendError = "Turn ended: \(stop)"
                        } else if !engine.supportsThreads {
                            await refreshThread()
                        }
                    case .usage(let usage):
                        activeUsage = usage
                    case .failed(let message):
                        sending = false
                        streamingText = ""
                        thoughtLine = nil
                        sendError = message
                        liveTools = []
                        TurnNotifier.turnFinished(threadTitle: engine.supportsThreads ? engine.label : (selectedModel ?? engine.label), failed: true)
                    }
                }
                sending = false
            } catch {
                sending = false
                streamingText = ""
                thoughtLine = nil
                sendError = error.localizedDescription
            }
        }
    }

    private var transcriptMarkdown: String {
        let entries = rows.map { row in
            TranscriptExport.Entry(
                role: row.toolStatus != nil ? .tool : row.isThought ? .thought : row.fromAgent ? .assistant : .user,
                text: row.text
            )
        }
        let title = engine.supportsThreads
            ? (sidebarSessions.first(where: { $0.sessionId == codeRemoteId })?.displayTitle ?? "\(engine.label) Thread")
            : "\(selectedModel ?? engine.label) Thread"
        return TranscriptExport.markdown(title: title, cwd: engine.supportsThreads ? displayCwd : nil, entries: entries)
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
    private func stop() {
        guard sending else { return }
        if let host = activeHost, let chatId = engine.supportsThreads ? codeChatId : sessionId {
            Task { await ChatSessionClient.cancel(host: host, sessionId: chatId) }
        }
        sendTask?.cancel()
        sendTask = nil
        sending = false
        streamingText = ""
        thoughtLine = nil
    }
}

/// MiniMax Code thread browser: list, resume, and hand the replayed
/// history back to the Chat tab.
struct MacSessionsSheet: View {
    var host: ClutchHost
    /// The engine whose threads the sheet lists.
    var engine: String = "mcode"
    /// Carries the listed session so the resume can send its own `cwd`.
    var onLoaded: (AcpSessionInfo, String, String, String?, [AcpHistoryEntry]) -> Void

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
                                            Text(session.title ?? session.sessionId)
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
            .navigationTitle(engine == "muse" ? "Muse Code Threads" : "MiniMax Code Threads")
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
            onLoaded(session, loaded.chatId, loaded.remoteSessionId, loaded.cwd, loaded.history)
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
            ThreadToolCard(name: row.text, status: toolStatus)
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

/// Native input bar (no voice on Mac v1 — hold-to-record is a stub on iOS too).
struct MacChatInputBar: View {
    @Binding var draft: String
    var sending: Bool
    var onSend: () -> Void
    var onStop: () -> Void
    var isDictating: Bool = false
    var onMic: () -> Void = {}
    /// Images attached to the next turn.
    var attachments: [ChatAttachment] = []
    var onAttach: () -> Void = {}
    var onRemoveAttachment: (ChatAttachment) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 4) {
            if !attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                                .font(.system(size: 10))
                            Text(attachment.displayName)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Button {
                                onRemoveAttachment(attachment)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(attachment.displayName)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.clutchSecondaryBackground, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: onMic) {
                    Image(systemName: isDictating ? "mic.fill" : "mic")
                        .font(.system(size: 15))
                        .foregroundStyle(isDictating ? Color.red : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .accessibilityLabel(isDictating ? "Stop Dictation" : "Dictate")
                .help(isDictating ? "Stop Dictation" : "Dictate A Message")
                Button(action: onAttach) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .accessibilityLabel("Attach Image")
                .help("Attach An Image")
                TextField("Message The Agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                    .disabled(sending)
                    .onSubmit(onSend)
                if sending {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                    .help("Stop This Turn")
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send Message")
                    .help("Send (Return)")
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            HStack(spacing: 8) {
                Text(sending ? Copy.gap("Working…", "Stop Ends The Turn And Keeps The Thread.") : "Return Sends · Shift+Return Adds A Line · ⌘Return Also Sends.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if draft.count >= 200 {
                    Text("\(draft.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.clutchBackground)
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
        /// The engine the thread belongs to (`mcode` or `muse`).  Absent in
        /// records written before Muse Code existed: those are MiniMax Code.
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
