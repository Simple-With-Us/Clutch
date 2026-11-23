import SwiftUI
import UniformTypeIdentifiers
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
    /// The call this one ran under, when a tool ran other tools.
    var toolParentId: String? = nil
    /// The id of the call, for a `.tool` bubble.
    var toolCallId: String? = nil
    /// What the tool was asked to do, as the engine wrote it.
    var toolInput: String? = nil
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
    /// The engine's execution plan, as it last reported it.
    var plan: [AcpPlanEntry] = []
    /// Whether the sidecar reported the running turn accepts steering.
    var supportsSteering = false
    /// The prompt held back while a turn runs, sent the moment it ends.
    var queuedPrompt: String?
    /// How many history entries the sidecar replayed.  At the client's
    /// load cap this is also the "earlier history isn't loaded" flag.
    var historyCount = 0
    /// Bumped on turn end and on permission arrival, so haptics have a
    /// value to fire on.
    var turnTick = 0
    var permissionTick = 0
    /// The permission requests the engine is waiting on, oldest first.
    ///
    /// The engine asks one question at a time, but a second request can land
    /// before the first is answered.  The queue keeps the earlier one on
    /// screen instead of dropping it behind the newer card, where it would
    /// only be answered by the fallback timer.
    var pendingPermissions: [AcpPermissionRequest] = []
    /// How many answers did not reach the engine.
    ///
    /// The card offers the request again when this count moves, so a failed
    /// answer never leaves the card disabled for good.
    var permissionAnswerFailures = 0

    /// The request on screen.
    var pendingPermission: AcpPermissionRequest? { pendingPermissions.first }
    /// Whether an answer can travel: the sidecar chat id is what the
    /// answer rides on, and it exists only once the turn has started.
    var canAnswerPermissions: Bool { chatId != nil }
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

    /// What the model picker shows: the picked model, or the engine itself.
    /// Naming a model here would claim the thread runs it, and an untouched
    /// thread keeps whatever model it was created with — which the client
    /// does not know.
    var pickerLabel: String {
        if let modelId {
            return catalog?.model(engineId: engine, modelId: modelId)?.displayLabel ?? modelId
        }
        return engineLabel
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
        catalog = try? await EngineCatalogClient(host: host).fetch(engine: engine)
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
            bubbles = Self.bubbles(from: loaded.history)
            historyCount = loaded.history.count
            // The plan is a state, not a line of the transcript: the last
            // plan the thread carried is the one the engine last reported.
            // A reload that carries no plan keeps the one on screen: the
            // transcript is a tail slice, and a plan written before it
            // would otherwise vanish from under the owner.
            if let carried = loaded.history.last(where: { $0.isPlan })?.plan {
                plan = carried
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
        // The capabilities belong to the turn that reported them, so a new
        // turn starts without steering until the sidecar says otherwise.
        supportsSteering = false
        bubbles.append(ThreadBubbleItem(id: UUID().uuidString, role: .user, text: prompt))
        TurnActivity.shared.runStarted(hostId: host.id, sessionId: session.sessionId, title: session.displayTitle)

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
            museOptions: engine == "muse" ? MuseLaunchPreferences.options(for: host) : nil,
            contextPolicy: engine == "muse" ? MuseContextPreferences.policy(for: host) : nil,
            images: attachments
        )
        attachments = []
        let replyId = UUID().uuidString
        var reply = ""
        var didFinish = false
        sendTask = Task {
            do {
                for try await event in client.stream(prompt: prompt) {
                    switch event {
                    case .capabilities(let steering):
                        supportsSteering = steering
                    case .started(let id, _):
                        chatId = id
                    case .message(let text):
                        thoughtLine = nil
                        reply += text
                        upsert(replyId, text: reply)
                    case .thought(let text):
                        thoughtLine = text
                    case .tool(let call):
                        upsertTool(
                            id: call.id,
                            name: call.name,
                            status: call.status,
                            parentId: call.parentId,
                            input: call.input
                        )
                    case .permission(let request):
                        // The engine is blocked on this request until the
                        // answer goes back, so it is held on screen, put in
                        // the home list's "Needs You" section, and the owner
                        // is woken for it — a stalled approval is the one
                        // event a turn-end notification can never cover.
                        pendingPermissions.append(request)
                        permissionTick += 1
                        TurnActivity.shared.approvalArrived(hostId: host.id, sessionId: session.sessionId, title: session.displayTitle)
                        TurnNotifier.permissionRequest(threadTitle: session.displayTitle)
                    case .plan(let entries):
                        plan = entries
                    case .done(_, _, let remote):
                        if let remote { remoteSessionId = remote }
                        pendingPermissions.removeAll()
                        TurnActivity.shared.approvalResolved(hostId: host.id, sessionId: session.sessionId)
                        TurnActivity.shared.runEnded(hostId: host.id, sessionId: session.sessionId)
                        turnTick += 1
                        TurnNotifier.turnFinished(threadTitle: session.displayTitle)
                        didFinish = true
                    case .usage:
                        break // live usage strip is Mac-only
                    case .contextControls:
                        break // compaction controls are shown on the Mac workspace
                    case .failed(let message):
                        sendError = message
                        ErrorReporting.turnFailed(engine: engine, message: message)
                        pendingPermissions.removeAll()
                        TurnActivity.shared.approvalResolved(hostId: host.id, sessionId: session.sessionId)
                        TurnActivity.shared.runEnded(hostId: host.id, sessionId: session.sessionId)
                        turnTick += 1
                        TurnNotifier.turnFinished(threadTitle: session.displayTitle, failed: true)
                    }
                }
            } catch {
                // A stopped turn is not a failure: the owner asked for it,
                // so the surface says nothing about it.
                if !Task.isCancelled {
                    sendError = error.localizedDescription
                    ErrorReporting.turnTransportFailed(engine: engine, error: error)
                }
                TurnActivity.shared.runEnded(hostId: host.id, sessionId: session.sessionId)
                TurnActivity.shared.approvalResolved(hostId: host.id, sessionId: session.sessionId)
            }
            if !reply.isEmpty { upsert(replyId, text: reply) }
            thoughtLine = nil
            isSending = false
            // A prompt held back while the turn ran goes out now: the turn
            // has ended, so sending again is allowed and the queue cannot
            // chain inside the stream loop.
            if didFinish, let queued = queuedPrompt, phase == .ready {
                queuedPrompt = nil
                draft = queued
                send()
            }
        }
    }

    /// Holds the draft for the next turn while the current one streams.
    func queueDraft() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, isSending else { return }
        draft = ""
        // A second prompt joins the first instead of replacing it: a queued
        // message that is silently dropped is a message the owner lost.
        if let queued = queuedPrompt, !queued.isEmpty {
            queuedPrompt = queued + "\n" + prompt
        } else {
            queuedPrompt = prompt
        }
    }

    /// Injects the draft into the running turn when the sidecar allows it.
    func steerDraft() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, isSending, supportsSteering, let chatId else { return }
        draft = ""
        let target = chatId
        let owner = host
        Task {
            do {
                try await ChatSessionClient.steer(host: owner, sessionId: target, text: prompt)
            } catch {
                sendError = error.localizedDescription
            }
        }
    }

    /// Answer the permission request the engine is waiting on.
    ///
    /// The answer goes to the sidecar, which hands it to the engine.  The
    /// card is cleared either way: a request the sidecar could not answer
    /// is not one the engine will take an answer for later.
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
                // failed answer can be tried again instead of stranding the
                // engine on a question nobody can see any more.
                pendingPermissions.removeFirst()
                if pendingPermissions.isEmpty {
                    TurnActivity.shared.approvalResolved(hostId: host.id, sessionId: session.sessionId)
                }
            } else {
                sendError = "The permission answer did not reach the engine."
                permissionAnswerFailures += 1
            }
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
        // A stopped turn cannot answer a question any more, so the card goes
        // with it rather than sitting there inviting an answer that lands
        // nowhere.
        pendingPermissions.removeAll()
        // The prompt held for the stopped turn goes with it: it was written
        // for a turn that is not running, and the next turn must not carry
        // it out on its own.
        queuedPrompt = nil
        supportsSteering = false
        TurnActivity.shared.approvalResolved(hostId: host.id, sessionId: session.sessionId)
        TurnActivity.shared.runEnded(hostId: host.id, sessionId: session.sessionId)
        turnTick += 1
        isSending = false
    }

    /// Tool updates rewrite the card minted for that call, so a long-running
    /// tool shows one card moving running → completed, not a pile of rows.
    private func upsertTool(id: String, name: String, status: String, parentId: String?, input: String?) {
        let key = id.isEmpty ? "tool-\(name)" : "tool-\(id)"
        if let index = bubbles.firstIndex(where: { $0.id == key }) {
            bubbles[index].toolStatus = status
            if !name.isEmpty { bubbles[index].text = name }
            if let parentId { bubbles[index].toolParentId = parentId }
            if let input { bubbles[index].toolInput = input }
        } else {
            bubbles.append(ThreadBubbleItem(
                id: key,
                role: .tool,
                text: name.isEmpty ? "Tool call" : name,
                toolStatus: status,
                toolParentId: parentId,
                toolCallId: id.isEmpty ? nil : id,
                toolInput: input
            ))
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

    /// The parents map: which call each tool call ran under.
    ///
    /// Built once for the whole transcript, because a row is asked for its
    /// depth and a thread can carry hundreds of rows.
    var toolParents: [String: String] {
        var parents: [String: String] = [:]
        for bubble in bubbles where bubble.role == .tool {
            guard let id = bubble.toolCallId, let parent = bubble.toolParentId else { continue }
            parents[id] = parent
        }
        return parents
    }

    /// The transcript as bubbles, from a loaded history.
    ///
    /// A tool card keeps the call it ran under and what it was asked, so a
    /// reloaded thread shows the same tree the live turn did.
    static func bubbles(from history: [AcpHistoryEntry]) -> [ThreadBubbleItem] {
        history.compactMap { entry in
            if entry.isTool {
                return ThreadBubbleItem(
                    id: "tool-\(entry.toolCallId ?? entry.text)-\(entry.text.hashValue)",
                    role: .tool,
                    text: entry.text,
                    toolStatus: entry.toolStatus ?? "completed",
                    toolParentId: entry.parentToolCallId,
                    toolCallId: entry.toolCallId,
                    toolInput: entry.toolInput
                )
            }
            guard entry.isVisible else { return nil }
            return ThreadBubbleItem(
                id: "\(entry.sessionId)-\(entry.kind)-\(entry.text.hashValue)",
                role: entry.isUser ? .user : .assistant,
                text: entry.text
            )
        }
    }

    /// How deep one bubble's call sits under the call that made it.
    ///
    /// A tool that runs other tools is the parent of them, and the children
    /// hang under it, the way the web canvas shows them.
    func toolDepth(of bubble: ThreadBubbleItem, parents: [String: String]) -> Int {
        guard bubble.role == .tool else { return 0 }
        return ToolCallDepth.depth(of: bubble.toolCallId, parents: parents)
    }

    /// The engine's owner-facing name, when the catalog has not loaded yet.
    var engineLabel: String {
        catalog?.descriptor(engine)?.label ?? EngineLabels.label(for: engine)
    }
}

public struct SessionThreadView: View {
    private let host: ClutchHost
    private let engine: String
    let session: AcpSessionInfo
    @State private var model: SessionThreadModel
    @State private var showFind = DebugLaunch.showsFind
    @State private var findText = DebugLaunch.findText ?? ""
    /// Which match the find arrows are on, an index into `matchOrder`.
    @State private var findSelection = 0
    /// Whether the transcript should chase the stream.  It turns off the
    /// moment the user scrolls up to read, and the jump-to-latest pill
    /// turns it back on.
    @State private var followLatest = true
    @StateObject private var dictation = DictationController()
    @State private var draftBase = ""
    /// The photo the user picked for the next turn.
    @State private var pickedPhoto: PhotosPickerItem?
    /// The attach sheet: photo, file, or paste behind one control.
    @State private var showAttachMenu = false
    /// The photo library, opened from the attach sheet.
    @State private var showPhotoPicker = false
    /// The file picker for images and text files outside the photo library.
    @State private var showFilePicker = false
    /// Whether a drag is hovering the composer.
    @State private var isDropTargeted = false
    @State private var showMuseSignIn = false
    /// Whether the user asked for reduced motion.  The scroll to the latest
    /// turn is the one animation here, and it is skipped when it is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(host: ClutchHost, session: AcpSessionInfo, engine: String = "mcode") {
        self.host = host
        self.engine = engine
        self.session = session
        _model = State(initialValue: SessionThreadModel(host: host, session: session, engine: engine))
    }

    public var body: some View {
        VStack(spacing: 0) {
            modelBar
            // The plan is the cockpit's header, not a strip under the
            // transcript: "what is it doing now" is the first question a
            // supervisor asks, so it stays pinned above the reading pane.
            if !model.plan.isEmpty {
                PlanPanel(entries: model.plan)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
            }
            if showFind {
                findBar
                Divider()
            }
            transcript
            Divider()
            // The approval sits directly above the composer, so the question
            // the engine is asking is answered where the next turn is
            // written — and it can never scroll out of the conversation.
            if let request = model.pendingPermission {
                PermissionCard(
                    request: request,
                    queuedCount: max(model.pendingPermissions.count - 1, 0),
                    canAnswer: model.canAnswerPermissions,
                    answerFailures: model.permissionAnswerFailures
                ) { optionId in
                    model.answerPermission(optionId)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            if let queued = model.queuedPrompt {
                queuedPromptPill(queued)
            }
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
        .sheet(isPresented: $showMuseSignIn) {
            EngineSignInView(host: host) { Task { await model.load() } }
        }
        .onChange(of: dictation.transcript) { _, text in
            guard dictation.isRecording || !text.isEmpty else { return }
            model.draft = draftBase + (draftBase.isEmpty || text.isEmpty ? "" : " ") + text
        }
        // Haptics keyed on counters so each event lands once.
        .sensoryFeedback(.success, trigger: model.turnTick)
        .sensoryFeedback(.warning, trigger: model.permissionTick)
        .sensoryFeedback(.error, trigger: model.sendError)
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
                        .font(ClutchFont.micro)
                    // What the engine will run: the picked model, or the
                    // catalog's first row, which is only shown — an
                    // untouched thread keeps the model it was created with.
                    Text(model.pickerLabel)
                        .font(ClutchFont.captionStrong)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(ClutchFont.microStrong)
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
                            .font(ClutchFont.micro)
                        Text((model.effort ?? "default").capitalized)
                            .font(ClutchFont.captionStrong)
                        Image(systemName: "chevron.down")
                            .font(ClutchFont.microStrong)
                    }
                }
            }

            Spacer(minLength: 0)

            if let note = model.catalog?.descriptor(model.engine)?.note {
                Image(systemName: "info.circle")
                    .font(ClutchFont.footnote)
                    .foregroundStyle(.secondary)
                    .help(note)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.clutchSecondaryBackground.opacity(0.6))
        .task { await model.loadCatalog() }
    }

    /// The find bar with navigation: matches are counted in thread order and
    /// the arrows walk them, so "1 match" is a place, not a dead end.
    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find In Thread", text: $findText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if matchOrder.count > 0 {
                Button {
                    findSelection = (clampedSelection - 1 + matchOrder.count) % matchOrder.count
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous Match")
                Text("\(clampedSelection + 1) of \(matchOrder.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    findSelection = (clampedSelection + 1) % matchOrder.count
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next Match")
            } else {
                Text(matchLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        // A new search starts at the first match.
        .onChange(of: findText) { _, _ in
            findSelection = 0
        }
    }

    /// The match the arrows are on, kept inside the list.
    ///
    /// The transcript grows while the owner reads it, so a selection that
    /// was in range can fall outside it: the counter would then name a
    /// match that is not there.
    private var clampedSelection: Int {
        guard !matchOrder.isEmpty else { return 0 }
        return min(max(findSelection, 0), matchOrder.count - 1)
    }

    /// Matches in thread order, so the arrows can walk them.
    private var matchOrder: [String] {
        let needle = findText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return model.bubbles.filter { $0.text.lowercased().contains(needle) }.map(\.id)
    }

    private var matchLabel: String {
        let needle = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return "" }
        let count = matchOrder.count
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
                if engine == "muse", EngineAuthenticationAttempt.isRequired(message) {
                    Button("Sign In To Muse") { showMuseSignIn = true }
                }
                Button("Try Again") { Task { await model.load() } }
            }
        case .ready:
            let parents = model.toolParents
            let matched = Set(matchOrder)
            GeometryReader { outer in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            // A capped load used to look like a thread that
                            // simply began mid-sentence; say so instead.
                            if model.historyCount >= 200 {
                                Text(Copy.gap(
                                    "This thread has more history than the app loads.",
                                    "Showing the most recent \(model.historyCount) events."
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 2)
                            }
                            ForEach(model.bubbles) { bubble in
                                ThreadBubbleRow(
                                    bubble: bubble,
                                    isMatch: matched.contains(bubble.id),
                                    depth: model.toolDepth(of: bubble, parents: parents)
                                )
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
                                    .foregroundStyle(ClutchColor.danger)
                                    .padding(.horizontal, 12)
                                if engine == "muse", EngineAuthenticationAttempt.isRequired(error) {
                                    Button("Sign In To Muse") { showMuseSignIn = true }
                                }
                            }
                            // Sentinel to scroll to: the transcript grows during a
                            // stream, and ScrollViewProxy has no content size to
                            // measure against.
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                                .background(GeometryReader { sentinel in
                                    Color.clear.preference(
                                        key: TranscriptBottomVisibility.self,
                                        value: sentinel.frame(in: .named("threadScroll")).maxY
                                    )
                                })
                        }
                        // A readable line length on iPad: the bubbles cap
                        // where a book would, and centre as one column.
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                    }
                    .coordinateSpace(name: "threadScroll")
                    .onPreferenceChange(TranscriptBottomVisibility.self) { bottomY in
                        // The sentinel rides at the content's end: near the
                        // viewport's own height means the user is at the
                        // bottom; anything beyond means they scrolled up.
                        let atBottom = bottomY <= outer.size.height + 120
                        if atBottom != followLatest { followLatest = atBottom }
                    }
                    .onChange(of: model.bubbles.count) { _, _ in
                        guard followLatest else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: model.thoughtLine) { _, _ in
                        // Reasoning streams in many times a second; chasing
                        // it would yank the reader down the whole time.
                        guard followLatest else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: findSelection) { _, selection in
                        let order = matchOrder
                        guard order.indices.contains(selection) else { return }
                        proxy.scrollTo(order[selection], anchor: .center)
                    }
                    .refreshable { await model.reload() }
                    .overlay(alignment: .bottomTrailing) {
                        if !followLatest {
                            Button {
                                followLatest = true
                                withAnimation(reduceMotion ? nil : ClutchMotion.quick) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            } label: {
                                Label("Latest", systemImage: "arrow.down")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.thinMaterial, in: Capsule())
                            }
                            .padding(12)
                            .accessibilityLabel("Jump To Latest")
                        }
                    }
                }
            }
        }
    }

    /// The composer dock.  The field closes only when the thread itself is
    /// unusable (failed or still loading) — never while a turn runs, where
    /// text steers or queues instead.
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
                    .foregroundStyle(dictation.isRecording ? ClutchColor.danger : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!composerEnabled)
            .clutchTapTarget()
            .accessibilityLabel(dictation.isRecording ? "Stop Dictation" : "Dictate")
            // One attach control: photo, file, and paste share a sheet, so
            // the field keeps its width on a phone.
            Button {
                showAttachMenu = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
            }
            .disabled(!composerEnabled)
            .clutchTapTarget()
            .accessibilityLabel("Attach Image Or File")
            TextField("Message", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.clutchSecondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(!composerEnabled)
            if model.isSending {
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(ClutchColor.danger)
                }
                .frame(minWidth: ClutchMetric.minTapTarget, minHeight: ClutchMetric.minTapTarget)
                .accessibilityLabel("Stop")
                Button {
                    if model.supportsSteering { model.steerDraft() } else { model.queueDraft() }
                } label: {
                    Image(systemName: model.supportsSteering ? "paperplane.circle.fill" : "tray.and.arrow.down.circle.fill")
                        .font(.title2)
                }
                .frame(minWidth: ClutchMetric.minTapTarget, minHeight: ClutchMetric.minTapTarget)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(model.supportsSteering ? "Steer" : "Queue")
            } else {
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .frame(minWidth: ClutchMetric.minTapTarget, minHeight: ClutchMetric.minTapTarget)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send Message")
            }
            }
            if !composerEnabled, !composerEnabledMessage.isEmpty {
                Text(composerEnabledMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Paste and drop take the same providers: files keep their names,
        // image data becomes attachments, text files inline into the draft.
        // No keyboard shortcut on the paste button: it would steal text
        // pastes from the field, while the paste command only fires for
        // the image and file types the field ignores.  The paste command
        // is macOS-only; on iOS the paste button reads the clipboard.
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
                    .padding(.horizontal, 8)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            // Any file is pickable; what Clutch cannot use is refused out
            // loud by the dispatcher rather than greyed out here.
            if case .success(let urls) = result {
                let outcome = AttachmentPaste.outcomeForFileURLs(urls)
                Task { @MainActor in applyOutcome(outcome) }
            }
        }
        .confirmationDialog("Attach", isPresented: $showAttachMenu, titleVisibility: .hidden) {
            Button("Choose Photo") { showPhotoPicker = true }
            Button("Choose File") { showFilePicker = true }
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
    }

    /// Whether the composer can send at all: a failed or unloaded thread
    /// has nowhere to send to, and the dock says so instead of swallowing
    /// the tap the way the send guard used to.
    private var composerEnabled: Bool {
        model.phase == .ready
    }

    private var composerEnabledMessage: String {
        switch model.phase {
        case .failed:
            return "Reopen this thread to continue — the last load failed."
        case .idle, .loading:
            return "Opening the thread…"
        case .ready:
            return ""
        }
    }

    /// The pill naming what is waiting for the running turn to end.
    @ViewBuilder
    private func queuedPromptPill(_ queued: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(ClutchFont.footnote)
                .foregroundStyle(.secondary)
            Text(queued)
                .font(ClutchFont.caption)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                model.queuedPrompt = nil
                model.draft = queued
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard Queued Message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.clutchSecondaryBackground, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
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

    /// Fold a paste, drop, or pick into the composer: images join the next
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
            model.sendError = outcome.errors.joined(separator: " ")
        } else if !outcome.images.isEmpty || !outcome.textInserts.isEmpty {
            model.sendError = nil
        }
    }

    /// The images waiting on the next turn, each removable.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(ClutchFont.micro)
                        Text(attachment.displayName)
                            .font(ClutchFont.footnote)
                            .lineLimit(1)
                        Button {
                            model.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(ClutchFont.footnote)
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
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
        switch AttachmentPaste.fate(data: data, name: "attachment.\(ext)") {
        case .image(let attachment):
            model.attachments.append(attachment)
        case .text(let insert):
            if model.draft.isEmpty {
                model.draft = insert
            } else {
                model.draft += "\n\n" + insert
            }
        case .rejected(let message):
            model.sendError = message
        }
    }
}

/// The sentinel's distance from the viewport top, reported so the
/// transcript can tell "user is at the bottom" from "user scrolled up"
/// without polling scroll offsets.
struct TranscriptBottomVisibility: PreferenceKey {
    static var defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

struct ThreadBubbleRow: View {
    let bubble: ThreadBubbleItem
    var isMatch: Bool = false
    /// How deep the call sits under the call that made it.
    var depth: Int = 0

    var body: some View {
        if bubble.role == .tool {
            ThreadToolCard(
                name: bubble.text,
                status: bubble.toolStatus ?? "completed",
                depth: depth,
                input: bubble.toolInput
            )
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
            // VoiceOver needs to know who is speaking: the role was only
            // ever a background colour, which reads as nothing.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(bubble.role == .user ? "You said: \(bubble.text)" : "Agent said: \(bubble.text)")
        }
    }
}
