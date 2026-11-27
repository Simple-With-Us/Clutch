import XCTest
@testable import Clutch

/// Unsent composer text, kept per host and thread (C-155 batch 2).
final class DraftStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "DraftStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testADraftRoundTripsPerHostAndThread() {
        let defaults = freshDefaults()
        let hostA = UUID()
        let hostB = UUID()
        XCTAssertEqual(DraftStore.draft(hostId: hostA, sessionId: "s-1", in: defaults), "")

        DraftStore.save("Fix the parser first", hostId: hostA, sessionId: "s-1", in: defaults)
        DraftStore.save("Ship it", hostId: hostA, sessionId: "s-2", in: defaults)
        DraftStore.save("Other host", hostId: hostB, sessionId: "s-1", in: defaults)

        XCTAssertEqual(DraftStore.draft(hostId: hostA, sessionId: "s-1", in: defaults), "Fix the parser first")
        XCTAssertEqual(DraftStore.draft(hostId: hostA, sessionId: "s-2", in: defaults), "Ship it")
        XCTAssertEqual(DraftStore.draft(hostId: hostB, sessionId: "s-1", in: defaults), "Other host")
    }

    func testClearingTheComposerForgetsTheDraft() {
        let defaults = freshDefaults()
        let host = UUID()
        DraftStore.save("Words", hostId: host, sessionId: "s-1", in: defaults)
        // Sending clears the composer; the same write clears the store.
        DraftStore.save("", hostId: host, sessionId: "s-1", in: defaults)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "s-1", in: defaults), "")
        DraftStore.save("Again", hostId: host, sessionId: "s-1", in: defaults)
        DraftStore.save("   \n ", hostId: host, sessionId: "s-1", in: defaults)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "s-1", in: defaults), "")
    }

    func testAnOverlongDraftIsTrimmedToTheCap() {
        let defaults = freshDefaults()
        let host = UUID()
        let long = String(repeating: "x", count: DraftStore.maxDraftLength + 500)
        DraftStore.save(long, hostId: host, sessionId: "s-1", in: defaults)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "s-1", in: defaults).count, DraftStore.maxDraftLength)
    }

    func testOldestDraftsGoFirstPastTheCap() {
        let defaults = freshDefaults()
        let host = UUID()
        for index in 0...(DraftStore.maxDrafts + 5) {
            DraftStore.save("draft \(index)", hostId: host, sessionId: "s-\(index)", in: defaults)
        }
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "s-0", in: defaults), "")
        let newest = "s-\(DraftStore.maxDrafts + 5)"
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: newest, in: defaults), "draft \(DraftStore.maxDrafts + 5)")
    }
}
