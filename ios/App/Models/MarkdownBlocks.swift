import Foundation

/// The parts of a markdown text.
///
/// A coding client that renders literal triple backticks is a credibility
/// problem, not a polish problem, so the fenced code is taken out of the
/// prose and drawn as code.  The prose keeps its inline markdown.
public struct MarkdownBlocks: Equatable, Sendable {

    /// One part of a markdown text.
    public enum Block: Equatable, Sendable {
        /// Prose, with inline markdown.
        case prose(String)
        /// A fenced code block, with the language it was tagged with.
        case code(language: String?, source: String)
    }

    /// The parts, in the order they appear.
    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    /// The parts of a markdown text.
    ///
    /// A fence that was never closed is still code:  showing the rest of
    /// the message as prose would be a guess about where the code ended.
    public static func parse(_ text: String) -> MarkdownBlocks {
        var blocks: [Block] = []
        var prose: [String] = []
        var source: [String] = []
        var language: String?
        var inCode = false

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.prose(joined)) }
            prose = []
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: language, source: source.joined(separator: "\n")))
                    source = []
                    language = nil
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                    let name = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = name.isEmpty ? nil : name
                }
                continue
            }
            if inCode {
                source.append(line)
            } else {
                prose.append(line)
            }
        }

        if inCode {
            blocks.append(.code(language: language, source: source.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return MarkdownBlocks(blocks: blocks)
    }
}
