import XCTest
@testable import Clutch

final class AcpSessionTests: XCTestCase {
    func testDecodesSidecarSessionPayload() throws {
        let json = """
        {"sessions":[{"sessionId":"s-1","cwd":"/Users/jay/lanes/foo","title":"Fix the flaky test","updatedAt":"2026-10-16T09:41:07.412Z"}]}
        """
        struct Payload: Decodable { var sessions: [AcpSessionInfo] }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.sessions.count, 1)
        let session = try XCTUnwrap(payload.sessions.first)
        XCTAssertEqual(session.sessionId, "s-1")
        XCTAssertEqual(session.cwd, "/Users/jay/lanes/foo")
        XCTAssertEqual(session.title, "Fix the flaky test")
        XCTAssertEqual(session.id, "s-1")
        XCTAssertNotNil(session.updated)
    }

    func testDisplayTitleFallsBackToWorkspaceThenUntitled() {
        let titled = AcpSessionInfo(sessionId: "a", cwd: "/tmp/x", title: "Named")
        XCTAssertEqual(titled.displayTitle, "Named")

        let blankTitle = AcpSessionInfo(sessionId: "b", cwd: "/Users/jay/lanes/foo", title: "   ")
        XCTAssertEqual(blankTitle.displayTitle, "foo")

        let bare = AcpSessionInfo(sessionId: "c")
        XCTAssertEqual(bare.displayTitle, "Untitled Session")
    }

    func testUpdatedDateToleratesBothISO8601Forms() {
        let fractional = AcpSessionInfo.updatedDate("2026-10-16T09:41:07.412Z")
        let plain = AcpSessionInfo.updatedDate("2026-10-16T09:41:07Z")
        XCTAssertNotNil(fractional)
        XCTAssertNotNil(plain)
        // Both forms name the same wall-clock second, and the fractional one
        // simply carries the extra precision, so they land well inside a
        // second of each other rather than in different minutes or days.
        XCTAssertEqual(fractional?.timeIntervalSince1970 ?? 0, plain?.timeIntervalSince1970 ?? -1, accuracy: 1.0)
        XCTAssertNil(AcpSessionInfo.updatedDate(nil))
        XCTAssertNil(AcpSessionInfo.updatedDate(""))
        XCTAssertNil(AcpSessionInfo.updatedDate("not a date"))
    }

    func testHistoryVisibilityKeepsConversationAndDropsToolChatter() {
        func entry(_ kind: String) -> AcpHistoryEntry {
            AcpHistoryEntry(sessionId: "s", kind: kind, text: "t")
        }
        XCTAssertTrue(entry("user_message").isVisible)
        XCTAssertTrue(entry("assistant_message").isVisible)
        XCTAssertFalse(entry("tool_call").isVisible)
        XCTAssertFalse(entry("thought").isVisible)
        XCTAssertTrue(entry("user_message").isUser)
        XCTAssertFalse(entry("assistant_message").isUser)
    }

    /// The Mac rail and the iOS sidebar share this ordering, so a thread must
    /// land in the same slot on both platforms.
    func testNewestFirstOrdersDatedRowsAndSinksUnreadableStamps() {
        let old = AcpSessionInfo(sessionId: "old", updatedAt: "2026-10-15T09:00:00Z")
        let new = AcpSessionInfo(sessionId: "new", updatedAt: "2026-10-16T09:00:00Z")
        let brokenA = AcpSessionInfo(sessionId: "broken-a", updatedAt: "not a date")
        let brokenB = AcpSessionInfo(sessionId: "broken-b", updatedAt: nil)

        let ordered = AcpSessionInfo.newestFirst([old, brokenA, new, brokenB])
        XCTAssertEqual(ordered.map(\.sessionId), ["new", "old", "broken-a", "broken-b"])
    }

    /// Two rows sharing an instant must not swap places between reloads of the
    /// same payload, or the list flickers under the user's finger.
    func testNewestFirstIsStableForEqualInstants() {
        let stamp = "2026-10-16T09:00:00Z"
        let first = AcpSessionInfo(sessionId: "first", updatedAt: stamp)
        let second = AcpSessionInfo(sessionId: "second", updatedAt: stamp)
        let ordered = AcpSessionInfo.newestFirst([first, second])
        XCTAssertEqual(ordered.map(\.sessionId), ["first", "second"])
    }

    func testNewestFirstHandlesEmptyInput() {
        XCTAssertTrue(AcpSessionInfo.newestFirst([]).isEmpty)
    }
}
