import SwiftUI
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

    /// The request on screen.
    private var pendingPermission: AcpPermissionRequest? { pendingPermissions.first }
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
                            // The permission card sits above the composer, so
                            // the question the engine is asking is answered
                            // where the turn is written.
                            if let request = pendingPermission {
                                PermissionCard(request: request) { optionId in
                                    answerPermission(optionId)
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                            }
                            ChatInputBar(
                                draft: $draft,
                                sending: sending,
                                isDictating: dictation.isRecording,
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
    private func answerPermission(_ optionId: String?) {
        guard let request = pendingPermissions.first, let host = activeHost, let sessionId else { return }
        Task {
            let answered = await ChatSessionClient.answerPermission(
                host: host,
                sessionId: sessionId,
                requestId: request.requestId,
                optionId: optionId
            )
            if answered {
                // The card only goes away once the answer is on its way, so a
                // failed answer can be tried again.
                pendingPermissions.removeFirst()
            } else {
                sendError = "The permission answer did not reach the engine."
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
            effort: requestEffort
        )
        Task {
            do {
                for try await event in client.stream(prompt: prompt) {
                    switch event {
                    case .capabilities:
                        break
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
                        // answer goes back, so it is held on screen.
                        pendingPermissions.append(request)
                    case .plan:
                        break // the plan panel belongs to the workspace
                    case .done(let stop, let id, _):
                        sessionId = id
                        sending = false
                        thoughtLine = nil
                        pendingPermissions.removeAll()
                        TurnNotifier.turnFinished(threadTitle: activeHost?.name ?? "Agent")
                        // The host ends a turn with its own name for it, and
                        // the bridge with ACP's, so both are a normal end.
                        if stop != "endTurn" && stop != "end_turn" && stop != "cancelled" {
                            sendError = "Turn ended: \(stop)"
                        }
                    case .usage:
                        break // live usage strip is Mac-only
                    case .contextControls:
                        break // compaction controls are shown on the Mac workspace
                    case .failed(let message):
                        sending = false
                        thoughtLine = nil
                        pendingPermissions.removeAll()
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
    var isDictating: Bool = false
    var onSend: () -> Void
    var onVoice: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message the agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .disabled(sending)
                .onSubmit(onSend)
            Button(action: onVoice) {
                Image(systemName: isDictating ? "mic.fill" : "mic")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(sending)
            .accessibilityLabel(isDictating ? "Stop Dictation" : "Dictate")
            Button(action: onSend) {
                if sending {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                }
            }
            .frame(minWidth: 44, minHeight: 44)
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
