import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What one paste, drop, or file pick produced.
///
/// Images ride the next turn as attachments; text inserts are spliced into
/// the draft (a pasted source file's contents, fenced with its name); and
/// every thing that could not be used gets one plain message.
public struct PasteOutcome: Sendable {
    public var images: [ChatAttachment] = []
    public var textInserts: [String] = []
    public var errors: [String] = []

    public init(images: [ChatAttachment] = [], textInserts: [String] = [], errors: [String] = []) {
        self.images = images
        self.textInserts = textInserts
        self.errors = errors
    }

    public var isEmpty: Bool { images.isEmpty && textInserts.isEmpty && errors.isEmpty }

    mutating func merge(_ other: PasteOutcome) {
        images.append(contentsOf: other.images)
        textInserts.append(contentsOf: other.textInserts)
        errors.append(contentsOf: other.errors)
    }
}

/// Paste, drop, and file-attach handling shared by the iOS and Mac composers.
///
/// Every entry point funnels into `fate(data:name:)`: image bytes (PNG,
/// JPEG, GIF, WebP) become turn attachments, anything the platform can
/// decode (screenshots as TIFF, HEIC photos) is re-encoded into one of
/// those, and text files inline into the draft instead — the sidecar only
/// takes images, so a source file travels as a fenced block the engine
/// reads in the prompt.  The bytes decide before the name does, the same
/// rule `ChatAttachment` itself follows.
public enum AttachmentPaste {
    /// The most items one paste or drop takes, so a stray multi-select
    /// cannot queue dozens of turns' worth of images at once.
    public static let maxItemsPerPaste = 10

    /// The most bytes inlined from one text file.  Past that the draft
    /// would be a wall of text the owner did not mean to send.
    public static let maxTextBytes = 200_000

    /// What one file becomes.
    public enum FileFate: Equatable, Sendable {
        /// An image attachment for the next turn.
        case image(ChatAttachment)
        /// Text to splice into the draft.
        case text(insert: String)
        /// Why the file could not be used.
        case rejected(message: String)
    }

    // MARK: - The dispatcher

    /// What one file becomes: an image attachment, a draft insert, or a
    /// message saying why neither.  The bytes are tried as an engine image
    /// first, then as anything the platform can re-encode (a TIFF
    /// screenshot, a HEIC photo, an oversize PNG shrunk to JPEG), then as
    /// a text file to inline — anything else is refused out loud.
    public static func fate(data: Data, name: String) -> FileFate {
        let cleanName = name.isEmpty ? "pasted-image" : name
        // Candidates in order: the bytes as-is when the engines take the
        // type, otherwise a platform PNG re-encode of what they do not.
        var candidates: [(data: Data, name: String)] = []
        if ChatAttachment.detectMimeType(data) != nil {
            candidates.append((data, cleanName))
        } else if let png = platformPNGData(from: data) {
            candidates.append((png, replacingExtension(of: cleanName, with: "png")))
        }
        // One JPEG fallback covers the oversize (a retina screenshot's PNG
        // routinely clears 6 MB) as well as source types the engines never
        // take: the bytes are tried small before they are refused big.
        let biggest = candidates.first?.data.count ?? 0
        if candidates.isEmpty || biggest > ChatAttachment.maxBytes,
           let jpeg = platformJPEGData(from: data) {
            candidates.append((jpeg, replacingExtension(of: cleanName, with: "jpg")))
        }
        for candidate in candidates {
            if let attachment = ChatAttachment.from(data: candidate.data, name: candidate.name) {
                return .image(attachment)
            }
        }
        if !candidates.isEmpty {
            return .rejected(message: AttachmentError.tooLarge(bytes: data.count).message)
        }
        if isTextFile(name: cleanName) {
            return textFate(data: data, name: cleanName)
        }
        return .rejected(message: unsupportedMessage(for: cleanName))
    }

    /// What a text file becomes: its contents fenced with its name, or a
    /// message when it is too big or is not readable text.
    static func textFate(data: Data, name: String) -> FileFate {
        guard data.count <= maxTextBytes else {
            return .rejected(message: Copy.gap(
                "\(name) is over the 200 KB text cap.",
                "Paste a smaller excerpt instead."
            ))
        }
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(message: "\(name) is not readable text.")
        }
        return .text(insert: fencedBlock(fileName: name, content: text))
    }

    /// A file's contents fenced with its name, so the engine sees what it
    /// was pasted from.
    public static func fencedBlock(fileName: String, content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return "```\(fileName)\n\(trimmed)\n```"
    }

    /// Whether the name belongs to a text file, by extension or by the
    /// bare names projects keep at their root.
    public static func isTextFile(name: String) -> Bool {
        let lower = name.lowercased()
        if textFileNames.contains(lower) { return true }
        guard let dot = lower.lastIndex(of: ".") else { return false }
        return textFileExtensions.contains(String(lower[lower.index(after: dot)...]))
    }

    /// Extensions inlined as text when their bytes are not an image.
    public static let textFileExtensions: Set<String> = [
        "txt", "md", "markdown", "rst", "log", "json", "jsonl", "yaml", "yml",
        "toml", "ini", "cfg", "conf", "env", "csv", "tsv", "xml", "plist",
        "swift", "c", "h", "cpp", "hpp", "m", "mm", "cs", "java", "kt", "kts",
        "go", "rs", "py", "rb", "php", "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "html", "css", "scss", "less", "vue", "svelte", "dart", "lua", "r",
        "jl", "ex", "exs", "erl", "hs", "scala", "pl", "pm", "tex", "diff",
        "patch", "sh", "bash", "zsh", "sql", "graphql", "gql", "gitignore",
    ]

    /// Bare file names inlined as text (they carry no extension).
    public static let textFileNames: Set<String> = [
        "dockerfile", "makefile", "readme", "license", "changelog", "authors",
        "copying", "gemfile", "podfile", "justfile",
    ]

    static func unsupportedMessage(for name: String) -> String {
        if name.contains(".") {
            return "\(name) is not an image or text file Clutch can attach."
        }
        return "That item is not an image or text file Clutch can attach."
    }

    static func replacingExtension(of name: String, with ext: String) -> String {
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return String(name[..<dot]) + "." + ext
        }
        return name + "." + ext
    }

    // MARK: - Files

    /// Files bigger than this are refused without being read: nothing past
    /// it can become an attachment (6 MB) or an inline excerpt (200 KB),
    /// so loading it would only burn memory.
    public static let maxFileBytes = 25 * 1024 * 1024

    /// Read files off disk into an outcome.  Reads are capped per call;
    /// every file is dispatched by its bytes, never trusted by its name.
    public static func outcomeForFileURLs(_ urls: [URL]) -> PasteOutcome {
        var outcome = PasteOutcome()
        for url in urls.prefix(maxItemsPerPaste) {
            // A provider can vend a web link where a file was expected;
            // reading it would be a network fetch, not a paste.
            guard url.isFileURL else {
                outcome.errors.append("That link is not a file Clutch can attach.")
                continue
            }
            let accessing = url.startAccessingSecurityScopedResource()
            // Swift runs this per iteration (unlike Go's function-scoped
            // defer), so each grant is released before the next file.
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            // Metadata is queried inside the access grant: outside it the
            // query can fail, and a file whose size cannot be verified is
            // refused rather than read unbounded.
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                  let size = values.fileSize else {
                outcome.errors.append("Could not read \(url.lastPathComponent).")
                continue
            }
            if values.isDirectory == true {
                outcome.errors.append(Copy.gap(
                    "\(url.lastPathComponent) is a folder.",
                    "Open it and pick files inside."
                ))
                continue
            }
            if size > maxFileBytes {
                outcome.errors.append("\(url.lastPathComponent) is too big to attach.")
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                outcome.errors.append("Could not read \(url.lastPathComponent).")
                continue
            }
            switch fate(data: data, name: url.lastPathComponent) {
            case .image(let attachment):
                outcome.images.append(attachment)
            case .text(let insert):
                outcome.textInserts.append(insert)
            case .rejected(let message):
                outcome.errors.append(message)
            }
        }
        if urls.count > maxItemsPerPaste {
            outcome.errors.append("Only the first \(maxItemsPerPaste) files were used.")
        }
        return outcome
    }

    // MARK: - Item providers (paste command + drop)

    /// The image types taken from a provider, most faithful first.
    static var preferredImageIdentifiers: [String] {
        [
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.gif.identifier,
            "org.webmproject.webp",
            UTType.tiff.identifier,
            UTType.heic.identifier,
            UTType.heif.identifier,
            UTType.bmp.identifier,
        ]
    }

    /// Build an outcome from paste-command or drop providers.  A provider
    /// that names a file URL is read as that file (the real name survives);
    /// then a file-backed provider's file representation under its
    /// suggested name; then the best image representation; then raw data
    /// as a last resort.
    public static func outcomeForProviders(_ providers: [NSItemProvider]) async -> PasteOutcome {
        var outcome = PasteOutcome()
        for provider in providers.prefix(maxItemsPerPaste) {
            // A web link vends where a file was expected: it must not
            // shadow an image representation, so it is remembered and
            // reported only when nothing else on the provider was usable.
            var linkURL: URL?
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadFileURL(from: provider) {
                if url.isFileURL {
                    outcome.merge(outcomeForFileURLs([url]))
                    continue
                }
                linkURL = url
            }
            if let file = await loadFile(from: provider) {
                switch file {
                case .file(let data, let name):
                    outcome.merge(fateOutcome(data: data, name: name))
                case .tooLarge(let name):
                    outcome.errors.append("\(name) is too big to attach.")
                }
                continue
            }
            if let identifier = imageIdentifier(for: provider),
               let data = await loadData(from: provider, type: identifier) {
                let name = provider.suggestedName ?? suggestedName(for: identifier)
                outcome.merge(fateOutcome(data: data, name: name))
                continue
            }
            if let identifier = provider.registeredTypeIdentifiers.first,
               let data = await loadData(from: provider, type: identifier) {
                // Last resort: unidentified data is still dispatched by its
                // bytes, so a wrong claim is refused, not mis-sent.
                let name = provider.suggestedName ?? suggestedName(for: identifier)
                outcome.merge(fateOutcome(data: data, name: name))
                continue
            }
            if linkURL != nil {
                outcome.errors.append("That link is not a file Clutch can attach.")
            } else {
                outcome.errors.append("That item is not an image or file Clutch can attach.")
            }
        }
        if providers.count > maxItemsPerPaste {
            outcome.errors.append("Only the first \(maxItemsPerPaste) items were used.")
        }
        return outcome
    }

    /// What one file-backed provider holds: its bytes under its suggested
    /// name, or the fact that it is too big to read at all.
    enum LoadedFile {
        case file(data: Data, name: String)
        case tooLarge(name: String)
    }

    /// Read a file-backed provider through its file representation.
    ///
    /// A provider made from a file advertises the file's own type, and only
    /// the file representation serves it — item and data loads come back
    /// empty.  The bytes are read inside the handler (the copy is only
    /// good there) after a size check, so a dropped movie never lands in
    /// memory whole.
    static func loadFile(from provider: NSItemProvider) async -> LoadedFile? {
        let name = provider.suggestedName ?? suggestedName(for: provider.registeredTypeIdentifiers.first ?? "")
        var identifiers = provider.registeredTypeIdentifiers
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            identifiers.insert(UTType.fileURL.identifier, at: 0)
        }
        for identifier in identifiers {
            if let file = await loadFileResult(from: provider, type: identifier, name: name) {
                return file
            }
        }
        return nil
    }

    static func loadFileResult(from provider: NSItemProvider, type: String, name: String) async -> LoadedFile? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                // A copy whose size cannot be verified is refused rather
                // than read unbounded.
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
                    return continuation.resume(returning: nil)
                }
                if size > maxFileBytes {
                    return continuation.resume(returning: .tooLarge(name: name))
                }
                guard let data = try? Data(contentsOf: url) else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: .file(data: data, name: name))
            }
        }
    }

    /// One file's dispatch wrapped as an outcome.
    static func fateOutcome(data: Data, name: String) -> PasteOutcome {
        switch fate(data: data, name: name) {
        case .image(let attachment):
            return PasteOutcome(images: [attachment])
        case .text(let insert):
            return PasteOutcome(textInserts: [insert])
        case .rejected(let message):
            return PasteOutcome(errors: [message])
        }
    }

    /// The provider's best image representation, when it has one.
    static func imageIdentifier(for provider: NSItemProvider) -> String? {
        for identifier in preferredImageIdentifiers {
            if provider.hasItemConformingToTypeIdentifier(identifier) { return identifier }
        }
        // Anything else the provider calls an image still counts: the bytes
        // are checked on load, so a wrong claim is refused, not mis-sent.
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier), type.conforms(to: .image) else { continue }
            return identifier
        }
        return nil
    }

    /// A name for provider data, which carries no file name of its own.
    static func suggestedName(for identifier: String) -> String {
        if let type = UTType(identifier), let ext = type.preferredFilenameExtension {
            return "pasted-image.\(ext)"
        }
        return "pasted-image.png"
    }

    static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else if let string = item as? String {
                    continuation.resume(returning: URL(string: string))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    static func loadData(from provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - The system clipboard

    /// Read the system clipboard, with one signature on both platforms:
    /// async everywhere, so every composer calls this and nothing else.
    @MainActor
    public static func pasteFromClipboard() async -> PasteOutcome {
#if os(iOS)
        return await pasteFromSystemClipboard()
#else
        return pasteFromSystemClipboard()
#endif
    }

#if os(iOS)
    /// Read the system clipboard: screenshots and copied photos arrive as
    /// images, Files-app copies as providers, bare copies as URLs.
    @MainActor
    public static func pasteFromSystemClipboard() async -> PasteOutcome {
        let board = UIPasteboard.general
        if board.hasImages, let uiImages = board.images, !uiImages.isEmpty {
            var outcome = PasteOutcome()
            for (index, image) in uiImages.prefix(maxItemsPerPaste).enumerated() {
                guard let data = image.pngData() else {
                    outcome.errors.append("Could not read that image.")
                    continue
                }
                switch fate(data: data, name: "pasted-image-\(index + 1).png") {
                case .image(let attachment):
                    outcome.images.append(attachment)
                case .text(let insert):
                    outcome.textInserts.append(insert)
                case .rejected(let message):
                    outcome.errors.append(message)
                }
            }
            if uiImages.count > maxItemsPerPaste {
                outcome.errors.append("Only the first \(maxItemsPerPaste) images were used.")
            }
            return outcome
        }
        if !board.itemProviders.isEmpty {
            let outcome = await outcomeForProviders(board.itemProviders)
            if !outcome.isEmpty { return outcome }
        }
        if let urls = board.urls, !urls.isEmpty {
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { return outcomeForFileURLs(files) }
        }
        // Some apps set raw image data without the UIImage bridge.
        for identifier in preferredImageIdentifiers {
            if let data = board.data(forPasteboardType: identifier) {
                return outcomeForProvidersFallback(data: data, identifier: identifier)
            }
        }
        return PasteOutcome(errors: ["The clipboard has no image or file to paste."])
    }

    /// One raw-data fallback wrapped as an outcome, so the clipboard read
    /// above stays a straight line.
    static func outcomeForProvidersFallback(data: Data, identifier: String) -> PasteOutcome {
        switch fate(data: data, name: suggestedName(for: identifier)) {
        case .image(let attachment):
            return PasteOutcome(images: [attachment])
        case .text(let insert):
            return PasteOutcome(textInserts: [insert])
        case .rejected(let message):
            return PasteOutcome(errors: [message])
        }
    }
#elseif os(macOS)
    /// Read the system clipboard: Finder copies arrive as file URLs with
    /// their real names, screenshots and copied pictures as images.
    public static func pasteFromSystemClipboard() -> PasteOutcome {
        let board = NSPasteboard.general
        if let objects = board.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL] {
            let files = objects.map { $0 as URL }.filter(\.isFileURL)
            if !files.isEmpty { return outcomeForFileURLs(files) }
        }
        if let images = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           !images.isEmpty {
            var outcome = PasteOutcome()
            for (index, image) in images.prefix(maxItemsPerPaste).enumerated() {
                guard let tiff = image.tiffRepresentation else {
                    outcome.errors.append("Could not read that image.")
                    continue
                }
                switch fate(data: tiff, name: "pasted-image-\(index + 1).tiff") {
                case .image(let attachment):
                    outcome.images.append(attachment)
                case .text(let insert):
                    outcome.textInserts.append(insert)
                case .rejected(let message):
                    outcome.errors.append(message)
                }
            }
            if images.count > maxItemsPerPaste {
                outcome.errors.append("Only the first \(maxItemsPerPaste) images were used.")
            }
            return outcome
        }
        // Raw image data without the NSImage bridge.
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type) {
                let name = type == .png ? "pasted-image.png" : "pasted-image.tiff"
                switch fate(data: data, name: name) {
                case .image(let attachment):
                    return PasteOutcome(images: [attachment])
                case .text(let insert):
                    return PasteOutcome(textInserts: [insert])
                case .rejected(let message):
                    return PasteOutcome(errors: [message])
                }
            }
        }
        return PasteOutcome(errors: ["The clipboard has no image or file to paste."])
    }
#endif

    // MARK: - Platform re-encoding

    /// A PNG of any image the platform can decode (HEIC, TIFF, BMP), or nil
    /// when the bytes are not an image at all.
    static func platformPNGData(from data: Data) -> Data? {
#if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return image.pngData()
#elseif os(macOS)
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
#else
        return nil
#endif
    }

    /// A quality-0.8 JPEG of any image the platform can decode, or nil when
    /// the bytes are not an image at all.  The fallback that shrinks an
    /// oversize PNG (a retina screenshot) under the cap.
    static func platformJPEGData(from data: Data) -> Data? {
#if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.8)
#elseif os(macOS)
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
#else
        return nil
#endif
    }
}
