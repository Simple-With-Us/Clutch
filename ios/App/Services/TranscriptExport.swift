import Foundation

/// Renders a thread transcript as Markdown for sharing and saving.  One
/// shape everywhere: the iOS share sheet, the Mac save panel, and the
/// copy-transcript actions all hand over this exact text.
public enum TranscriptExport {
    public struct Entry: Equatable, Sendable {
        public var role: Role
        public var text: String

        public enum Role: Equatable, Sendable {
            case user
            case assistant
            case thought
            case tool
        }

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    public static func markdown(title: String, cwd: String?, entries: [Entry], exportedAt: Date = Date()) -> String {
        var lines: [String] = ["# \(title.isEmpty ? "MiniMax Code Thread" : title)", ""]
        if let cwd, !cwd.isEmpty {
            lines.append("Working directory: `\(cwd)`")
        }
        let stamp = ISO8601DateFormatter().string(from: exportedAt)
        lines.append("Exported: \(stamp)")
        lines.append("")
        for entry in entries where !entry.text.isEmpty {
            switch entry.role {
            case .user:
                lines.append("## You")
            case .assistant:
                lines.append("## Assistant")
            case .thought:
                lines.append("## Thinking")
            case .tool:
                lines.append("**Tool:** \(entry.text)")
                lines.append("")
                continue
            }
            lines.append("")
            lines.append(entry.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Writes the Markdown to a temporary `.md` file for the share sheet.
    public static func tempFile(title: String, markdown: String) -> URL? {
        let safe = title
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        let name = (safe.isEmpty ? "minimax-code-thread" : String(safe.prefix(60))) + ".md"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
