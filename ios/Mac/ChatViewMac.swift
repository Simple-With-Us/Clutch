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
/// by model on the sidecar; MiniMax Code resumes a direct `mcode` thread.
enum ChatEngine: String {
    case deepseek
    case minimax
    case mcode
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
    @State private var mcodeChatId: String?
    @State private var mcodeRemoteId: String?
    @State private var mcodeCwd: String?
    @State private var mcodeLoaded: [AcpHistoryEntry] = []
    @State private var mcodePending: [LocalPrompt] = []
    @State private var showingSessions = false
    @State private var showingSidebar = true
    @State private var sidebarSessions: [AcpSessionInfo] = []
    @State private var sidebarLoading = false
    @State private var sidebarError: String?
    @State private var sidebarLoadingId: String?
    @State private var selectedModel: String = "DeepSeek-V4.1-Pro"
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

    struct LiveTool: Identifiable, Equatable {
        var id: String
        var name: String
        var status: String
    }

    let activeHost: ClutchHost?

    public init(activeHost: ClutchHost? = nil) {
        self.activeHost = activeHost
    }

    private var deviceUid: String { MacChatIdentity.deviceUid }

    private var rows: [Row] {
        if engine == .mcode { return mcodeRows }
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
    private var mcodeRows: [Row] {
        var out = mcodeLoaded.enumerated().map { index, entry in
            Row(
                id: "mcode-\(index)-\(entry.text.hashValue)",
                text: entry.text,
                date: Date(),
                fromAgent: entry.kind != "user_message_chunk",
                isCard: false,
                isThought: entry.kind == "agent_thought_chunk",
                toolStatus: entry.isTool ? (entry.toolStatus ?? "completed") : nil
            )
        }
        out += mcodePending.map {
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
                if engine == .mcode && showingSidebar {
                    ThreadSidebar(
                        sessions: sidebarSessions,
                        selectedId: mcodeRemoteId,
                        loading: sidebarLoading,
                        loadingId: sidebarLoadingId,
                        errorText: sidebarError,
                        onSelect: { session in openSession(session, fromSidebar: true) },
                        onNew: { startMcodeThread() },
                        onRefresh: { Task { await loadSidebarSessions() } },
                        pinnedIds: pinnedIds,
                        onTogglePin: { session in
                            guard let host = activeHost else { return }
                            ThreadPinStore.toggle(session.sessionId, forHost: host.id)
                            pinnedIds = ThreadPinStore.pinnedIDs(forHost: host.id)
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
                    if engine == .mcode {
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
            if engine == .mcode { await loadSidebarSessions() }
        }
        .sheet(isPresented: $showingSessions) {
            if let host = activeHost {
                MacSessionsSheet(host: host) { _, chatId, remoteId, cwd, history in
                    adopt(chatId: chatId, remoteId: remoteId, cwd: cwd, history: history)
                }
            }
        }
    }

    private var chatPane: some View {
        VStack(spacing: 0) {
            modelStrip
            if engine == .mcode {
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
                cwdDraft = mcodeCwd ?? ""
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
                            mcodeCwd = trimmed.isEmpty ? nil : trimmed
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
        if let cwd = mcodeCwd, !cwd.isEmpty { return cwd }
        if let selected = sidebarSessions.first(where: { $0.sessionId == mcodeRemoteId })?.cwd, !selected.isEmpty { return selected }
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
            mcodeCwd = url.path
        }
    }

    // MARK: - Header

    private var modelStrip: some View {
        HStack(spacing: 8) {
            Picker("Engine", selection: engineBinding) {
                Text("DeepSeek").tag(ChatEngine.deepseek)
                Text("MiniMax").tag(ChatEngine.minimax)
                Text("MiniMax Code").tag(ChatEngine.mcode)
            }
            .pickerStyle(.segmented)
            .frame(width: 264)

            if engine != .mcode {
                Menu {
                    Section(engine == .minimax ? "MiniMax" : "DeepSeek") {
                        if engine == .minimax {
                            Button("MiniMax-M3.1-Flash") { selectModel("MiniMax-M3.1-Flash") }
                            Button("MiniMax-M3") { selectModel("MiniMax-M3") }
                            Button("MiniMax-M2.7-highspeed") { selectModel("MiniMax-M2.7-highspeed") }
                        } else {
                            Button("DeepSeek-V4.1-Pro") { selectModel("DeepSeek-V4.1-Pro") }
                            Button("DeepSeek-V4.1-Flash") { selectModel("DeepSeek-V4.1-Flash") }
                        }
                    }
                    Section("MiniMax Code") {
                        Button("Resume Thread…") {
                            selectEngine(.mcode)
                            showingSessions = true
                        }
                        Button("New Thread") { startMcodeThread() }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                        Text(selectedModel)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.clutchSecondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            } else if !mcodeAvailable {
                Label("mcode Not Found On Host", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("The sidecar answered, but MiniMax Code is not installed or not signed in on that host.")
            }

            Spacer()

            if engine == .mcode {
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

            if let host = activeHost {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor(for: host))
                        .frame(width: 6, height: 6)
                    Text(host.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .help(statusHelp(for: host))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.clutchBackground)
    }

    private var engineBinding: Binding<ChatEngine> {
        Binding(
            get: { engine },
            set: { selectEngine($0) }
        )
    }

    private func selectEngine(_ next: ChatEngine) {
        guard next != engine else { return }
        if next == .mcode {
            // Resume, not reset: prepare() reopens the last thread for this
            // host.  Clearing it is what the sidebar's New Thread button is
            // for (startMcodeThread).
            engine = .mcode
            MacEngineStore.save(.mcode)
            resetTurnState()
            Task { await prepare() }
            return
        }
        engine = next
        MacEngineStore.save(next)
        if next == .minimax, !selectedModel.lowercased().hasPrefix("minimax") {
            selectedModel = "MiniMax-M3.1-Flash"
        }
        if next == .deepseek, selectedModel.lowercased().hasPrefix("minimax") {
            selectedModel = "DeepSeek-V4.1-Pro"
        }
        resetTurnState()
        sessionId = nil
        Task { await prepare() }
    }

    private func statusColor(for host: ClutchHost) -> Color {
        if let reachable = sidecarReachable { return reachable ? .green : .red }
        return host.status == .online ? .green : .orange
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
                    if engine == .mcode {
                        MacChatSetupCard(
                            symbol: "terminal",
                            title: "MiniMax Code",
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

    private func selectModel(_ model: String) {
        selectedModel = model
        engine = model.lowercased().hasPrefix("minimax") ? .minimax : .deepseek
        MacEngineStore.save(engine)
        resetTurnState()
        sessionId = nil
        Task { await prepare() }
    }

    private func startMcodeThread() {
        engine = .mcode
        MacEngineStore.save(engine)
        resetTurnState()
        sessionId = nil
        mcodeChatId = nil
        mcodeRemoteId = nil
        mcodeCwd = nil
        mcodeLoaded = []
        mcodePending = []
        phase = .ready
        if let host = activeHost {
            MacMcodeStore.clear(for: host)
        }
        if !showingSidebar { showingSidebar = true }
    }

    /// Adopt a freshly loaded MiniMax Code thread into the chat pane.
    private func adopt(chatId: String, remoteId: String, cwd: String?, history: [AcpHistoryEntry]) {
        engine = .mcode
        MacEngineStore.save(engine)
        resetTurnState()
        mcodeChatId = chatId
        mcodeRemoteId = remoteId
        mcodeCwd = cwd
        mcodeLoaded = history
        mcodePending = []
        phase = .ready
        if let host = activeHost {
            MacMcodeStore.save(remoteId: remoteId, cwd: cwd, for: host)
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
        Task {
            defer { if fromSidebar { sidebarLoadingId = nil } }
            do {
                let loaded = try await SessionsClient(host: host).load(
                    sessionId: session.sessionId,
                    cwd: session.cwd
                )
                adopt(chatId: loaded.chatId, remoteId: loaded.remoteSessionId, cwd: loaded.cwd, history: loaded.history)
            } catch {
                if fromSidebar {
                    sidebarError = mcodeLoadErrorMessage(error, session: session)
                } else {
                    sendError = mcodeLoadErrorMessage(error, session: session)
                }
            }
        }
    }

    private func loadSidebarSessions() async {
        guard let host = activeHost, engine == .mcode else { return }
        sidebarLoading = true
        defer { sidebarLoading = false }
        do {
            sidebarSessions = try await SessionsClient(host: host).list()
            sidebarError = nil
        } catch {
            // Keep whatever list we already have; a retry is one click away.
            if sidebarSessions.isEmpty {
                sidebarError = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
            }
        }
    }

    /// The sidecar answers a failed resume with a bare ACP reason, so name the
    /// thread and say what to try rather than showing a raw params error.
    private func mcodeLoadErrorMessage(_ error: Error, session: AcpSessionInfo) -> String {
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
        await checkSidecar()
        if engine != .mcode, MacEngineStore.load() == .mcode {
            engine = .mcode
        }
        if engine == .mcode {
            // Reopen the last thread for this host when there is one, so a
            // finished turn survives relaunch instead of going nowhere.
            if let saved = MacMcodeStore.load(for: host) {
                do {
                    let loaded = try await SessionsClient(host: host).load(
                        sessionId: saved.remoteId,
                        cwd: saved.cwd
                    )
                    adopt(chatId: loaded.chatId, remoteId: loaded.remoteSessionId, cwd: loaded.cwd, history: loaded.history)
                    return
                } catch {
                    MacMcodeStore.clear(for: host)
                }
            }
            mcodeChatId = nil
            mcodeRemoteId = nil
            mcodeLoaded = []
            mcodePending = []
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
        if engine == .mcode {
            guard let remoteId = mcodeRemoteId else { return }
            do {
                let loaded = try await SessionsClient(host: host).load(
                    sessionId: remoteId,
                    cwd: mcodeCwd
                )
                mcodeChatId = loaded.chatId
                mcodeCwd = loaded.cwd
                mcodeLoaded = loaded.history
                mcodePending = []
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
        if engine == .mcode {
            mcodePending.append(LocalPrompt(text: prompt, at: Date()))
        } else {
            localPrompts.append(LocalPrompt(text: prompt, at: Date()))
            MacChatStore.savePrompts(localPrompts)
        }
        let client = ChatSessionClient(
            host: host,
            model: selectedModel,
            sessionId: engine == .mcode ? mcodeChatId : sessionId,
            relayReceiverUid: deviceUid,
            engine: engine == .mcode ? "mcode" : nil,
            cwd: engine == .mcode ? mcodeCwd : nil
        )
        sendTask = Task {
            do {
                for try await event in client.stream(prompt: prompt) {
                    switch event {
                    case .started(let id, _):
                        if engine == .mcode {
                            mcodeChatId = id
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
                        if engine == .mcode {
                            mcodeChatId = id
                            if let remoteId, !remoteId.isEmpty {
                                mcodeRemoteId = remoteId
                                MacMcodeStore.save(remoteId: remoteId, cwd: mcodeCwd, for: host)
                            }
                            if !streamingText.isEmpty {
                                mcodeLoaded.append(AcpHistoryEntry(sessionId: "local", kind: "agent_message_chunk", text: streamingText))
                            }
                            for tool in liveTools {
                                mcodeLoaded.append(AcpHistoryEntry(sessionId: "local", kind: "tool_call", text: tool.name, toolCallId: tool.id, toolStatus: tool.status))
                            }
                        } else {
                            sessionId = id
                        }
                        liveTools = []
                        TurnNotifier.turnFinished(threadTitle: engine == .mcode ? (sidebarSessions.first(where: { $0.sessionId == mcodeRemoteId })?.displayTitle ?? "MiniMax Code") : selectedModel)
                        sending = false
                        streamingText = ""
                        thoughtLine = nil
                        if stop != "endTurn" && stop != "end_turn" && stop != "cancelled" {
                            sendError = "Turn ended: \(stop)"
                        } else if engine != .mcode {
                            await refreshThread()
                        }
                    case .failed(let message):
                        sending = false
                        streamingText = ""
                        thoughtLine = nil
                        sendError = message
                        liveTools = []
                        TurnNotifier.turnFinished(threadTitle: engine == .mcode ? "MiniMax Code" : selectedModel, failed: true)
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
        let title = engine == .mcode
            ? (sidebarSessions.first(where: { $0.sessionId == mcodeRemoteId })?.displayTitle ?? "MiniMax Code Thread")
            : "\(selectedModel) Thread"
        return TranscriptExport.markdown(title: title, cwd: engine == .mcode ? displayCwd : nil, entries: entries)
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
        if let host = activeHost, let chatId = engine == .mcode ? mcodeChatId : sessionId {
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
            .navigationTitle("MiniMax Code Threads")
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
            sessions = try await SessionsClient(host: host).list()
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
                cwd: session.cwd
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

    var body: some View {
        VStack(spacing: 4) {
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
                Text(sending ? "Working… Stop Ends The Turn And Keeps The Thread." : "Return Sends · Shift+Return Adds A Line · ⌘Return Also Sends.")
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
    }

    private static func map() -> [String: Saved] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Saved].self, from: data) else { return [:] }
        return decoded
    }

    static func load(for host: ClutchHost) -> Saved? {
        map()[host.id.uuidString]
    }

    static func save(remoteId: String, cwd: String?, for host: ClutchHost) {
        var current = map()
        current[host.id.uuidString] = Saved(remoteId: remoteId, cwd: cwd)
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
