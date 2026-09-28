import SwiftUI

public struct ToolCallCard: View {
    public let toolCall: ToolCall
    @State private var isExpanded: Bool = false
    
    public init(toolCall: ToolCall) {
        self.toolCall = toolCall
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: iconForTool(toolCall.name))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                    
                    Text(toolCall.name)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if let duration = toolCall.durationMs {
                        Text("\(Int(duration))ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Image(systemName: toolCall.status == .completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(toolCall.status == .completed ? .green : .red)
                    
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
                VStack(alignment: .leading, spacing: 8) {
                    // Input params
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ARGUMENTS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Text(toolCall.argumentsJson)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                    
                    // Output
                    if let output = toolCall.output {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OUTPUT")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                            
                            Text(output.replacingOccurrences(of: "&nbsp;", with: "  "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    
    private func iconForTool(_ name: String) -> String {
        if name.contains("composio") {
            return "puzzlepiece.extension.fill"
        } else if name.contains("recall") || name.contains("rag") {
            return "externaldrive.badge.icloud"
        } else if name.contains("bash") || name.contains("shell") {
            return "terminal.fill"
        } else if name.contains("file") {
            return "doc.text.fill"
        } else {
            return "wrench.and.screwdriver.fill"
        }
    }
}
