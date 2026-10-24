import SwiftUI
import CometChatUIKitSwift
import CometChatSDK

/// The native Chat tab, now on CometChat: the agent thread renders in the
/// kit's message list (live via its socket), the native input bar owns the
/// send path so prompts travel to the Mac sidecar (`POST /clutch/v1/chat`)
/// instead of CometChat's cloud send, and the sidecar relays the turn back
/// into the thread. Model strip and hold-to-record voice stay native.
public struct ChatView: View {
    /// Which surface the Chat tab shows: the CometChat agent thread, or the
    /// host's MiniMax Code threads (the same split view as the Code tab, so
    /// the two entry points can never drift apart).
    enum Surface: Hashable {
        case agent
        case code
    }

    @State private var surface: Surface = .agent
    /// The paired-host store, so the chat surface can switch hosts the way
    /// the web canvas does.  The Mac app uses it to reach a code server.
    let store: HostStore?
    @StateObject private var dictation = DictationController()
    @State private var draftBase = ""
    @State private var manager = CometChatManager.shared
    @State private var selectedModel: String = "DeepSeek-V4.1-Pro"
    @State private var draft: String = ""
    @State private var sessionId: String?
    @State private var sending: Bool = false
    @State private var thoughtLine: String?
    @State private var sendError: String?
    @State private var cardAlert: String?
    @State private var isTranscribingVoice: Bool = false
    @State private var voiceStatusMessage: String?

    let activeHost: ClutchHost?
    let transcriptionService = TranscriptionService.shared

    public init(activeHost: ClutchHost? = nil, store: HostStore? = nil) {
        self.activeHost = activeHost
        self.store = store
    }

    public var body: some View {
        Group {
            if surface == .code, let host = activeHost {
                VStack(spacing: 0) {
                    surfacePicker
                    SessionsView(host: host)
                }
            } else {
                agentBody
            }
        }
        .onAppear {
            if activeHost?.isMiniMaxCodeOnly == true { surface = .code }
        }
    }

    private var surfacePicker: some View {
        Picker("Chat Surface", selection: $surface) {
            Text("Agent").tag(Surface.agent)
            Text("MiniMax Code").tag(Surface.code)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var agentBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                surfacePicker
                // Model header strip
                HStack(spacing: 8) {
                    Menu {
                        Button("DeepSeek-V4.1-Pro") { selectedModel = "DeepSeek-V4.1-Pro" }
                        Button("DeepSeek-V4.1-Flash") { selectedModel = "DeepSeek-V4.1-Flash" }
                        Button("MiniMax-M3.1-Flash") { selectedModel = "MiniMax-M3.1-Flash" }
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
                        .background(Color(.secondarySystemBackground))
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
                .background(Color(.systemBackground))

                Divider()

                if dictation.isRecording {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Listening… Tap The Mic Again To Stop.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1))
                }

                // Thread surface
                if activeHost == nil {
                    Spacer()
                    ChatSetupCard(
                        symbol: "iphone.and.arrow.forward",
                        title: "No Host Paired",
                        message: "Pair with your Mac from Hosts and Settings to start chatting."
                    )
                    Spacer()
                } else {
                    switch manager.phase {
                    case .idle, .loadingConfig, .signingIn:
                        Spacer()
                        ProgressView("Connecting chat…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    case .failed(let message):
                        Spacer()
                        ChatSetupCard(
                            symbol: "bubble.left.and.exclamationmark",
                            title: "Chat Unavailable",
                            message: message
                        )
                        Spacer()
                    case .ready:
                        if let agent = manager.agentUser {
                            AgentThreadView(agent: agent)
                            if let thought = thoughtLine, !thought.isEmpty {
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
                            if let error = sendError {
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                            }
                            ChatInputBar(
                                draft: $draft,
                                sending: sending,
                                onSend: { send(draft) },
                                onVoice: { startVoice() }
                            )
                        } else {
                            Spacer()
                            ProgressView("Loading agent…")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: activeHost?.id) {
                guard let host = activeHost else { return }
                await manager.prepare(host: host)
            }
            .onChange(of: dictation.transcript) { _, text in
                guard dictation.isRecording || !text.isEmpty else { return }
                draft = draftBase + (draftBase.isEmpty || text.isEmpty ? "" : " ") + text
            }
            .onReceive(NotificationCenter.default.publisher(for: .clutchCardAction)) { note in
                cardAlert = (note.userInfo?["title"] as? String) ?? "Card action"
            }
            .alert("Card action", isPresented: Binding(
                get: { cardAlert != nil },
                set: { if !$0 { cardAlert = nil } }
            )) {
                Button("OK", role: .cancel) { cardAlert = nil }
            } message: {
                Text(cardAlert ?? "")
            }
        }
    }

    private func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !sending else { return }
        guard let host = activeHost, let myUid = manager.myUid else { return }
        draft = ""
        sendError = nil
        sending = true
        let client = ChatSessionClient(host: host, model: selectedModel, sessionId: sessionId, relayReceiverUid: myUid)
        Task {
            do {
                for try await event in client.stream(prompt: prompt) {
                    switch event {
                    case .started(let id, _):
                        sessionId = id
                    case .message:
                        thoughtLine = nil
                    case .thought(let text):
                        thoughtLine = String(text.prefix(220))
                    case .tool:
                        break
                    case .done(let stop, let id, _):
                        sessionId = id
                        sending = false
                        thoughtLine = nil
                        TurnNotifier.turnFinished(threadTitle: activeHost?.name ?? "Agent")
                        if stop != "endTurn" && stop != "cancelled" {
                            sendError = "Turn ended: \(stop)"
                        }
                    case .failed(let message):
                        sending = false
                        thoughtLine = nil
                        sendError = message
                    }
                }
                sending = false
            } catch {
                sending = false
                thoughtLine = nil
                sendError = error.localizedDescription
            }
        }
    }

    private func startVoice() {
        if !dictation.isRecording { draftBase = draft }
        dictation.toggle()
    }
}

/// UIKit-hosted agent thread (header + live message list, no kit composer).
struct AgentThreadView: UIViewControllerRepresentable {
    let agent: CometChatSDK.User

    func makeUIViewController(context: Context) -> AgentMessagesVC {
        AgentMessagesVC(agent: agent)
    }

    func updateUIViewController(_ controller: AgentMessagesVC, context: Context) {}
}

/// Native input bar: the send path the kit never sees.
struct ChatInputBar: View {
    @Binding var draft: String
    var sending: Bool
    var onSend: () -> Void
    var onVoice: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message the agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .disabled(sending)
                .onSubmit(onSend)
            Button(action: onVoice) {
                Image(systemName: "mic.fill")
            }
            .disabled(sending)
            .accessibilityLabel("Hold To Talk")
            Button(action: onSend) {
                if sending {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
            }
            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send Message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
}

struct ChatSetupCard: View {
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
