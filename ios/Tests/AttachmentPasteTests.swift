import XCTest
import UniformTypeIdentifiers
@testable import Clutch

/// Paste, drop, and file-attach dispatch, as every composer shares it.
///
/// Images become turn attachments by their bytes (never their names), text
/// files inline into the draft fenced with their names, and everything else
/// is refused with a message instead of failing silently at the send.
final class AttachmentPasteTests: XCTestCase {
    /// Twelve bytes with PNG magic, then zeros: enough for the detector,
    /// which reads the magic, not a valid image.
    private func pngBytes(size: Int) -> Data {
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x00])
        if size > bytes.count {
            bytes.append(Data(repeating: 0, count: size - bytes.count))
        }
        return bytes
    }

    // MARK: - Detection

    func testDetectsTheEngineImageTypes() {
        XCTAssertEqual(ChatAttachment.detectMimeType(pngBytes(size: 64)), "image/png")
        XCTAssertEqual(
            ChatAttachment.detectMimeType(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0])),
            "image/jpeg"
        )
        XCTAssertEqual(
            ChatAttachment.detectMimeType(Data([0x47, 0x49, 0x46, 0x38, 0, 0, 0, 0, 0, 0, 0, 0])),
            "image/gif"
        )
        XCTAssertEqual(
            ChatAttachment.detectMimeType(Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])),
            "image/webp"
        )
    }

    func testDetectionIgnoresTheName() {
        XCTAssertNil(ChatAttachment.detectMimeType(Data("not an image".utf8)))
        XCTAssertNil(ChatAttachment.detectMimeType(Data()))
    }

    // MARK: - The size cap

    func testSmallImagesBecomeAttachments() {
        let attachment = ChatAttachment.from(data: pngBytes(size: 1024), name: "shot.png")
        XCTAssertEqual(attachment?.mimeType, "image/png")
        XCTAssertEqual(attachment?.name, "shot.png")
    }

    func testOversizeImagesAreRefusedBeforeTheSend() {
        // The sidecar drops anything over 6 MB, so the client refuses it
        // with a message instead of sending an imageless turn.
        XCTAssertNil(ChatAttachment.from(data: pngBytes(size: 7 * 1024 * 1024), name: "big.png"))
    }

    func testRejectionMessagesSayWhatToDo() {
        XCTAssertTrue(AttachmentError.unsupportedType.message.contains("PNG"))
        XCTAssertTrue(AttachmentError.tooLarge(bytes: 0).message.contains("6 MB"))
    }

    // MARK: - Text files

    func testTextFilesAreRecognizedByName() {
        XCTAssertTrue(AttachmentPaste.isTextFile(name: "main.swift"))
        XCTAssertTrue(AttachmentPaste.isTextFile(name: "notes.MD"))
        XCTAssertTrue(AttachmentPaste.isTextFile(name: "run.sh"))
        XCTAssertTrue(AttachmentPaste.isTextFile(name: "Dockerfile"))
        XCTAssertTrue(AttachmentPaste.isTextFile(name: "Makefile"))
        XCTAssertTrue(AttachmentPaste.isTextFile(name: "README"))
        XCTAssertFalse(AttachmentPaste.isTextFile(name: "shot.png"))
        XCTAssertFalse(AttachmentPaste.isTextFile(name: "archive.zip"))
        XCTAssertFalse(AttachmentPaste.isTextFile(name: "data.bin"))
    }

    func testFencedBlockNamesItsSource() {
        let block = AttachmentPaste.fencedBlock(fileName: "main.swift", content: "let x = 1\n")
        XCTAssertEqual(block, "```main.swift\nlet x = 1\n```")
    }

    // MARK: - The dispatcher

    func testImageBytesBecomeAnAttachment() {
        switch AttachmentPaste.fate(data: pngBytes(size: 64), name: "shot.png") {
        case .image(let attachment):
            XCTAssertEqual(attachment.mimeType, "image/png")
            XCTAssertEqual(attachment.name, "shot.png")
        case .text, .rejected:
            XCTFail("PNG bytes should attach as an image")
        }
    }

    func testTextBytesInlineFencedWithTheirName() {
        let source = "print(\"hi\")\n"
        switch AttachmentPaste.fate(data: Data(source.utf8), name: "hello.py") {
        case .text(let insert):
            XCTAssertTrue(insert.contains("```hello.py"))
            XCTAssertTrue(insert.contains("print(\"hi\")"))
        case .image, .rejected:
            XCTFail("Python source should inline as text")
        }
    }

    func testUnknownBinariesAreRefusedOutLoud() {
        switch AttachmentPaste.fate(data: Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 64)), name: "archive.zip") {
        case .rejected(let message):
            XCTAssertTrue(message.contains("archive.zip"))
        case .image, .text:
            XCTFail("A zip should be refused, not attached or inlined")
        }
    }

    func testOversizeImagesAreRefusedWithTheCap() {
        // Zeros are no decodable image, so no JPEG fallback rescues this:
        // the verdict is the cap message, deterministically.
        switch AttachmentPaste.fate(data: pngBytes(size: 7 * 1024 * 1024), name: "big.png") {
        case .rejected(let message):
            XCTAssertTrue(message.contains("6 MB"))
        case .image, .text:
            XCTFail("A 7 MB image should be refused")
        }
    }

    func testOversizeTextIsRefusedBeforeItFloodsTheDraft() {
        let big = String(repeating: "x", count: AttachmentPaste.maxTextBytes + 1)
        switch AttachmentPaste.fate(data: Data(big.utf8), name: "notes.txt") {
        case .rejected(let message):
            XCTAssertTrue(message.contains("200 KB"))
        case .image, .text:
            XCTFail("Text past the cap should be refused")
        }
    }

    // MARK: - Files on disk

    /// A scratch directory that is removed when the test ends.
    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentPasteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testFilesDispatchByTheirBytes() throws {
        let dir = try scratchDirectory()
        let imageURL = dir.appendingPathComponent("shot.png")
        let textURL = dir.appendingPathComponent("notes.txt")
        let blobURL = dir.appendingPathComponent("blob.bin")
        try pngBytes(size: 64).write(to: imageURL)
        try "hello".write(to: textURL, atomically: true, encoding: .utf8)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: blobURL)

        let outcome = AttachmentPaste.outcomeForFileURLs([imageURL, textURL, blobURL])
        XCTAssertEqual(outcome.images.count, 1)
        XCTAssertEqual(outcome.images.first?.name, "shot.png")
        XCTAssertEqual(outcome.textInserts.count, 1)
        XCTAssertTrue(outcome.textInserts.first?.contains("```notes.txt") ?? false)
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertTrue(outcome.errors.first?.contains("blob.bin") ?? false)
    }

    func testFoldersAreRefusedWithWhatToDo() throws {
        let dir = try scratchDirectory()
        let outcome = AttachmentPaste.outcomeForFileURLs([dir])
        XCTAssertTrue(outcome.images.isEmpty)
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertTrue(outcome.errors.first?.contains("folder") ?? false)
    }

    // MARK: - Providers (paste command + drop)

    func testImageProvidersBecomeAttachments() async {
        let provider = NSItemProvider(
            item: pngBytes(size: 64) as NSData,
            typeIdentifier: UTType.png.identifier
        )
        let outcome = await AttachmentPaste.outcomeForProviders([provider])
        XCTAssertEqual(outcome.images.count, 1)
        XCTAssertTrue(outcome.errors.isEmpty)
    }

    func testFileProvidersKeepTheirNames() async throws {
        let dir = try scratchDirectory()
        let textURL = dir.appendingPathComponent("hello.py")
        try "print(\"hi\")".write(to: textURL, atomically: true, encoding: .utf8)
        // A drop or paste vends the file as a file-URL identifier, the way
        // Finder and Files copies arrive — and the real name survives.
        let provider = NSItemProvider(item: textURL as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let outcome = await AttachmentPaste.outcomeForProviders([provider])
        XCTAssertTrue(outcome.textInserts.first?.contains("```hello.py") ?? false)
        XCTAssertTrue(outcome.errors.isEmpty)
    }
}
