import XCTest
import UniformTypeIdentifiers
@testable import Clutch

/// Clutch must answer a web page's file-input request with an in-app
/// `UIDocumentPicker`, and must never leave two of them open at once.  Both
/// properties live in `OpenPanelSession`, which is testable without a window.
@MainActor
final class OpenPanelSessionTests: XCTestCase {
    func testDirectoryRequestOffersFolders() {
        // "Choose workspace" arrives as a `webkitdirectory` input.
        XCTAssertEqual(OpenPanelSession.contentTypes(allowsDirectories: true), [.folder])
    }

    func testFileRequestOffersItems() {
        XCTAssertEqual(OpenPanelSession.contentTypes(allowsDirectories: false), [.item])
    }

    func testSecondRequestCancelsTheFirst() {
        let session = OpenPanelSession()
        var firstCalls = 0
        var firstURLs: [URL]? = []
        var secondCalls = 0

        session.begin { urls in firstCalls += 1; firstURLs = urls }
        session.begin { _ in secondCalls += 1 }

        XCTAssertEqual(firstCalls, 1, "the panel already open must be cancelled, not left hanging")
        XCTAssertNil(firstURLs, "a cancelled panel reports no selection")
        XCTAssertEqual(secondCalls, 0)

        session.finish(with: [URL(fileURLWithPath: "/tmp/workspace")])
        XCTAssertEqual(secondCalls, 1)
    }

    func testFinishFiresAtMostOnce() {
        // WebKit must get exactly one result per request, or it waits forever.
        let session = OpenPanelSession()
        var calls = 0
        session.begin { _ in calls += 1 }

        session.finish(with: [URL(fileURLWithPath: "/tmp/a")])
        session.finish(with: nil)

        XCTAssertEqual(calls, 1)
        XCTAssertFalse(session.isActive)
    }

    func testFinishWithoutAnOpenRequestIsHarmless() {
        let session = OpenPanelSession()
        session.finish(with: [URL(fileURLWithPath: "/tmp/a")])
        XCTAssertFalse(session.isActive)
    }
}