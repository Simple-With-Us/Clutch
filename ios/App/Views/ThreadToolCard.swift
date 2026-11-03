import SwiftUI

/// One tool call in a MiniMax Code transcript, live or replayed: the tool's
/// title and where it stands.  Shared by the Mac chat pane and the iOS
/// thread view so a tool looks the same on both.  (The older
/// `ToolCallCard` in Components uses UIKit colors and stays iOS-only.)
public struct ThreadToolCard: View {
    public var name: String
    public var status: String
    @State private var expanded = false

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse Tool Details" : "Expand Tool Details")
            if expanded {
                ScrollView {
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.clutchSecondaryBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(statusLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
        }
        .contentShape(Rectangle())
    }

    private var summary: String {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") || text.hasPrefix("[") { return "Tool Output" }
        return String(text.prefix(160)).components(separatedBy: .newlines).first ?? "Tool Call"
    }

    private var symbol: String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "failed": return "xmark.octagon.fill"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    private var color: Color {
        switch status {
        case "completed": return .green
        case "failed": return .red
        default: return .orange
        }
    }

    private var statusLabel: String {
        switch status {
        case "completed": return "Done"
        case "failed": return "Failed"
        default: return "Running"
        }
    }
}
