import SwiftUI

/// One tool call in a transcript, live or replayed:  what the call was, what
/// it answered, and where it stands.  Shared by the Mac chat pane and the
/// iOS thread view so a tool looks the same on both.  (The older
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
    /// What the tool answered, as the engine wrote it.
    public var output: String?
    @State private var expanded = false
    @State private var showsRaw = false

    public init(
        name: String,
        status: String,
        depth: Int = 0,
        input: String? = nil,
        output: String? = nil
    ) {
        self.name = name
        self.status = status
        self.depth = depth
        self.input = input
        self.output = output
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.base) {
            Button {
                expanded.toggle()
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilitySummary)
            if expanded {
                detail
            }
        }
        .padding(.horizontal, ClutchSpacing.base)
        .padding(.vertical, ClutchSpacing.snug)
        // The tree: a call that ran other tools holds them under itself.
        .padding(.leading, ClutchSpacing.base + CGFloat(depth) * 14)
        .background(ClutchColor.surface, in: RoundedRectangle(cornerRadius: ClutchRadius.control))
    }

    /// What the call was, read into the shape the card draws.
    private var typed: TypedToolCard {
        TypedToolCard.make(name: name, status: status, input: input, output: output)
    }

    /// The body of the card.
    ///
    /// What is shown is what the engine wrote:  the file that was read, the
    /// lines that changed, the command and how it ended, the suite and how
    /// many failed.  The raw call and the raw answer are one button away
    /// for the reader who wants exactly what was written.
    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.snug) {
            switch typed.kind {
            case .fileRead:
                if let output, !output.isEmpty {
                    ClutchCodeBlock(source: output, maximumLines: 20)
                }
            case .fileEdit:
                if typed.addedLines > 0 || typed.removedLines > 0 {
                    HStack(spacing: ClutchSpacing.snug) {
                        Text("+\(typed.addedLines)")
                            .font(ClutchFont.monoMicro)
                            .foregroundStyle(.green)
                        Text("−\(typed.removedLines)")
                            .font(ClutchFont.monoMicro)
                            .foregroundStyle(.red)
                    }
                }
                if let output, !output.isEmpty {
                    ClutchCodeBlock(source: output, maximumLines: 20)
                }
            case .shell:
                if let code = typed.exitCode {
                    Text(code == 0 ? "Exit 0" : "Exit \(code)")
                        .font(ClutchFont.monoMicro)
                        .foregroundStyle(code == 0 ? Color.secondary : Color.red)
                }
                if let output, !output.isEmpty {
                    ClutchCodeBlock(source: output, maximumLines: 20)
                }
            case .test:
                if !typed.failingNames.isEmpty {
                    VStack(alignment: .leading, spacing: ClutchSpacing.hair) {
                        ForEach(typed.failingNames, id: \.self) { name in
                            Text(name)
                                .font(ClutchFont.monoMicro)
                                .foregroundStyle(.red)
                        }
                    }
                }
                if let output, !output.isEmpty {
                    ClutchCodeBlock(source: output, maximumLines: 20)
                }
            case .unknown:
                if let output, !output.isEmpty {
                    ClutchCodeBlock(source: output, maximumLines: 20)
                }
            }

            if typed.rawInput != nil || typed.rawOutput != nil {
                Button {
                    showsRaw.toggle()
                } label: {
                    Text(showsRaw ? "Hide Raw" : "Show Raw")
                        .font(ClutchFont.microStrong)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsRaw ? "Hide Raw" : "Show Raw")
                .help(showsRaw ? "Hide Raw" : "Show Raw")
            }

            if showsRaw {
                VStack(alignment: .leading, spacing: ClutchSpacing.hair) {
                    if let raw = typed.rawInput, !raw.isEmpty {
                        Text(raw)
                            .font(ClutchFont.monoMicro)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let raw = typed.rawOutput, !raw.isEmpty {
                        Text(raw)
                            .font(ClutchFont.monoMicro)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(ClutchSpacing.snug)
                .background(ClutchColor.surface, in: RoundedRectangle(cornerRadius: ClutchRadius.control))
            }
        }
    }

    /// What VoiceOver reads for the header.  The label carries the tool's
    /// name and where it stands, because a bare "expand" would say nothing
    /// about which call it expands.
    private var accessibilitySummary: String {
        let verb = expanded ? "Collapse Tool Details" : "Expand Tool Details"
        return "\(verb), \(typed.headline), \(statusLabel)"
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(ClutchFont.microStrong)
                .foregroundStyle(.secondary)
            Image(systemName: symbol)
                .font(ClutchFont.microStrong)
                .foregroundStyle(color)
            Text(typed.headline)
                .font(ClutchFont.monoMicro)
                .lineLimit(1)
            if let detail = typed.detail {
                Text(detail)
                    .font(ClutchFont.monoMicro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(statusLabel)
                .font(ClutchFont.sectionLabel)
                .foregroundStyle(color)
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        ClutchStatus(toolStatus: status).symbol
    }

    private var color: Color {
        ClutchStatus(toolStatus: status).color
    }

    private var statusLabel: String {
        ClutchStatus.toolStatusLabel(forStatus: status)
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
