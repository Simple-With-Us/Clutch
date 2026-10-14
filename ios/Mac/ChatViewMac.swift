import SwiftUI
import Foundation

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

/// One MiniMax Code session from `GET /clutch/v1/sessions`.
struct AcpSessionInfo: Decodable, Identifiable {
    var sessionId: String
    var cwd: String?
    var title: String?
    var updatedAt: String?
    var id: String { sessionId }

    /// The sidecar sends ISO-8601 with milliseconds and a `Z` suffix; tolerate
    /// the plain form too so a thread without them still sorts sensibly.
    static func updatedDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

/// One replayed update from `POST /clutch/v1/sessions/load`.
struct AcpHistoryEntry: Decodable, Equatable {
    var sessionId: String
    var kind: String
    var text: String
}

/// Minimal client for the mcode session endpoints (see `chat-bridge.ts`).
/// Same chat-token gate as everything else on the sidecar.
struct McodeSessionsClient {
    var host: ClutchHost

    private func authorized(_ url: URL) throws -> URLRequest {
        guard let token = host.chatToken, !token.isEmpty else { throw ChatClientError.missingToken }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Session discovery and full-history replay cross process spawns on
        // a loaded Mac; the old 30s budget timed out routinely.
        req.timeoutInterval = 90
        return req
    }

    private func base() throws -> URLComponents {
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        guard comps.url != nil else { throw ChatClientError.badHost }
        return comps
    }

    func list(limit: Int = 100) async throws -> [AcpSessionInfo] {
        var comps = try base()
        comps.path = "/clutch/v1/sessions"
        comps.queryItems = [
            URLQueryItem(name: "engine", value: "mcode"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = comps.url else { throw ChatClientError.badHost }
        let (data, resp) = try await URLSession.shared.data(for: authorized(url))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Payload: Decodable { var sessions: [AcpSessionInfo] }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.sessions ?? []
    }

    /// `cwd` is effectively required: the sidecar falls back to `$HOME` when it
    /// is absent, and the ACP bridge then refuses any thread whose persisted
    /// workspace is elsewhere ("Requested cwd does not match the persisted
    /// session workspace").  Always pass the cwd the session was listed with,
    /// or every thread outside `$HOME` fails to resume.
    func load(sessionId: String, cwd: String? = nil, limit: Int = 200) async throws -> (chatId: String, remoteId: String, cwd: String?, history: [AcpHistoryEntry]) {
        var comps = try base()
        comps.path = "/clutch/v1/sessions/load"
        guard let url = comps.url else { throw ChatClientError.badHost }
        var req = try authorized(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["engine": "mcode", "sessionId": sessionId, "limit": limit]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatClientError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Payload: Decodable {
            var sessionId: String
            var remoteSessionId: String?
            var cwd: String?
            var history: [AcpHistoryEntry]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ChatClientError.http(200)
        }
        // The sidecar does not echo cwd back, so keep the one we asked for:
        // the pull-to-refresh path needs it to resume this same thread again.
        return (payload.sessionId, payload.remoteSessionId ?? sessionId, payload.cwd ?? cwd, payload.history ?? [])
    }
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
        return (promptRows + bubbleRows).sorted { $0.date < $1.date }
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
                isThought: entry.kind == "agent_thought_chunk"
            )
        }
        out += mcodePending.map {
            Row(id: $0.id.uuidString, text: $0.text, date: $0.at, fromAgent: false, isCard: false)
        }
        return out
    }

    public var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if engine == .mcode && showingSidebar {
                    MacThreadSidebar(
                        sessions: sidebarSessions,
                        selectedId: mcodeRemoteId,
                        loading: sidebarLoading,
                        loadingId: sidebarLoadingId,
                        errorText: sidebarError,
                        onSelect: { session in openSession(session, fromSidebar: true) },
                        onNew: { startMcodeThread() },
                        onRefresh: { Task { await loadSidebarSessions() } }
                    )
                    Divider()
                }
                chatPane
            }
            .navigationTitle("Chat")
            .toolbar {
                if engine == .mcode {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showingSidebar.toggle() }
                        } label: {
                            Image(systemName: "sidebar.leading")
                        }
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
                onSend: { send(draft) }
            )
        }
    }

    // MARK: - Header

    private var modelStrip: some View {
        HStack(spacing: 8) {
            Menu {
                Section("DeepSeek") {
                    Button("DeepSeek-V4.1-Pro") { selectModel("DeepSeek-V4.1-Pro") }
                    Button("DeepSeek-V4.1-Flash") { selectModel("DeepSeek-V4.1-Flash") }
                }
                Section("MiniMax") {
                    Button("MiniMax-M3.1-Flash-Preview") { selectModel("MiniMax-M3.1-Flash-Preview") }
                    Button("MiniMax-M3") { selectModel("MiniMax-M3") }
                    Button("MiniMax-M2.7-highspeed") { selectModel("MiniMax-M2.7-highspeed") }
                }
                Section("MiniMax Code") {
                    Button("Resume thread…") {
                        engine = .mcode
                        showingSessions = true
                    }
                    Button("New thread") { startMcodeThread() }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11))
                    Text(engine == .mcode ? "MiniMax Code" : selectedModel)
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

            Spacer()

            if let host = activeHost {
                HStack(spacing: 5) {
                    Circle()
                        .fill(host.status == .online ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(host.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.clutchBackground)
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
                                    MacChatRow(row: row)
                                        .id(row.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: rows.count) {
                            if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
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
                let loaded = try await McodeSessionsClient(host: host).load(
                    sessionId: session.sessionId,
                    cwd: session.cwd
                )
                adopt(chatId: loaded.chatId, remoteId: loaded.remoteId, cwd: loaded.cwd, history: loaded.history)
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
            sidebarSessions = try await McodeSessionsClient(host: host).list()
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
        if engine != .mcode, MacEngineStore.load() == .mcode {
            engine = .mcode
        }
        if engine == .mcode {
            // Reopen the last thread for this host when there is one, so a
            // finished turn survives relaunch instead of going nowhere.
            if let saved = MacMcodeStore.load(for: host) {
                do {
                    let loaded = try await McodeSessionsClient(host: host).load(
                        sessionId: saved.remoteId,
                        cwd: saved.cwd
                    )
                    adopt(chatId: loaded.chatId, remoteId: loaded.remoteId, cwd: loaded.cwd, history: loaded.history)
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
                let loaded = try await McodeSessionsClient(host: host).load(
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
            engine: engine == .mcode ? "mcode" : nil
        )
        Task {
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
                        } else {
                            sessionId = id
                        }
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
            sessions = try await McodeSessionsClient(host: host).list()
        } catch {
            self.error = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
        }
    }

    private func load(_ session: AcpSessionInfo) async {
        loadingId = session.sessionId
        error = nil
        defer { loadingId = nil }
        do {
            let loaded = try await McodeSessionsClient(host: host).load(
                sessionId: session.sessionId,
                cwd: session.cwd
            )
            onLoaded(session, loaded.chatId, loaded.remoteId, loaded.cwd, loaded.history)
            dismiss()
        } catch {
            self.error = (error as? ChatClientError)?.localizedDescription ?? error.localizedDescription
        }
    }
}

/// Thread bubble and user prompt rows.
struct MacChatRow: View {
    var row: ChatView.Row

    var body: some View {
        if row.isThought {
            HStack {
                Text(row.text)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                Spacer(minLength: 48)
            }
        } else {
            HStack {
                if !row.fromAgent { Spacer(minLength: 48) }
                VStack(alignment: row.fromAgent ? .leading : .trailing, spacing: 4) {
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
                    if row.isCard {
                        Text("TOOL SUMMARY")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                }
                if row.fromAgent { Spacer(minLength: 48) }
            }
        }
    }
}

/// Native input bar (no voice on Mac v1 — hold-to-record is a stub on iOS too).
struct MacChatInputBar: View {
    @Binding var draft: String
    var sending: Bool
    var onSend: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message the agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .disabled(sending)
                .onSubmit(onSend)
            Button(action: onSend) {
                if sending {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
            }
            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
