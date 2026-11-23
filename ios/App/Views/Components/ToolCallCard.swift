import SwiftUI

public struct ToolCallCard: View {
    public let toolCall: ToolCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool = false

    public init(toolCall: ToolCall) {
        self.toolCall = toolCall
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(reduceMotion ? nil : ClutchMotion.standard) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: toolCall.status))
                        .font(ClutchFont.captionStrong)
                        .foregroundColor(statusColor(for: toolCall.status))

                    Text(toolCall.name)
                        .font(ClutchFont.footnote.weight(.semibold).monospaced())
                        .foregroundColor(.primary)

                    Spacer()

                    if let ms = toolCall.durationMs {
                        Text("\(Int(ms))ms")
                            .font(ClutchFont.micro.monospaced())
                            .foregroundColor(.secondary)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(ClutchFont.micro.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if !toolCall.argumentsJson.isEmpty {
                        Text("Arguments:")
                            .font(ClutchFont.sectionLabel)
                            .foregroundColor(.secondary)
                        Text(toolCall.argumentsJson)
                            .font(ClutchFont.micro.monospaced())
                            .foregroundColor(.primary)
                    }

                    if let out = toolCall.output, !out.isEmpty {
                        Divider()
                        Text("Output:")
                            .font(ClutchFont.sectionLabel)
                            .foregroundColor(.secondary)
                        Text(out)
                            .font(ClutchFont.micro.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func iconName(for status: ToolStatus) -> String {
        switch status {
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "wrench.and.screwdriver.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func statusColor(for status: ToolStatus) -> Color {
        switch status {
        case .running: return .orange
        case .completed: return .blue
        case .failed: return .red
        }
    }
}
