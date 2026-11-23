import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import CometChatUIKitSwift
import CometChatSDK

/// The native Chat tab, now on CometChat: the agent thread renders in the
/// kit's message list (live via its socket), the native input bar owns the
/// send path so prompts travel to the Mac sidecar (`POST /clutch/v1/chat`)
/// instead of CometChat's cloud send, and the sidecar relays the turn back
/// into the thread.  The engine, model and effort strip and the
/// tap-to-dictate voice stay native.
///
/// The pickers come from the host's catalog (`GET /clutch/v1/engines`), so
/// a provider model shows up without an app release, and every turn names
/// the engine it runs on instead of letting the sidecar guess from the
/// model name.
///
/// The coding threads live in the Workspace tab, which covers every engine
/// the host runs.  This tab is the agent conversation, which is a different
/// kind of conversation rather than another engine.
public struct ChatView: View {
    /// The paired-host store, so the chat surface can switch hosts the way
    /// the web canvas does.  The Mac app uses it to reach a code server.
    let store: HostStore?
    @StateObject private var dictation = DictationController()
    @State private var draftBase = ""
    @State private var manager = CometChatManager.shared
    /// The host's engine catalog: which engines it runs, which models each
    /// one offers, and which effort levels it accepts.
    ///
    /// The chat reads it instead of shipping a model list, so a provider
    /// that ships a new model shows up without an app release — the same
    /// trick the thread surface and the Mac app use.
    @State private var catalog: EngineCatalog?
    /// The engine the turn runs on, by the id the catalog published.
    @State private var selectedEngine: String = "deepseek"
    /// The picked model, by the id the catalog published.
    @State private var selectedModel: String?
    /// The picked reasoning effort, by the level the catalog published.
    @State private var selectedEffort: String?
    /// Why the catalog could not be read, when it could not.
    @State private var catalogError: String?
    @State private var draft: String = ""
    /// Images attached to the next turn, the way the thread surface
    /// attaches files to a message.
    @State private var attachments: [ChatAttachment] = []
    @State private var sessionId: String?
    @State private var sending: Bool = false
    @State private var thoughtLine: String?
    @State private var sendError: String?
    /// The permission request the engine is waiting on, when it asked for
    /// one.  The engine is blocked until this is answered.
    /// The permission requests the engine is waiting on, oldest first.
    ///
    /// The engine asks one question at a time, but a second request can land
    /// before the first is answered, so the queue keeps the earlier one on
    /// screen instead of dropping it behind the newer card.
    @State private var pendingPermissions: [AcpPermissionRequest] = []
    /// How many answers did not reach the engine.
    ///
    /// The card offers the request again when this count moves, so a failed
    /// answer never leaves the card disabled for good.
    @State private var permissionAnswerFailures = 0
    /// How many answers were dropped because the request they named was no
    /// longer the one on screen.
    @State private var permissionStaleAnswers = 0

    /// The request on screen.
    private var pendingPermission: AcpPermissionRequest? { pendingPermissions.first }
    @State private var cardAlert: String?
    @State private var isTranscribingVoice: Bool = false
    @State private var voiceStatusMessage: String?
    /// The prompt held back while a turn runs, sent the moment it ends.
    ///
    /// The field never closes while a turn streams: text typed then either
    /// steers the running turn or queues for the next one, so supervising
    /// from the phone never means waiting idle.
    @State private var queuedPrompt: String?
    /// Whether the sidecar reported the running turn accepts steering.
    @State private var supportsSteering = false
    /// The in-flight turn's task, cancelled by the stop control.
    @State private var sendTask: Task<Void, Never>?
    /// Which turn owns the composer.  Every turn takes a new number, so a
    /// stream that is on its way out can tell that it no longer owns the
    /// state and leaves the newer turn alone.
    @State private var turnToken: Int = 0
    /// Bumped on turn end and on permission arrival, so haptics have a
    /// value to fire on.
    @State private var turnTick = 0
    @State private var permissionTick = 0
    @State private var isShowingHosts = false

    let activeHost: ClutchHost?
    let transcriptionService = TranscriptionService.shared

    public init(activeHost: ClutchHost? = nil, store: HostStore? = nil) {
        self.activeHost = activeHost
        self.store = store
    }

    public var body: some View {
        agentBody
    }

    private var agentBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The engine, model and effort strip, straight from the
                // host's catalog.
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        engineMenu
                        modelMenu
                        effortMenu

                        Spacer(minLength: 0)

                        if let host = activeHost {
                            HostSwitcher(host: host, store: store ?? HostStore.shared, compact: true)
                                .fixedSize()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    // What the host said about the engines, when it said
                    // something worth reading.
                    if !catalogMessages.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(catalogMessages.indices, id: \.self) { index in
                                Text(catalogMessages[index])
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    }
                }
                .background(Color(.systemBackground))

                Divider()

                if dictation.isRecording {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(Copy.gap("Listening…", "Tap the mic again to stop."))
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
                        Button("Try Again") {
                            if let host = activeHost {
                                Task { await manager.prepare(host: host) }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 24)
                        Button("Hosts And Settings") {
                            isShowingHosts = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 24)
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
                                    .foregroundStyle(ClutchColor.danger)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                            }
                            // The permission card sits above the composer, so
                            // the question the engine is asking is answered
                            // where the turn is written.
                            if let request = pendingPermission {
                                PermissionCard(
                                    request: request,
                                    queuedCount: max(pendingPermissions.count - 1, 0),
                                    canAnswer: sessionId != nil,
                                    answerFailures: permissionAnswerFailures,
                                    staleAnswers: permissionStaleAnswers
                                ) { answer in
                                    answerPermission(answer)
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                            }
                            if let queued = queuedPrompt {
                                queuedPromptPill(queued)
                            }
                            ChatInputBar(
                                draft: $draft,
                                sending: sending,
                                isDictating: dictation.isRecording,
                                onSend: { _ = send(draft) },
                                onStop: { stopTurn() },
                                onQueue: { queueDraft() },
                                onSteer: { steerDraft() },
                                canSteer: supportsSteering && sessionId != nil,
                                onVoice: { startVoice() },
                                attachments: $attachments,
                                onError: { sendError = $0 }
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
            .sheet(isPresented: $isShowingHosts) {
                HostsSheet(store: store ?? HostStore.shared)
            }
            // Haptics keyed on counters, not on state booleans, so the
            // feedback fires once per event rather than on every layout pass.
            .sensoryFeedback(.success, trigger: turnTick)
            .sensoryFeedback(.warning, trigger: permissionTick)
            .task(id: activeHost?.pairingKey) {
                guard let host = activeHost else { return }
                // A different host means a different catalog: the old one is
                // dropped so the pickers never show another machine's
                // engines, and the choices made for it go with it.
                catalog = nil
                catalogError = nil
                selectedModel = nil
                selectedEffort = nil
                // The catalog comes first: the strip is on screen while the
                // chat connects, and a failed read is worth saying early.
                await loadCatalog(for: selectedEngine)
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

    // MARK: - The catalog-driven pickers

    /// The engine picker: the engines this host can actually run.
    ///
    /// An engine the host reports as unavailable is never a choice, because
    /// a turn on it would fail at the provider.  It stays in the menu when
    /// the host says why it cannot run, so the owner learns what is
    /// missing instead of finding an engine quietly gone.
    private var engineMenu: some View {
        Menu {
            if pickableEngines.isEmpty {
                Text("No Engines Available")
            } else {
                ForEach(pickableEngines) { descriptor in
                    Button {
                        selectEngine(descriptor.id)
                    } label: {
                        if descriptor.id == selectedEngine {
                            Label(descriptor.label, systemImage: "checkmark")
                        } else {
                            Text(descriptor.label)
                        }
                    }
                }
            }
            if !unavailableEngines.isEmpty {
                Divider()
                ForEach(unavailableEngines) { descriptor in
                    Text("\(descriptor.label) — Unavailable")
                }
            }
        } label: {
            stripLabel(symbol: "cpu", text: engineLabel)
        }
        .accessibilityLabel("Engine: \(engineLabel)")
    }

    /// The model picker: the models the picked engine offers.
    private var modelMenu: some View {
        Menu {
            if engineModels.isEmpty {
                Text("No Models Advertised")
            } else {
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
            }
        } label: {
            stripLabel(symbol: "cpu", text: modelLabel)
        }
        .disabled(engineModels.isEmpty)
        .accessibilityLabel("Model: \(modelLabel)")
    }

    /// The effort picker, when the picked engine accepts effort levels.
    @ViewBuilder
    private var effortMenu: some View {
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
                stripLabel(symbol: "gauge.with.dots.needle.50percent", text: effortLabel)
            }
            .accessibilityLabel("Reasoning Effort: \(selectedEffort?.capitalized ?? "Default")")
        }
    }

    /// One picker in the header strip.
    private func stripLabel(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// The engines the owner can pick.
    ///
    /// A host that published no catalog still gets the built-in list, so
    /// the picker is never empty and the chat still works.
    private var pickableEngines: [EngineDescriptor] {
        if let catalog {
            return catalog.engines.filter { EngineIds.isKnown($0.id) && $0.available }
        }
        return EngineIds.all.map { fallbackDescriptor(for: $0) }
    }

    /// The engines that cannot run here, with the reason the host gave.
    ///
    /// They are listed, never offered: a turn on them would fail at the
    /// provider, and the note is what tells the owner what to fix.
    private var unavailableEngines: [EngineDescriptor] {
        guard let catalog else { return [] }
        return catalog.engines.filter {
            EngineIds.isKnown($0.id) && !$0.available && !($0.note ?? "").isEmpty
        }
    }

    /// The engine the app offers when the host has published no catalog.
    private func fallbackDescriptor(for engineId: String) -> EngineDescriptor {
        EngineDescriptor(
            id: engineId,
            label: EngineLabels.label(for: engineId),
            available: true,
            models: Self.builtInModels[engineId] ?? [],
            effortLevels: [],
            effortConfigId: "reasoning_effort",
            modelConfigId: "model"
        )
    }

    /// The models an engine offers, from the catalog or the built-in list.
    private func models(for engineId: String) -> [EngineModel] {
        if let catalog {
            return catalog.descriptor(engineId)?.models ?? []
        }
        return Self.builtInModels[engineId] ?? []
    }

    /// The models this chat offers when the host publishes no catalog.
    ///
    /// These are the models the sidecar ships for the dsh engines, so a
    /// turn still works before the catalog lands, or while it cannot be
    /// read.  The code engines advertise their models by probing the engine
    /// itself, so there is nothing to fall back to for them.
    ///
    /// The retired MiniMax-M2.7-highspeed is deliberately not here: the
    /// provider refuses it, so offering it would fail at the turn.
    private static let builtInModels: [String: [EngineModel]] = [
        "deepseek": [
            EngineModel(id: "DeepSeek-V4.1-Pro", label: "DeepSeek-V4.1-Pro", value: "DeepSeek-V4.1-Pro"),
            EngineModel(id: "DeepSeek-V4.1-Flash", label: "DeepSeek-V4.1-Flash", value: "DeepSeek-V4.1-Flash", images: true),
        ],
        "minimax": [
            EngineModel(id: "MiniMax-M3.1-Flash", label: "MiniMax-M3.1-Flash", value: "MiniMax-M3.1-Flash"),
            EngineModel(id: "MiniMax-M3", label: "MiniMax-M3", value: "MiniMax-M3"),
        ],
    ]

    /// The picked engine's entry in the catalog, when it has one.
    private var selectedDescriptor: EngineDescriptor? {
        catalog?.descriptor(selectedEngine)
    }

    /// The models the picked engine offers.
    ///
    /// A host that published no catalog falls back to the built-in models
    /// for the engine, so the picker still has something to send.
    private var engineModels: [EngineModel] {
        models(for: selectedEngine)
    }

    /// The effort levels the picked engine accepts.
    private var engineEfforts: [String] {
        selectedDescriptor?.effortLevels ?? []
    }

    /// The engine's owner-facing name.
    private var engineLabel: String {
        selectedDescriptor?.label ?? EngineLabels.label(for: selectedEngine)
    }

    /// What the model picker shows.
    private var modelLabel: String {
        if let picked = selectedModel,
           let entry = engineModels.first(where: { $0.id == picked }) {
            return entry.displayLabel
        }
        return engineModels.first?.displayLabel ?? "Default Model"
    }

    /// What the effort picker shows when the owner has not picked one.
    private var effortLabel: String {
        (selectedEffort ?? "default").capitalized
    }

    /// What the host said about the engines, when it said something.
    ///
    /// A catalog that could not be read is worth saying out loud: the chat
    /// still works, but on the choices the host published last, and the
    /// owner should know that is what is happening.
    private var catalogMessages: [String] {
        var messages: [String] = []
        if let catalogError {
            messages.append(catalog == nil
                ? Copy.gap("Couldn't Read The Engine List.", "Using The Built-In Models.")
                : Copy.gap("Couldn't Read The Engine List.", "Using The Last One."))
            messages.append(catalogError)
        }
        for descriptor in unavailableEngines {
            if let note = descriptor.note {
                messages.append("\(descriptor.label): \(note)")
            }
        }
        if let note = selectedDescriptor?.note {
            messages.append(note)
        }
        return messages
    }

    /// Read the host's catalog for the pickers.
    ///
    /// A failure is not fatal: the choices this host published last stay on
    /// screen, and the built-in models stand in when there never were any.
    /// The failure is reported in the view rather than hidden behind a
    /// picker that looks normal.
    private func loadCatalog(for engineId: String) async {
        guard let host = activeHost else { return }
        do {
            let loaded = try await EngineCatalogClient(host: host).fetch(engine: engineId)
            guard activeHost?.id == host.id else { return }
            catalog = loaded
            catalogError = nil
        } catch {
            guard activeHost?.id == host.id else { return }
            // The catalog this host published last stays on screen, so a
            // failed read does not empty the pickers.
            if catalog == nil {
                catalog = await EngineCatalogClient(host: host).lastKnownCatalog()
            }
            catalogError = error.localizedDescription
        }
        applyCatalogChoices()
    }

    /// Keep the picks inside what the host publishes.
    ///
    /// An engine this host cannot run is not a choice, so the picker moves
    /// to one that can, and a model or an effort the host does not offer is
    /// dropped rather than sent and refused.
    private func applyCatalogChoices() {
        if !pickableEngines.contains(where: { $0.id == selectedEngine }),
           let first = pickableEngines.first {
            selectedEngine = first.id
        }
        if let selectedModel, !engineModels.contains(where: { $0.id == selectedModel }) {
            self.selectedModel = nil
        }
        if selectedModel == nil {
            selectedModel = engineModels.first?.id
        }
        if let selectedEffort, !engineEfforts.contains(selectedEffort) {
            self.selectedEffort = nil
        }
    }

    /// Show another engine's models and effort levels.
    ///
    /// The model and the effort belong to the engine that was picked, so the
    /// new engine starts on its own first model.
    private func selectEngine(_ id: String) {
        guard id != selectedEngine else { return }
        selectedEngine = id
        selectedModel = nil
        selectedEffort = nil
        applyCatalogChoices()
        Task { await loadCatalog(for: id) }
    }

    /// The engine the request names.
    ///
    /// The sidecar refuses an engine it does not know, so the id is only
    /// sent when it is one Clutch runs.
    private var requestEngine: String? {
        EngineIds.isKnown(selectedEngine) ? selectedEngine : nil
    }

    /// The model the request names: the exact value the engine wants.
    private var requestModel: String {
        if let picked = selectedModel,
           let entry = engineModels.first(where: { $0.id == picked }) {
            return entry.value
        }
        return engineModels.first?.value ?? ""
    }

    /// The effort the request names, when the engine publishes levels and
    /// the owner picked one.
    private var requestEffort: String? {
        guard let selectedEffort, engineEfforts.contains(selectedEffort) else { return nil }
        return selectedEffort
    }

    /// Answer the permission request the engine is waiting on.
    ///
    /// The answer goes to the sidecar, which hands it to the engine.
    private func answerPermission(_ answer: AcpPermissionAnswer) {
        guard let request = pendingPermissions.first, let host = activeHost, let sessionId else { return }
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
                sessionId: sessionId,
                requestId: answer.requestId,
                optionId: answer.optionId
            )
            if answered {
                // The card only goes away once the answer is on its way, so a
                // failed answer can be tried again.
                pendingPermissions.removeFirst()
            } else {
                sendError = "The permission answer did not reach the engine."
                permissionAnswerFailures += 1
            }
        }
    }

    /// Sends one turn.
    ///
    /// The answer says whether the turn started.  A send that bails on the
    /// host or the connection has to hand its text back, because the
    /// parked follow-up would otherwise be gone.
    @discardableResult
    private func send(_ text: String) -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return false }
        if sending {
            // A prompt typed while a turn runs queues for the next one;
            // the composer never has to disable itself for a stream.
            queueDraft()
            return false
        }
        guard let host = activeHost else { return false }
        guard let myUid = manager.myUid else {
            sendError = "Chat is still connecting — try again in a moment."
            return false
        }
        draft = ""
        sendError = nil
        sending = true
        // The capabilities belong to the turn that reported them, so a new
        // turn starts without steering until the sidecar says otherwise.
        supportsSteering = false
        // The turn's images ride the request while the composer clears:
        // what comes back on a transport failure is restored below, so a
        // send that never left never eats its attachments.
        let outgoingImages = attachments
        let client = ChatSessionClient(
            host: host,
            model: requestModel,
            sessionId: sessionId,
            relayReceiverUid: myUid,
            // The engine always rides along: without it the sidecar routes
            // by model name, and a turn that names no known model would land
            // on DeepSeek.
            engine: requestEngine,
            // The effort rides along only when the engine publishes levels
            // and the owner picked one, so a turn keeps the engine's own
            // effort otherwise.
            effort: requestEffort,
            images: outgoingImages
        )
        attachments = []
        // This turn takes the composer.  A stream that is still on its way
        // out compares the number it was given with the current one and
        // leaves the newer turn's state alone.
        turnToken += 1
        let token = turnToken
        let task = Task {
            var endedNormally = false
            /// Whether the stream answered at all.  An event means the engine
            /// has the turn, so its prompt and its images must not be handed
            /// back a second time.
            var receivedEvent = false
            do {
                for try await event in client.stream(prompt: prompt) {
                    // A newer turn owns the composer now, so this stream's
                    // events are stale and must not touch it.
                    guard turnToken == token else { return }
                    receivedEvent = true
                    switch event {
                    case .capabilities(let steering):
                        supportsSteering = steering
                    case .started(let id, _):
                        sessionId = id
                    case .message:
                        thoughtLine = nil
                    case .thought(let text):
                        thoughtLine = String(text.prefix(220))
                    case .tool:
                        break
                    case .permission(let request):
                        // The engine is blocked on this request until the
                        // answer goes back, so it is held on screen and the
                        // owner is woken for it: a stalled approval is the
                        // one event a turn-end notification can never cover.
                        pendingPermissions.append(request)
                        permissionTick += 1
                        TurnNotifier.permissionRequest(threadTitle: activeHost?.name ?? "Agent")
                    case .plan:
                        break // the plan panel belongs to the workspace
                    case .done(let stop, let id, _):
                        sessionId = id
                        thoughtLine = nil
                        pendingPermissions.removeAll()
                        turnTick += 1
                        TurnNotifier.turnFinished(threadTitle: activeHost?.name ?? "Agent")
                        // The host ends a turn with its own name for it, and
                        // the bridge with ACP's, so both are a normal end.
                        // A turn the owner stopped is "cancelled": its queued
                        // text stays parked rather than firing.
                        if stop != "endTurn" && stop != "end_turn" && stop != "cancelled" {
                            sendError = "Turn ended: \(stop)"
                        } else if stop != "cancelled" {
                            endedNormally = true
                        }
                    case .usage:
                        break // live usage strip is Mac-only
                    case .contextControls:
                        break // compaction controls are shown on the Mac workspace
                    case .failed(let message):
                        thoughtLine = nil
                        pendingPermissions.removeAll()
                        sendError = message
                        ErrorReporting.turnFailed(engine: selectedEngine, message: message)
                    }
                }
                // The stream is closed, so the composer goes idle here
                // and not on the first .done event: a turn that is still
                // closing cannot be started a second time.
                guard turnToken == token else { return }
                sending = false
                sendTask = nil
                // A turn that finished on its own sends what the owner
                // typed ahead while it ran; a stopped or failed turn
                // leaves the queued text for the send button.
                if endedNormally, let queued = queuedPrompt, !queued.isEmpty {
                    queuedPrompt = nil
                    // The queue holds text: the attachments in the composer
                    // stay there for the next message instead of riding the
                    // parked text.
                    let carried = attachments
                    attachments = []
                    // The chained send clears the composer, so what the owner
                    // typed while the turn was closing goes back in after it.
                    let typeAhead = draft
                    let started = send(queued)
                    attachments = carried
                    if started {
                        restoreTypeAhead(typeAhead)
                    } else {
                        // The send never started, so the queued text goes
                        // back in front of the type-ahead that is still in
                        // the composer.
                        restoreToComposer(queued)
                    }
                } else {
                    restoreQueuedPrompt()
                }
            } catch is CancellationError {
                // A stop the owner asked for is not an error: the partial
                // reply stays and the composer simply goes back to idle.
                guard turnToken == token else { return }
                sending = false
                sendTask = nil
                thoughtLine = nil
                restoreQueuedPrompt()
            } catch {
                guard turnToken == token else { return }
                sending = false
                sendTask = nil
                thoughtLine = nil
                // A stopped turn is not a failure: the owner asked for it,
                // so the surface says nothing about it.
                let cancelled = Task.isCancelled
                if !cancelled {
                    sendError = error.localizedDescription
                    ErrorReporting.turnTransportFailed(engine: selectedEngine, error: error)
                }
                restoreQueuedPrompt()
                // A stream that failed before any event means the turn never
                // reached the engine, so its images and its prompt come
                // back.  A stream that failed after an event means the
                // engine already has them, and handing them back would ask
                // the owner to repeat a turn that already ran.
                if !cancelled, !receivedEvent {
                    attachments = outgoingImages + attachments
                    restoreToComposer(prompt)
                }
            }
        }
        // The task is assigned after it is built, so a turn that ends before
        // the assignment lands cannot leave a finished task in the state.
        sendTask = task
        return true
    }

    /// Cancels the running turn: the sidecar is told first so the engine
    /// stops work, then the local stream is dropped.
    private func stopTurn() {
        guard sending else { return }
        if let host = activeHost, let sessionId {
            let target = sessionId
            Task { await ChatSessionClient.cancel(host: host, sessionId: target) }
        }
        sendTask?.cancel()
        sendTask = nil
        thoughtLine = nil
        // This turn gives up the composer, so a stream that is still on its
        // way out cannot clear the state of the next one.
        turnToken += 1
        // A stopped turn cannot answer a question any more, so the card goes
        // with it rather than sitting there inviting an answer that lands
        // nowhere.
        pendingPermissions.removeAll()
        // The queued text is the owner's to send or edit, so it goes back to
        // the composer instead of waiting hidden for a later turn.
        restoreQueuedPrompt()
        supportsSteering = false
        isSendingStopFeedback()
        sending = false
    }

    /// Holds the draft for the next turn.
    private func queueDraft() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, sending else { return }
        draft = ""
        // A second prompt joins the first instead of replacing it: a queued
        // message that is silently dropped is a message the owner lost.
        if let queued = queuedPrompt, !queued.isEmpty {
            queuedPrompt = queued + "\n" + prompt
        } else {
            queuedPrompt = prompt
        }
    }

    /// Moves the queued text back into the composer.  A stopped or failed
    /// turn hands it over, because the send button sends the composer's
    /// text: queued text that stayed hidden in state would be sent by a
    /// later turn the owner never asked for.
    private func restoreQueuedPrompt() {
        guard let queued = queuedPrompt else { return }
        queuedPrompt = nil
        restoreToComposer(queued)
    }

    /// Puts text that has to survive back into the composer.
    ///
    /// The dictation observer rewrites the field from `draftBase` and the
    /// transcript on every transcript change, so text that has to outlive
    /// the next transcript update joins the base while dictation runs, and
    /// the field is rebuilt the way the observer would rebuild it.
    private func restoreToComposer(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if dictation.isRecording {
            draftBase = draftBase.isEmpty ? value : value + "\n\n" + draftBase
            let spoken = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            draft = draftBase + (draftBase.isEmpty || spoken.isEmpty ? "" : " ") + spoken
            return
        }
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = current.isEmpty ? value : value + "\n\n" + draft
    }

    /// Puts the owner's type-ahead back into the composer.
    ///
    /// While dictation records the field belongs to the observer, which
    /// rebuilds it from the base and the transcript: the type-ahead stays
    /// out of the base, because the live field already holds the dictated
    /// words and folding it in would repeat them.
    private func restoreTypeAhead(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if dictation.isRecording {
            draft = value
            return
        }
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = current.isEmpty ? value : value + "\n\n" + draft
    }

    /// Injects the draft into the running turn when the sidecar allows it.
    private func steerDraft() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, sending, supportsSteering, let host = activeHost, let sessionId else { return }
        draft = ""
        let target = sessionId
        Task {
            do {
                try await ChatSessionClient.steer(host: host, sessionId: target, text: prompt)
            } catch {
                if SteerFailure.failedBeforeSend(error) {
                    sendError = error.localizedDescription
                    // The steer never left, so the text it was going to carry
                    // goes back to the composer instead of being lost.
                    restoreSteerPrompt(prompt)
                } else {
                    // The sidecar may have injected the text, so the text
                    // stays out of the composer: putting it back would have
                    // the owner send the same correction twice.
                    sendError = "\(error.localizedDescription)\u{00A0} The steer outcome is unknown, so the text was not put back in the composer."
                }
            }
        }
    }

    /// Puts a failed steer's text back into the composer.
    ///
    /// While dictation records, the field belongs to the dictation
    /// observer, which rewrites it from the base and the transcript: the
    /// text goes back the way the observer would write it, instead of
    /// joining the base and repeating the dictated words.
    private func restoreSteerPrompt(_ prompt: String) {
        if dictation.isRecording {
            restoreTypeAhead(prompt)
        } else {
            restoreToComposer(prompt)
        }
    }

    private func isSendingStopFeedback() {
        // Stop is a deliberate destructive-feeling tap; a medium impact
        // marks it without a notification-grade buzz.
        turnTick += 1
    }

    /// The pill naming what is waiting for the running turn to end.
    @ViewBuilder
    private func queuedPromptPill(_ queued: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(queued)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                queuedPrompt = nil
                restoreToComposer(queued)
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
        .padding(.bottom, 4)
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

/// Native input bar: the send path the kit never sees.  While a turn runs
/// the field stays open — text goes out as a steer when the turn accepts
/// one, or queues for the next turn otherwise, and the send button becomes
/// the stop control.
struct ChatInputBar: View {
    @Binding var draft: String
    var sending: Bool
    var isDictating: Bool = false
    var onSend: () -> Void
    var onStop: () -> Void = {}
    var onQueue: () -> Void = {}
    var onSteer: () -> Void = {}
    var canSteer: Bool = false
    var onVoice: () -> Void
    /// Images attached to the next turn.
    @Binding var attachments: [ChatAttachment]
    /// Reports a paste, drop, or pick failure; nil clears a stale one.
    var onError: (String?) -> Void = { _ in }
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            if !attachments.isEmpty {
                attachmentStrip
            }
            HStack(spacing: 8) {
                // One attach control: photo, file, and paste share a sheet,
                // so the field keeps its width on a phone.
                Button {
                    showAttachMenu = true
                } label: {
                    Image(systemName: "paperclip")
                        .frame(minWidth: 32, minHeight: 44)
                }
                .accessibilityLabel("Attach Image Or File")
                TextField("Message the agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button(action: onVoice) {
                    Image(systemName: isDictating ? "mic.fill" : "mic")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(isDictating ? "Stop Dictation" : "Dictate")
                if sending {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(ClutchColor.danger)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Stop")
                    Button(action: canSteer ? onSteer : onQueue) {
                        Image(systemName: canSteer ? "paperplane.circle.fill" : "tray.and.arrow.down.circle.fill")
                            .font(.system(size: 22))
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(canSteer ? "Steer" : "Queue")
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send Message")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        // Drop takes providers and the paste button reads the clipboard;
        // no keyboard shortcut on the paste button, which would steal the
        // field's text pastes.  (The paste command is macOS-only.)
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
            if case .success(let urls) = result {
                let outcome = AttachmentPaste.outcomeForFileURLs(urls)
                Task { @MainActor in applyOutcome(outcome) }
            }
        }
        .confirmationDialog("Attach", isPresented: $showAttachMenu, titleVisibility: .hidden) {
            // The pickers open after the dialog dismisses: presenting
            // synchronously from the action can drop the second
            // presentation while the dismissal is still in flight.
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
    }

    /// The images waiting on the next turn, each removable.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.system(size: 10))
                        Text(attachment.displayName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
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
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
            }
        }
    }

    /// Take providers from a paste command or a drop.
    private func handlePasteProviders(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            applyOutcome(await AttachmentPaste.outcomeForProviders(providers))
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
            attachments.append(contentsOf: outcome.images)
        }
        for insert in outcome.textInserts {
            if draft.isEmpty {
                draft = insert
            } else {
                draft += "\n\n" + insert
            }
        }
        if !outcome.errors.isEmpty {
            onError(outcome.errors.joined(separator: " "))
        } else if !outcome.images.isEmpty || !outcome.textInserts.isEmpty {
            onError(nil)
        }
    }

    /// Read a picked photo into an attachment.
    private func loadAttachment(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run { onError("Could not read that photo.") }
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
