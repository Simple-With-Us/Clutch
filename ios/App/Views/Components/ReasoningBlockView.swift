import SwiftUI

public struct ReasoningBlockView: View {
    public let reasoningText: String
    public var isStreaming: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool = false

    public init(reasoningText: String, isStreaming: Bool = false) {
        self.reasoningText = reasoningText
        self.isStreaming = isStreaming
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(reduceMotion ? nil : ClutchMotion.standard) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isStreaming ? "sparkles" : "brain")
                        .font(ClutchFont.footnote.weight(.semibold))
                        .foregroundColor(.indigo)

                    Text(isStreaming ? "Thinking…" : "Thought process")
                        .font(ClutchFont.footnote.weight(.medium))
                        .foregroundColor(.secondary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(ClutchFont.micro.weight(.semibold))
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
                        .font(ClutchFont.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineSpacing(3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
