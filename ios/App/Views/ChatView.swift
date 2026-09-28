import SwiftUI

public struct ChatView: View {
    @State private var apiClient = HarnessAPIClient.shared
    @State private var connectionManager = HostConnectionManager.shared
    
    @State private var promptText: String = ""
    @State private var selectedModel: ModelItem = ModelItem.defaultModel
    @State private var reasoningEffort: ReasoningEffort = .medium
    @State private var isShowingHostManager: Bool = false
    
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
                
                // Messages list
                if let session = apiClient.currentSession {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(session.messages) { message in
                                    ChatMessageRow(message: message)
                                        .id(message.id)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                        }
                        .onChange(of: session.messages.count) {
                            if let lastId = session.messages.last?.id {
                                withAnimation {
                                    proxy.scrollTo(lastId, anchor: .bottom)
                                }
                            }
                        }
                    }
                } else {
                    EmptyChatStateView()
                }
                
                Divider()
                
                // Composer
                ComposerView(
                    prompt: $promptText,
                    selectedModel: $selectedModel,
                    reasoningEffort: $reasoningEffort,
                    isGenerating: apiClient.isGenerating,
                    onSend: sendMessage
                )
            }
            .navigationTitle(apiClient.currentSession?.title ?? "Harness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        isShowingHostManager = true
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: connectionManager.activeHost?.status.icon ?? "laptopcomputer")
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
    
    private func sendMessage() {
        guard let session = apiClient.currentSession else { return }
        let text = promptText
        promptText = ""
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
                        
                        Text("HARNESS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text(timeString(message.timestamp))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    
                    // Reasoning block
                    if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                        ReasoningBlockView(
                            reasoningText: reasoning,
                            isStreaming: message.isStreaming && message.content.isEmpty
                        )
                    }
                    
                    // Tool calls
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
                // Code block
                let lines = part.components(separatedBy: "\n")
                let lang = lines.first?.trimmingCharacters(in: .whitespaces)
                let codeLines = lines.dropFirst().joined(separator: "\n")
                blocks.append(TextBlock(text: codeLines.isEmpty ? part : codeLines, isCode: true, lang: lang))
            } else {
                // Text block
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    blocks.append(TextBlock(text: trimmed, isCode: false, lang: nil))
                }
            }
        }
        return blocks.isEmpty ? [TextBlock(text: raw, isCode: false, lang: nil)] : blocks
    }
}

struct HostWarningBanner: View {
    let host: HostConnection
    let onConfigure: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text("Host \(host.name) is \(host.status.rawValue.lowercased()).")
                .font(.system(size: 13, weight: .medium))
            
            Spacer()
            
            Button("Switch Host", action: onConfigure)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

struct EmptyChatStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 64, height: 64)
                
                Text("H")
                    .font(.system(size: 32, weight: .black))
                    .foregroundColor(.accentColor)
            }
            
            Text("Into the Unknown")
                .font(.system(size: 20, weight: .bold))
            
            Text("Start a conversation with your paired Harness instance.&nbsp; Full support for MiniMax, DeepSeek, Composio tools, and Fleet RAG.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Spacer()
        }
    }
}
