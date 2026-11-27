import SwiftUI

/// Parsed markdown, kept across body passes.
///
/// A transcript re-renders for reasons that have nothing to do with its
/// text — a hover, a ticking count, a sibling row streaming — and every
/// visible history row used to re-split its fences and rebuild its
/// attributed string on each pass.  The parse is a pure function of the
/// string, so the string itself is the key; NSCache bounds the memory and
/// drops the lot under pressure, which is the right failure for a cache.
private enum ClutchMarkdownCache {
    private final class CachedBlocks {
        let value: MarkdownBlocks
        init(_ value: MarkdownBlocks) { self.value = value }
    }

    private final class CachedProse {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let blocksCache: NSCache<NSString, CachedBlocks> = {
        let cache = NSCache<NSString, CachedBlocks>()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private static let proseCache: NSCache<NSString, CachedProse> = {
        let cache = NSCache<NSString, CachedProse>()
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func blocks(for text: String) -> MarkdownBlocks {
        let key = text as NSString
        if let cached = blocksCache.object(forKey: key) { return cached.value }
        let parsed = MarkdownBlocks.parse(text)
        blocksCache.setObject(CachedBlocks(parsed), forKey: key, cost: text.utf16.count * 2)
        return parsed
    }

    static func prose(for source: String) -> AttributedString {
        let key = source as NSString
        if let cached = proseCache.object(forKey: key) { return cached.value }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let parsed = (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
        proseCache.setObject(CachedProse(parsed), forKey: key, cost: source.utf16.count * 2)
        return parsed
    }
}

/// Markdown in a transcript.
///
/// The prose keeps its inline markdown and the fenced code is drawn as
/// code, in a monospaced block with a copy button.  A coding client that
/// renders literal triple backticks is a credibility problem, not a polish
/// problem.
public struct ClutchMarkdownText: View {
    /// The markdown to draw.
    public var text: String
    /// The font the prose is drawn in.
    public var font: Font
    /// The colour the prose is drawn in.
    public var color: Color

    public init(
        text: String,
        font: Font = ClutchFont.footnote,
        color: Color = .primary
    ) {
        self.text = text
        self.font = font
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.snug) {
            ForEach(Array(blocks.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let source):
                    Text(prose(source))
                        .font(font)
                        .foregroundStyle(color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let source):
                    ClutchCodeBlock(language: language, source: source)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The parts of the text.
    private var blocks: MarkdownBlocks {
        ClutchMarkdownCache.blocks(for: text)
    }

    /// The prose, with its inline markdown read.
    ///
    /// The code is already out of the text by now, so only the inline
    /// syntax is interpreted:  a line that starts with a hash in the middle
    /// of a sentence is still a sentence.
    private func prose(_ source: String) -> AttributedString {
        ClutchMarkdownCache.prose(for: source)
    }
}

/// A fenced block of code, with a copy button.
public struct ClutchCodeBlock: View {
    /// The language the block was tagged with.
    public var language: String?
    /// The code.
    public var source: String
    /// How many lines are drawn before the block folds away.
    public var maximumLines: Int

    @State private var copied = false
    @State private var showsAll = false

    public init(language: String? = nil, source: String, maximumLines: Int = 12) {
        self.language = language
        self.source = source
        self.maximumLines = maximumLines
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.hair) {
            HStack(spacing: ClutchSpacing.tight) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(ClutchFont.microStrong)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    copy()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(ClutchFont.microStrong)
                        .foregroundStyle(copied ? ClutchColor.success : Color.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy Code")
                .help(copied ? "Copied" : "Copy Code")
            }
            Text(shown)
                .font(ClutchFont.monoMicro)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ClutchSpacing.snug)
                .background(ClutchColor.surface, in: RoundedRectangle(cornerRadius: ClutchRadius.control))
            if isFolded {
                Button {
                    showsAll.toggle()
                } label: {
                    Text(showsAll ? "Show Less" : "Show All")
                        .font(ClutchFont.microStrong)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsAll ? "Show Less" : "Show All")
            }
        }
    }

    /// The lines that are drawn.
    private var shown: String {
        guard isFolded, !showsAll else { return source }
        let lines = source.components(separatedBy: .newlines)
        return lines.prefix(maximumLines).joined(separator: "\n")
    }

    /// Whether the block has more to show than it shows.
    private var isFolded: Bool {
        source.components(separatedBy: .newlines).count > maximumLines
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = source
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}
