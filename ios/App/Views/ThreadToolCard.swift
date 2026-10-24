import SwiftUI

/// One tool call in a MiniMax Code transcript, live or replayed: the tool's
/// title and where it stands.  Shared by the Mac chat pane and the iOS
/// thread view so a tool looks the same on both.  (The older
/// `ToolCallCard` in Components uses UIKit colors and stays iOS-only.)
public struct ThreadToolCard: View {
    public var name: String
    public var status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(statusLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.clutchSecondaryBackground, in: RoundedRectangle(cornerRadius: 8))
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
        case "completed": return "DONE"
        case "failed": return "FAILED"
        default: return "RUNNING"
        }
    }
}
