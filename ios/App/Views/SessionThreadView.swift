import SwiftUI

/// One rendered turn in a native MiniMax Code thread.
struct ThreadBubbleItem: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    var id: String
    var role: Role
    var text: String
}

@MainActor
@Observable
final class SessionThreadModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private let host: ClutchHost
    private let client: SessionsClient
    private let session: AcpSessionInfo

    /// Sidecar chat id for the loaded thread; swapped on every send so the
    /// next turn continues the same conversation.
    private var chatId: String?
    private var cwd: String?
    /// The durable ACP id, which is what a reload resumes from.
    private var remoteSessionId: String

    var phase: Phase = .idle
    var bubbles: [ThreadBubbleItem] = []
    var draft = ""
    var isSending = false
    var thoughtLine: String?
    var sendError: String?

    init(host: ClutchHost, session: AcpSessionInfo) {
        self.host = host
        self.client = SessionsClient(host: host)
        self.session = session
        self.remoteSessionId = session.sessionId
        self.cwd = session.cwd
    }

    func load() async {
        guard phase == .idle || isFailed else { return }
        phase = .loading
        do {
            let loaded = try await client.load(sessionId: remoteSessionId, cwd: session.cwd)
            chatId = loaded.chatId
            // The sidecar does not echo cwd back, so keep the one we asked
            // for; a reload without it fails every thread outside $HOME.
            cwd = loaded.cwd
            remoteSessionId = loaded.remoteSessionId
            bubbles = loaded.history.filter(\.isVisible).map {
                ThreadBubbleItem(
                    id: "\($0.sessionId)-\($0.kind)-\($0.text.hashValue)",
                    role: $0.isUser ? .user : .assistant,
                    text: $0.text
                )
            }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending, phase == .ready else { return }
        draft = ""
        sendError = nil
        isSending = true
        thoughtLine = nil
        bubbles.append(ThreadBubbleItem(id: UUID().uuidString, role: .user, text: prompt))

        // relayReceiverUid is empty: an unpaired CometChat thread has no sink
        // to relay into, and the sidecar skips the mirror when it is blank.
        let client = ChatSessionClient(
            host: host,
            model: "mcode",
            sessionId: chatId,
            relayReceiverUid: "",
            engine: "mcode"
        )
        let replyId = UUID().uuidString
        var reply = ""
        Task {
            do {
                for try await event in client.stream(prompt: prompt) {
                    switch event {
                    case .started(let id, _):
                        chatId = id
                    case .message(let text):
                        thoughtLine = nil
                        reply += text
                        upsert(replyId, text: reply)
                    case .thought(let text):
                        thoughtLine = text
                    case .done(_, _, let remote):
                        if let remote { remoteSessionId = remote }
                    case .failed(let message):
                        sendError = message
                    }
                }
            } catch {
                sendError = error.localizedDescription
            }
            if !reply.isEmpty { upsert(replyId, text: reply) }
            thoughtLine = nil
            isSending = false
        }
    }

    /// Streaming rewrites the tail bubble on every event, so match on the id
    /// we minted for this turn instead of appending a new one each chunk.
    private func upsert(_ id: String, text: String) {
        if let index = bubbles.firstIndex(where: { $0.id == id }) {
            bubbles[index].text = text
        } else {
            bubbles.append(ThreadBubbleItem(id: id, role: .assistant, text: text))
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

public struct SessionThreadView: View {
    let session: AcpSessionInfo
    @State private var model: SessionThreadModel

    public init(host: ClutchHost, session: AcpSessionInfo) {
        self.session = session
        _model = State(initialValue: SessionThreadModel(host: host, session: session))
    }

    public var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .navigationTitle(session.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
    }

    @ViewBuilder
    private var transcript: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Open Session", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        case .ready:
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.bubbles) { bubble in
                            ThreadBubbleRow(bubble: bubble)
                                .id(bubble.id)
                        }
                        if let thought = model.thoughtLine, !thought.isEmpty {
                            Text(thought)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .id("thought")
                        }
                        if let error = model.sendError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 12)
                        }
                        // Sentinel to scroll to: the transcript grows during a
                        // stream, and ScrollViewProxy has no content size to
                        // measure against.
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .onChange(of: model.bubbles.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.thoughtLine) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ThreadBubbleRow: View {
    let bubble: ThreadBubbleItem

    var body: some View {
        HStack {
            if bubble.role == .user { Spacer(minLength: 40) }
            Text(bubble.text)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(bubble.role == .user ? Color.accentColor.opacity(0.18) : Color.clutchSecondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if bubble.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
