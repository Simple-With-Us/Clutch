import SwiftUI
import ExyteChat

extension ChatMessage {
    public var exyteMessage: ExyteChat.Message {
        let isUser = self.role == .user
        let user = isUser
            ? ExyteChat.User(id: "user", name: "You", avatarURL: nil, isCurrentUser: true)
            : ExyteChat.User(id: "assistant", name: modelUsed ?? "Clutch", avatarURL: nil, isCurrentUser: false)

        return ExyteChat.Message(
            id: self.id.uuidString,
            user: user,
            createdAt: self.timestamp,
            text: self.content
        )
    }
}

public struct ChatView: View {
    @State private var messages: [ChatMessage] = [
        ChatMessage(
            role: .assistant,
            content: "Ready for your coding task. How can I help you today?",
            modelUsed: "Clutch"
        )
    ]
    @State private var selectedModel: String = "DeepSeek-V4.1-Pro"
    @State private var isTranscribingVoice: Bool = false
    @State private var voiceStatusMessage: String?

    let activeHost: ClutchHost?
    let transcriptionService = TranscriptionService.shared

    public init(activeHost: ClutchHost? = nil) {
        self.activeHost = activeHost
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Model header strip
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

                if isTranscribingVoice {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(voiceStatusMessage ?? "Transcribing voice with Whisper…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1))
                }

                // ExyteChat View
                ExyteChat.ChatView(messages: messages.map(\.exyteMessage)) { draft in
                    handleDraft(draft)
                } messageBuilder: { params in
                    if let original = messages.first(where: { $0.id.uuidString == params.message.id }) {
                        ChatMessageCard(message: original)
                            .padding(.horizontal, 8)
                    } else {
                        EmptyView()
                    }
                }
                .audioRecordingMode(.holdToRecord)
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func handleDraft(_ draft: DraftMessage) {
        if let audioURL = draft.recording?.url {
            isTranscribingVoice = true
            voiceStatusMessage = "Transcribing voice via Whisper…"
            Task {
                do {
                    let transcribed = try await transcriptionService.transcribeAudio(
                        fileURL: audioURL,
                        hostURL: activeHost?.origin
                    )
                    await MainActor.run {
                        isTranscribingVoice = false
                        voiceStatusMessage = nil
                        submitUserPrompt(transcribed)
                    }
                } catch {
                    await MainActor.run {
                        isTranscribingVoice = false
                        voiceStatusMessage = "Transcription failed: \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submitUserPrompt(text)
    }

    private func submitUserPrompt(_ text: String) {
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)

        // Mock assistant streaming response
        let assistantMsgId = UUID()
        let assistantMsg = ChatMessage(
            id: assistantMsgId,
            role: .assistant,
            content: "I've received your request: \"\(text)\". Working on it using \(selectedModel)…",
            reasoningContent: "Analyzing project dependencies and checking tool registries…",
            modelUsed: selectedModel
        )
        messages.append(assistantMsg)
    }
}

struct ChatMessageCard: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.content)
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.1))
                                .frame(width: 18, height: 18)
                            Text("C")
                                .font(.system(size: 10, weight: .black))
                        }
                        Text(message.modelUsed ?? "Clutch")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                    }

                    if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                        ReasoningBlockView(reasoningText: reasoning, isStreaming: message.isStreaming)
                    }

                    ForEach(message.toolCalls) { toolCall in
                        ToolCallCard(toolCall: toolCall)
                    }

                    Text(message.content)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Spacer(minLength: 40)
            }
        }
    }
}
