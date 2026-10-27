import XCTest
@testable import Clutch

/// The sidecar's file endpoints, as the native apps read them.
///
/// The web canvas shows the files of the folder a thread works in, and the
/// native apps ask the sidecar for the same thing.  These tests pin the
/// shapes, because a sidecar that answers differently is a client that
/// shows nothing.
final class FilesClientTests: XCTestCase {
    func testDecodesAFolderListing() throws {
        let payload = """
        {"path":"src","parent":"",
         "entries":[{"name":"main.ts","path":"src/main.ts","kind":"file","size":42},
                    {"name":"Views","path":"src/Views","kind":"directory"}]}
        """
        let listing = try JSONDecoder().decode(FilesClient.Listing.self, from: Data(payload.utf8))
        XCTAssertEqual(listing.path, "src")
        XCTAssertEqual(listing.parent, "")
        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertFalse(listing.entries[0].isDirectory)
        XCTAssertEqual(listing.entries[0].size, 42)
        XCTAssertTrue(listing.entries[1].isDirectory)
        XCTAssertNil(listing.entries[1].size)
    }

    func testDecodesAFilePreview() throws {
        let payload = """
        {"path":"README.md","name":"README.md","kind":"text","bytes":12,
         "truncated":false,"content":"# Clutch\\n"}
        """
        let preview = try JSONDecoder().decode(FilesClient.Preview.self, from: Data(payload.utf8))
        XCTAssertEqual(preview.name, "README.md")
        XCTAssertTrue(preview.isText)
        XCTAssertFalse(preview.truncated)
        XCTAssertEqual(preview.bytes, 12)
        XCTAssertTrue(preview.content.contains("# Clutch"))
    }

    func testAFileThatIsNotTextIsNotText() throws {
        let payload = """
        {"path":"picture.png","name":"picture.png","kind":"binary","bytes":8,
         "truncated":false,"content":""}
        """
        let preview = try JSONDecoder().decode(FilesClient.Preview.self, from: Data(payload.utf8))
        XCTAssertFalse(preview.isText)
        XCTAssertEqual(preview.content, "")
    }

    func testAListingWithNoEntriesIsEmptyRatherThanMissing() throws {
        let payload = """
        {"path":"","entries":[]}
        """
        let listing = try JSONDecoder().decode(FilesClient.Listing.self, from: Data(payload.utf8))
        XCTAssertEqual(listing.path, "")
        XCTAssertNil(listing.parent)
        XCTAssertTrue(listing.entries.isEmpty)
    }
}
