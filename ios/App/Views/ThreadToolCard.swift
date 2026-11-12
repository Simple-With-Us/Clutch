import SwiftUI

/// One tool call in a MiniMax Code transcript, live or replayed: the tool's
/// title and where it stands.  Shared by the Mac chat pane and the iOS
/// thread view so a tool looks the same on both.  (The older
/// `ToolCallCard` in Components uses UIKit colors and stays iOS-only.)
public struct ThreadToolCard: View {
    public var name: String
    public var status: String
    /// How deep the call sits under the call that made it.
    ///
    /// A tool that runs other tools is the parent of them, and the children
    /// hang under it, the way the web canvas shows them.
    public var depth: Int = 0
    /// What the tool was asked to do, as the engine wrote it.
    public var input: String?
    @State private var expanded = false

    public init(
        name: String,
        status: String,
        depth: Int = 0,
        input: String? = nil
    ) {
        self.name = name
        self.status = status
        self.depth = depth
        self.input = input
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
                    VStack(alignment: .leading, spacing: 6) {
                        // What the tool was asked, before what it answered:
                        // the name says which tool ran, and this says what it
                        // was asked to do.
                        if let input, !input.isEmpty {
                            Text(input)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(name)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        // The tree: a call that ran other tools holds them under itself.
        .padding(.leading, 9 + CGFloat(depth) * 14)
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

/// How deep a tool call sits under the call that made it.
///
/// The depth is worked out from the calls themselves, so a call whose parent
/// was never seen still shows, one level down, rather than disappearing.
public enum ToolCallDepth {
    /// The deepest nesting a tree shows.
    ///
    /// A tree is walked with the calls it knows, and a loop in those calls
    /// must not spin forever.
    public static let maximum = 8

    /// The depth of one call, given the parents of all the calls.
    public static func depth(of id: String?, parents: [String: String]) -> Int {
        guard let id, !id.isEmpty else { return 0 }
        var depth = 0
        var current = parents[id]
        var seen: Set<String> = [id]
        while let parent = current, !seen.contains(parent), depth < maximum {
            seen.insert(parent)
            depth += 1
            current = parents[parent]
        }
        return depth
    }
}
