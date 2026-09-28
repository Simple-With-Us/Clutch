import SwiftUI

public struct ReasoningBlockView: View {
    public let reasoningText: String
    public var isStreaming: Bool = false
    @State private var isExpanded: Bool = false
    
    public init(reasoningText: String, isStreaming: Bool = false) {
        self.reasoningText = reasoningText
        self.isStreaming = isStreaming
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isStreaming ? "sparkles" : "brain")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.indigo)
                        .symbolEffect(.pulse, isActive: isStreaming)
                    
                    Text(isStreaming ? "Thinking..." : "Thought process")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reasoningText.replacingOccurrences(of: "&nbsp;", with: "  "))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
            }
        }
    }
}
