import SwiftUI
#if canImport(PhotosUI)
import PhotosUI
#endif

/// One rendered turn in a native MiniMax Code thread.
struct ThreadBubbleItem: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case tool
    }

    var id: String
    var role: Role
    var text: String
    /// Tool status (`running` / `completed` / `failed`) for `.tool` bubbles.
    var toolStatus: String? = nil
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
    /// Images attached to the next turn, the way the web canvas attaches
    /// files to a message.
    var attachments: [ChatAttachment] = []

    /// The engine this thread runs on (`mcode` for MiniMax Code, `muse` for
    /// Muse Code).  Set when the thread is opened, and what the catalog is
    /// filtered by.
    var engine: String = "mcode"
    /// The picked model, by the id the catalog published.
    var modelId: String?
    /// The picked reasoning effort, by the level the catalog published.
    var effort: String?
    /// The host's engine catalog, for the model and effort pickers.
    var catalog: EngineCatalog?

    private var sendTask: Task<Void, Never>?

    init(host: ClutchHost, session: AcpSessionInfo, engine: String = "mcode") {
        self.host = host
        self.client = SessionsClient(host: host)
        self.session = session
        self.engine = engine
        self.remoteSessionId = session.sessionId
        self.cwd = session.cwd
    }

    /// The engine's models, as the catalog published them.
    var models: [EngineModel] {
        catalog?.descriptor(engine)?.models ?? []
    }

    /// The engine's effort levels, as the catalog published them.
    var effortLevels: [String] {
        catalog?.descriptor(engine)?.effortLevels ?? []
    }

    /// What the model picker shows: the picked model, or the catalog's first
    /// row.  The first row is only shown — it is not sent with a turn, so an
    /// untouched thread keeps the model it was created with.
    var pickerLabel: String {
        if let modelId { return modelId }
        return models.first?.displayLabel ?? engineLabel
    }

    /// Load the catalog so the pickers can show what this host really
    /// offers.  A failure is not fatal: the thread still works, the pickers
    /// just stay empty.
    ///
    /// The catalog's first row is only the *default* the picker shows; it is
    /// not sent with a turn unless the owner picked it.  A resumed thread
    /// keeps the model and effort it was created with, and sending a
    /// default would silently switch it.
    func loadCatalog() async {
        guard catalog == nil else { return }
        catalog = try? await EngineCatalogClient(host: host).fetch()
    }

    func load() async {
        guard phase == .idle || isFailed else { return }
        await fetch()
    }

    /// Pull-to-refresh on the transcript, matching the Mac chat pane.  Forces a
    /// reload even when a thread is already open, so a turn that finished on
    /// the Mac shows up on the phone without leaving the thread.
    func reload() async {
        guard !isSending else { return }
        await fetch()
    }

    private func fetch() async {
        phase = .loading
        do {
            let loaded = try await client.load(sessionId: remoteSessionId, cwd: session.cwd, engine: engine)
            chatId = loaded.chatId
            // The sidecar does not echo cwd back, so keep the one we asked
            // for; a reload without it fails every thread outside $HOME.
            cwd = loaded.cwd
            remoteSessionId = loaded.remoteSessionId
            bubbles = loaded.history.compactMap { entry in
                if entry.isTool {
                    return ThreadBubbleItem(
                        id: "tool-\(entry.toolCallId ?? entry.text)-\(entry.text.hashValue)",
                        role: .tool,
                        text: entry.text,
                        toolStatus: entry.toolStatus ?? "completed"
                    )
                }
                guard entry.isVisible else { return nil }
                return ThreadBubbleItem(
                    id: "\(entry.sessionId)-\(entry.kind)-\(entry.text.hashValue)",
                    role: entry.isUser ? .user : .assistant,
                    text: entry.text
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
        // The model and the effort ride along only when the owner picked
        // them: an untouched thread keeps the ones it was created with.
        let client = ChatSessionClient(
            host: host,
            model: modelId ?? "",
            sessionId: chatId,
            relayReceiverUid: "",
            engine: engine,
            cwd: cwd,
            effort: effort,
            images: attachments
        )
        attachments = []
        let replyId = UUID().uuidString
        var reply = ""
        sendTask = Task {
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
                    case .tool(let id, let name, let status):
                        upsertTool(id: id, name: name, status: status)
                    case .done(_, _, let remote):
                        if let remote { remoteSessionId = remote }
                        TurnNotifier.turnFinished(threadTitle: session.displayTitle)
                    case .failed(let message):
                        sendError = message
                        TurnNotifier.turnFinished(threadTitle: session.displayTitle, failed: true)
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

    /// Stop the in-flight turn: cancel on the sidecar, then drop the local
    /// stream.  A partial reply already on screen stays — it is what the
    /// agent had said when the stop landed.
    func stop() {
        guard isSending else { return }
        if let chatId {
            let host = self.host
            Task { await ChatSessionClient.cancel(host: host, sessionId: chatId) }
        }
        sendTask?.cancel()
        sendTask = nil
        thoughtLine = nil
        isSending = false
    }

    /// Tool updates rewrite the card minted for that call, so a long-running
    /// tool shows one card moving running → completed, not a pile of rows.
    private func upsertTool(id: String, name: String, status: String) {
        let key = id.isEmpty ? "tool-\(name)" : "tool-\(id)"
        if let index = bubbles.firstIndex(where: { $0.id == key }) {
            bubbles[index].toolStatus = status
            if !name.isEmpty { bubbles[index].text = name }
        } else {
            bubbles.append(ThreadBubbleItem(id: key, role: .tool, text: name.isEmpty ? "Tool call" : name, toolStatus: status))
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

    /// The engine's owner-facing name, when the catalog has not loaded yet.
    var engineLabel: String {
        catalog?.descriptor(engine)?.label ?? (engine == "muse" ? "Muse Code" : "MiniMax Code")
    }
}

public struct SessionThreadView: View {
    let session: AcpSessionInfo
    @State private var model: SessionThreadModel
    @State private var showFind = DebugLaunch.showsFind
    @State private var findText = DebugLaunch.findText ?? ""
    @StateObject private var dictation = DictationController()
    @State private var draftBase = ""
    /// The photo the user picked for the next turn.
    @State private var pickedPhoto: PhotosPickerItem?

    public init(host: ClutchHost, session: AcpSessionInfo, engine: String = "mcode") {
        self.session = session
        _model = State(initialValue: SessionThreadModel(host: host, session: session, engine: engine))
    }

    public var body: some View {
        VStack(spacing: 0) {
            modelBar
            if showFind {
                findBar
                Divider()
            }
            transcript
            Divider()
            composer
        }
        .navigationTitle(session.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showFind.toggle()
                    if !showFind { findText = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel(showFind ? "Hide Find" : "Find In Thread")
                if !model.bubbles.isEmpty {
                    ShareLink(item: exportMarkdown) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share Transcript")
                }
            }
        }
        .task { await model.load() }
        .onChange(of: dictation.transcript) { _, text in
            guard dictation.isRecording || !text.isEmpty else { return }
            model.draft = draftBase + (draftBase.isEmpty || text.isEmpty ? "" : " ") + text
        }
    }

    /// The model and effort pickers, straight from the host's catalog.
    ///
    /// This is the web canvas's model picker, reduced to what a phone can
    /// show: the engine's own models and the effort levels it accepts, so
    /// a new provider model appears here without an app release.
    private var modelBar: some View {
        HStack(spacing: 8) {
            Menu {
                if model.models.isEmpty {
                    Text("No Models Advertised")
                } else {
                    ForEach(model.models) { entry in
                        Button {
                            model.modelId = entry.id
                        } label: {
                            if entry.id == model.modelId {
                                Label(entry.displayLabel, systemImage: "checkmark")
                            } else {
                                Text(entry.displayLabel)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                    // What the engine will run: the picked model, or the
                    // catalog's first row, which is only shown — an
                    // untouched thread keeps the model it was created with.
                    Text(model.pickerLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .disabled(model.models.isEmpty)

            if !model.effortLevels.isEmpty {
                Menu {
                    ForEach(model.effortLevels, id: \.self) { level in
                        Button {
                            model.effort = level
                        } label: {
                            if level == model.effort {
                                Label(level.capitalized, systemImage: "checkmark")
                            } else {
                                Text(level.capitalized)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.dots.needle.50percent")
                            .font(.system(size: 10))
                        Text((model.effort ?? "default").capitalized)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
            }

            Spacer(minLength: 0)

            if let note = model.catalog?.descriptor(model.engine)?.note {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(note)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.clutchSecondaryBackground.opacity(0.6))
        .task { await model.loadCatalog() }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find In Thread", text: $findText)
                .textFieldStyle(.plain)
            Text(matchLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showFind = false
                findText = ""
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

    private var matchingIDs: Set<String> {
        let needle = findText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return Set(model.bubbles.filter { $0.text.lowercased().contains(needle) }.map(\.id))
    }

    private var matchLabel: String {
        let needle = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return "" }
        let count = matchingIDs.count
        return count == 1 ? "1 match" : "\(count) matches"
    }

    private var exportMarkdown: String {
        let entries = model.bubbles.map { bubble in
            TranscriptExport.Entry(
                role: bubble.role == .user ? .user : bubble.role == .tool ? .tool : .assistant,
                text: bubble.text
            )
        }
        return TranscriptExport.markdown(title: session.displayTitle, cwd: session.cwd, entries: entries)
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
                            ThreadBubbleRow(bubble: bubble, isMatch: matchingIDs.contains(bubble.id))
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
                .refreshable { await model.reload() }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !model.attachments.isEmpty {
                attachmentStrip
            }
            HStack(alignment: .bottom, spacing: 8) {
            Button {
                if !dictation.isRecording { draftBase = model.draft }
                dictation.toggle()
            } label: {
                Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                    .font(.title3)
                    .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.isSending)
            .accessibilityLabel(dictation.isRecording ? "Stop Dictation" : "Dictate")
            PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "paperclip")
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
            }
            .disabled(model.isSending)
            .accessibilityLabel("Attach Image")
            TextField("Message", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
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
                .accessibilityLabel("Stop")
            } else {
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send Message")
            }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task { await loadAttachment(item) }
        }
    }

    /// The images waiting on the next turn, each removable.
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
            .padding(.horizontal, 12)
        }
    }

    /// Read a picked photo into an attachment.  A photo the engines cannot
    /// take (an unsupported type, or one over the size cap) is reported
    /// instead of failing silently at the send.
    private func loadAttachment(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            model.sendError = "Could not read that photo."
            return
        }
        guard let attachment = ChatAttachment.from(data: data, name: "attachment") else {
            model.sendError = Copy.gap(
                "That image type is not supported.",
                "Use PNG, JPEG, GIF, or WebP."
            )
            return
        }
        model.attachments.append(attachment)
    }
}

struct ThreadBubbleRow: View {
    let bubble: ThreadBubbleItem
    var isMatch: Bool = false

    var body: some View {
        if bubble.role == .tool {
            ThreadToolCard(name: bubble.text, status: bubble.toolStatus ?? "completed")
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isMatch ? Color.accentColor : Color.clear, lineWidth: 2)
                )
        } else {
            HStack {
                if bubble.role == .user { Spacer(minLength: 40) }
                Text(bubble.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(bubble.role == .user ? Color.accentColor.opacity(0.18) : Color.clutchSecondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isMatch ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                if bubble.role == .assistant { Spacer(minLength: 40) }
            }
        }
    }
}
