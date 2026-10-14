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
    }

    @State private var phase: Phase = .loading
    @State private var agentBubbles: [ThreadBubble] = []
    @State private var localPrompts: [LocalPrompt] = MacChatStore.loadPrompts()
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
        let promptRows = localPrompts.map {
            Row(id: $0.id.uuidString, text: $0.text, date: $0.at, fromAgent: false, isCard: false)
        }
        let bubbleRows = agentBubbles.map {
            Row(id: $0.id, text: $0.text, date: $0.date, fromAgent: $0.senderUid != deviceUid, isCard: $0.kind == "card")
        }
        return (promptRows + bubbleRows).sorted { $0.date < $1.date }
    }

    public var body: some View {
        NavigationStack {
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
            .navigationTitle("Chat")
        }
        .task(id: activeHost?.id) {
            await prepare()
        }
    }

    // MARK: - Header

    private var modelStrip: some View {
        HStack(spacing: 8) {
            Menu {
                Button("DeepSeek-V4.1-Pro") { selectedModel = "DeepSeek-V4.1-Pro" }
                Button("DeepSeek-V4.1-Flash") { selectedModel = "DeepSeek-V4.1-Flash" }
                Button("MiniMax-M3.1-Flash-Preview") { selectedModel = "MiniMax-M3.1-Flash-Preview" }
                Button("MiniMax-M3") { selectedModel = "MiniMax-M3" }
                Button("MiniMax-M2.7-highspeed") { selectedModel = "MiniMax-M2.7-highspeed" }
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
                    MacChatSetupCard(
                        symbol: "bubble.left.and.bubble.right",
                        title: "Start the Thread",
                        message: "Send the first prompt below — the turn streams back live."
                    )
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

    private func prepare() async {
        guard let host = activeHost else { return }
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
        localPrompts.append(LocalPrompt(text: prompt, at: Date()))
        MacChatStore.savePrompts(localPrompts)
        let client = ChatSessionClient(host: host, model: selectedModel, sessionId: sessionId, relayReceiverUid: deviceUid)
        Task {
            do {
                for try await event in client.stream(prompt: prompt) {
                    switch event {
                    case .started(let id, _):
                        sessionId = id
                    case .message(let chunk):
                        thoughtLine = nil
                        streamingText += chunk
                    case .thought(let text):
                        thoughtLine = String(text.prefix(220))
                    case .done(let stop, let id):
                        sessionId = id
                        sending = false
                        streamingText = ""
                        thoughtLine = nil
                        if stop != "endTurn" && stop != "cancelled" {
                            sendError = "Turn ended: \(stop)"
                        } else {
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

/// Thread bubble and user prompt rows.
struct MacChatRow: View {
    var row: ChatView.Row

    var body: some View {
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
