import Foundation
import SwiftUI
import Observation

@Observable
public final class HarnessAPIClient {
    public static let shared = HarnessAPIClient()
    
    public var sessions: [Session] = []
    public var currentSession: Session?
    public var isGenerating: Bool = false
    public var workspaces: [WorkspaceItem] = WorkspaceItem.defaults
    public var activeWorkspace: WorkspaceItem?
    
    private let sessionsKey = "com.simplewithus.harness.saved_sessions"
    
    public init() {
        loadSessions()
        self.activeWorkspace = workspaces.first
    }
    
    public func loadSessions() {
        if let data = UserDefaults.standard.data(forKey: sessionsKey),
           let decoded = try? JSONDecoder().decode([Session].self, from: data),
           !decoded.isEmpty {
            self.sessions = decoded
            self.currentSession = decoded.first
        } else {
            createInitialSession()
        }
    }
    
    public func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: sessionsKey)
        }
    }
    
    private func createInitialSession() {
        let initial = Session(
            title: "Welcome to Harness",
            workspacePath: "~/Code/Harness",
            model: "MiniMax-M3",
            vendor: .miniMax,
            reasoningEffort: .medium,
            messages: [
                ChatMessage(
                    role: .assistant,
                    content: "Welcome to Harness companion!&nbsp; Connected to your host with full tool orchestration, Composio, and Fleet RAG integration.&nbsp; How can I assist with your code today?",
                    reasoningContent: "System initialized with active profile [mmh-web].&nbsp; Connected endpoints and tool catalogs ready.&nbsp; Waiting for workspace directives."
                )
            ]
        )
        self.sessions = [initial]
        self.currentSession = initial
        saveSessions()
    }
    
    public func createSession(
        title: String = "New Session",
        workspacePath: String? = nil,
        model: ModelItem = ModelItem.defaultModel,
        reasoningEffort: ReasoningEffort = .medium
    ) -> Session {
        let newSession = Session(
            title: title,
            workspacePath: workspacePath ?? activeWorkspace?.path,
            model: model.displayName,
            vendor: model.vendor,
            reasoningEffort: reasoningEffort,
            createdAt: Date(),
            updatedAt: Date(),
            messages: [],
            hostId: HostConnectionManager.shared.activeHost?.id
        )
        sessions.insert(newSession, at: 0)
        currentSession = newSession
        saveSessions()
        return newSession
    }
    
    public func selectSession(_ session: Session) {
        currentSession = session
    }
    
    public func deleteSession(_ session: Session) {
        sessions.removeAll(where: { $0.id == session.id })
        if currentSession?.id == session.id {
            currentSession = sessions.first
        }
        saveSessions()
    }
    
    public func sendMessage(
        _ prompt: String,
        in session: Session,
        model: ModelItem,
        effort: ReasoningEffort,
        attachedImages: [Data] = []
    ) async {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        let userMessage = ChatMessage(
            role: .user,
            content: prompt,
            timestamp: Date()
        )
        
        await MainActor.run {
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx].messages.append(userMessage)
                sessions[idx].updatedAt = Date()
                if sessions[idx].messages.count == 1 {
                    sessions[idx].title = String(prompt.prefix(32))
                }
                currentSession = sessions[idx]
                isGenerating = true
            }
        }
        
        // Assistant placeholder
        var assistantMsg = ChatMessage(
            role: .assistant,
            content: "",
            reasoningContent: model.supportsReasoning && effort != .off ? "" : nil,
            isReasoningExpanded: true,
            isStreaming: true
        )
        
        await MainActor.run {
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx].messages.append(assistantMsg)
                currentSession = sessions[idx]
            }
        }
        
        // Execute against host or simulated streaming
        await streamResponse(
            prompt: prompt,
            model: model,
            effort: effort,
            sessionId: session.id
        )
    }
    
    private func streamResponse(
        prompt: String,
        model: ModelItem,
        effort: ReasoningEffort,
        sessionId: String
    ) async {
        let isReasoning = model.supportsReasoning && effort != .off
        let activeHost = HostConnectionManager.shared.activeHost
        
        // Check if we should synthesize tools
        let lower = prompt.lowercased()
        let triggersComposio = lower.contains("slack") || lower.contains("github") || lower.contains("linear") || lower.contains("issue")
        let triggersRecall = lower.contains("recall") || lower.contains("memory") || lower.contains("rag") || lower.contains("lesson")
        
        var toolCalls: [ToolCall] = []
        if triggersComposio {
            toolCalls.append(
                ToolCall(
                    name: "composio_github",
                    argumentsJson: "{\"action\": \"search_issues\", \"query\": \"repo:jaywedgeworth22/Harness state:open\"}",
                    output: "Found 2 open issues: #30 [AG] Harness iOS companion app; #19 Public overview accuracy",
                    status: .completed,
                    durationMs: 340
                )
            )
        } else if triggersRecall {
            toolCalls.append(
                ToolCall(
                    name: "recall_search",
                    argumentsJson: "{\"query\": \"\(prompt)\", \"app\": \"harness\"}",
                    output: "Matched 3 items from fleet memory (score: 0.992).&nbsp; Inter-agent protocol and brand header guidelines active.",
                    status: .completed,
                    durationMs: 280
                )
            )
        }
        
        // Step 1: Thinking / Reasoning phase if reasoning is enabled
        if isReasoning {
            let reasoningSteps = [
                "1. Analyzing request context and workspace state for \(model.displayName)...\n",
                "2. Checking tool allowlists (Composio, Fleet RAG, built-in bash)...\n",
                "3. Verified host connection at \(activeHost?.hostAndPort ?? "local:3080").\n",
                "4. Formulating verified plan and response syntax."
            ]
            
            for step in reasoningSteps {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    if let sIdx = self.sessions.firstIndex(where: { $0.id == sessionId }),
                       let mIdx = self.sessions[sIdx].messages.indices.last {
                        let current = self.sessions[sIdx].messages[mIdx].reasoningContent ?? ""
                        self.sessions[sIdx].messages[mIdx].reasoningContent = current + step
                        self.currentSession = self.sessions[sIdx]
                    }
                }
            }
        }
        
        // Step 2: Content streaming phase
        let sampleContent: String
        if triggersComposio {
            sampleContent = "I've checked the open items via Composio.&nbsp; Issue #30 is in progress for the Harness iOS companion app.&nbsp; All required tools are mounted and authorized."
        } else if triggersRecall {
            sampleContent = "Retrieved fleet memory from the shared corpus.&nbsp; All active guidelines and operational rules for \(model.displayName) are in scope."
        } else {
            sampleContent = "Executed query via **\(model.displayName)** on **\(activeHost?.name ?? "Host")**.&nbsp; The workspace `\(activeWorkspace?.path ?? "~/Code/Harness")` is clean and ready for operations.&nbsp; Let me know what changes or commands to run next."
        }
        
        let words = sampleContent.components(separatedBy: " ")
        for (i, word) in words.enumerated() {
            try? await Task.sleep(nanoseconds: 60_000_000)
            await MainActor.run {
                if let sIdx = self.sessions.firstIndex(where: { $0.id == sessionId }),
                   let mIdx = self.sessions[sIdx].messages.indices.last {
                    let prev = self.sessions[sIdx].messages[mIdx].content
                    self.sessions[sIdx].messages[mIdx].content = prev.isEmpty ? word : "\(prev) \(word)"
                    if i == words.count - 1 {
                        self.sessions[sIdx].messages[mIdx].toolCalls = toolCalls
                        self.sessions[sIdx].messages[mIdx].isStreaming = false
                        self.sessions[sIdx].tokenCount += 350
                        self.isGenerating = false
                    }
                    self.currentSession = self.sessions[sIdx]
                }
            }
        }
        
        await MainActor.run {
            self.saveSessions()
        }
    }
}
