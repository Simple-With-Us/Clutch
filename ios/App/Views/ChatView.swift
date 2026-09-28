import SwiftUI
import ExyteChat

extension ChatMessage {
    public var exyteMessage: ExyteChat.Message {
        let isUser = self.role == .user
        let user = isUser
            ? ExyteChat.User(id: "user", name: "You", avatarURL: nil, isCurrentUser: true)
            : ExyteChat.User(id: "assistant", name: modelUsed ?? "Harness", avatarURL: nil, isCurrentUser: false)

        return ExyteChat.Message(
            id: self.id.uuidString,
            user: user,
            createdAt: self.timestamp,
            text: self.content
        )
    }
}

public struct ChatView: View {
    @State private var apiClient = HarnessAPIClient.shared
    @State private var connectionManager = HostConnectionManager.shared
    @State private var transcriptionService = TranscriptionService.shared

    @State private var selectedModel: ModelItem = ModelItem.defaultModel
    @State private var reasoningEffort: ReasoningEffort = .medium
    @State private var isShowingHostManager: Bool = false
    @State private var isTranscribingVoice: Bool = false
    @State private var voiceStatusMessage: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Host status banner if offline
                if let host = connectionManager.activeHost, host.status != .online {
                    HostWarningBanner(host: host) {
                        isShowingHostManager = true
                    }
                }

                // Active Model & Reasoning Effort Strip
                ModelSelectionStrip(
                    selectedModel: $selectedModel,
                    reasoningEffort: $reasoningEffort,
                    activeHost: connectionManager.activeHost
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))

                Divider()

                // Voice transcription banner if active
                if isTranscribingVoice {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(voiceStatusMessage ?? "Transcribing voice with Whisper…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.1))
                }

                // ExyteChat View
                if let session = apiClient.currentSession {
                    ExyteChat.ChatView(messages: session.messages.map(\.exyteMessage)) { draft in
                        handleDraftSubmission(draft: draft, in: session)
                    } messageBuilder: { params in
                        if let original = session.messages.first(where: { $0.id.uuidString == params.message.id }) {
                            ChatMessageRow(message: original)
                                .padding(.horizontal, 10)
                        } else {
                            EmptyView()
                        }
                    }
                    .audioRecordingMode(.holdToRecord)
                } else {
                    EmptyChatStateView()
                }
            }
            .navigationTitle(apiClient.currentSession?.title ?? "Harness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        isShowingHostManager = true
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: connectionManager.activeHost?.hostKind.icon ?? "cpu.fill")
                                .font(.system(size: 12))
                                .foregroundColor(connectionManager.activeHost?.status == .online ? .green : .orange)
                            Text(connectionManager.activeHost?.name ?? "No Host")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        _ = apiClient.createSession(model: selectedModel, reasoningEffort: reasoningEffort)
                    }) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .medium))
                    }
                }
            }
            .sheet(isPresented: $isShowingHostManager) {
                HostManagerSheet()
            }
        }
    }

    private func handleDraftSubmission(draft: DraftMessage, in session: Session) {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle voice recording if present
        if let audioURL = draft.recording?.url {
            isTranscribingVoice = true
            voiceStatusMessage = "Transcribing voice via \(transcriptionService.mode == .cloudOnly ? "OpenRouter" : "Whisper")…"

            Task {
                do {
                    let transcribed = try await transcriptionService.transcribeAudio(
                        fileURL: audioURL,
                        host: connectionManager.activeHost
                    )
                    await MainActor.run {
                        isTranscribingVoice = false
                        voiceStatusMessage = nil
                    }

                    let combined = text.isEmpty ? transcribed : "\(text)\n\n\(transcribed)"
                    if !combined.isEmpty {
                        await apiClient.sendMessage(
                            combined,
                            in: session,
                            model: selectedModel,
                            effort: reasoningEffort
                        )
                    }
                } catch {
                    await MainActor.run {
                        isTranscribingVoice = false
                        voiceStatusMessage = nil
                    }

                    let errPrompt = text.isEmpty ? "[Voice transcription failed: \(error.localizedDescription)]" : "\(text)\n\n[Voice transcription failed: \(error.localizedDescription)]"
                    await apiClient.sendMessage(
                        errPrompt,
                        in: session,
                        model: selectedModel,
                        effort: reasoningEffort
                    )
                }
            }
        } else if !text.isEmpty {
            Task {
                await apiClient.sendMessage(
                    text,
                    in: session,
                    model: selectedModel,
                    effort: reasoningEffort
                )
            }
        }
    }
}

struct ModelSelectionStrip: View {
    @Binding var selectedModel: ModelItem
    @Binding var reasoningEffort: ReasoningEffort
    let activeHost: HostConnection?

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(ModelItem.supportedModels) { model in
                    Button(action: {
                        selectedModel = model
                    }) {
                        HStack {
                            Text(model.displayName)
                            if selectedModel.id == model.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: selectedModel.vendor.iconName)
                        .font(.system(size: 11))
                        .foregroundColor(selectedModel.vendor == .miniMax ? .purple : .blue)
                    Text(selectedModel.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Menu {
                ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                    Button(action: {
                        reasoningEffort = effort
                    }) {
                        HStack {
                            Text(effort.rawValue.capitalized)
                            if reasoningEffort == effort {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                        .foregroundColor(.purple)
                    Text(reasoningEffort.rawValue.capitalized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            if let host = activeHost {
                HStack(spacing: 4) {
                    Circle()
                        .fill(host.status == .online ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(host.hostKind == .miniMaxCompanion ? "MiniMax" : "DeepSeek")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(.systemBackground))
                .clipShape(Capsule())
            }
        }
    }
}

struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 40)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.content.replacingOccurrences(of: "&nbsp;", with: "  "))
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    Text(timeString(message.timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.trailing, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    // Assistant header with H monogram
                    HStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.1))
                                .frame(width: 20, height: 20)
                            Text("H")
                                .font(.system(size: 11, weight: .black))
                        }

                        Text(message.modelUsed ?? "HARNESS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)

                        Spacer()

                        Text(timeString(message.timestamp))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    // Reasoning block (Tree-of-thought traces)
                    if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                        ReasoningBlockView(
                            reasoningText: reasoning,
                            isStreaming: message.isStreaming && message.content.isEmpty
                        )
                    }

                    // Tool calls (MCP, Composio, Computer Use)
                    ForEach(message.toolCalls) { toolCall in
                        ToolCallCard(toolCall: toolCall)
                    }

                    // Message content
                    if !message.content.isEmpty {
                        FormattedContentRenderer(content: message.content)
                    } else if message.isStreaming && message.toolCalls.isEmpty {
                        HStack(spacing: 4) {
                            Text("Generating response")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                Spacer(minLength: 40)
            }
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct FormattedContentRenderer: View {
    let content: String

    var body: some View {
        let blocks = parseBlocks(content)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<blocks.count, id: \.self) { index in
                let block = blocks[index]
                if block.isCode {
                    CodeBlockView(code: block.text, language: block.lang)
                } else {
                    Text(block.text.replacingOccurrences(of: "&nbsp;", with: "  "))
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private struct TextBlock {
        let text: String
        let isCode: Bool
        let lang: String?
    }

    private func parseBlocks(_ raw: String) -> [TextBlock] {
        var blocks: [TextBlock] = []
        let parts = raw.components(separatedBy: "```")

        for (idx, part) in parts.enumerated() {
            if idx % 2 == 1 {
                let lines = part.components(separatedBy: "\n")
                let lang = lines.first?.trimmingCharacters(in: .whitespaces)
                let codeLines = lines.dropFirst().joined(separator: "\n")
                blocks.append(TextBlock(text: codeLines.isEmpty ? part : codeLines, isCode: true, lang: lang))
            } else {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    blocks.append(TextBlock(text: trimmed, isCode: false, lang: nil))
                }
            }
        }
        return blocks
    }
}

struct HostWarningBanner: View {
    let host: HostConnection
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Host is \(host.status.rawValue)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Tap to configure or reconnect to \(host.name)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
        }
        .buttonStyle(.plain)
    }
}

struct EmptyChatStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
            }

            Text("Ready to Code with Harness")
                .font(.system(size: 18, weight: .bold))

            Text("Hold the microphone button to dictate directives, or type below.  Seamlessly connects to DeepSeek and MiniMax on your Mac or cloud server.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
    }
}
