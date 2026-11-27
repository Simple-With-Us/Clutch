import XCTest
@testable import Clutch

/// Unsent composer text, kept per host and thread (C-155 batch 2).
final class DraftStoreTests: XCTestCase {
    private func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftStoreTests.\(UUID().uuidString)", isDirectory: true)
    }

    func testADraftRoundTripsPerHostAndThread() {
        let directory = freshDirectory()
        let hostA = UUID()
        let hostB = UUID()
        XCTAssertEqual(DraftStore.draft(hostId: hostA, sessionId: "s-1", in: directory), "")

        DraftStore.save("Fix the parser first", hostId: hostA, sessionId: "s-1", in: directory)
        DraftStore.save("Ship it", hostId: hostA, sessionId: "s-2", in: directory)
        DraftStore.save("Other host", hostId: hostB, sessionId: "s-1", in: directory)

        XCTAssertEqual(DraftStore.draft(hostId: hostA, sessionId: "s-1", in: directory), "Fix the parser first")
        XCTAssertEqual(DraftStore.draft(hostId: hostA, sessionId: "s-2", in: directory), "Ship it")
        XCTAssertEqual(DraftStore.draft(hostId: hostB, sessionId: "s-1", in: directory), "Other host")
    }

    func testClearingTheComposerForgetsTheDraft() {
        let directory = freshDirectory()
        let host = UUID()
        DraftStore.save("Words", hostId: host, sessionId: "s-1", in: directory)
        // Sending clears the composer; the same write clears the store.
        DraftStore.save("", hostId: host, sessionId: "s-1", in: directory)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "s-1", in: directory), "")
        DraftStore.save("Again", hostId: host, sessionId: "s-1", in: directory)
        DraftStore.save("   \n ", hostId: host, sessionId: "s-1", in: directory)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "s-1", in: directory), "")
    }

    func testALongDraftIsKeptWhole() {
        let directory = freshDirectory()
        let host = UUID()
        // A pasted file spliced into the composer must come back whole:
        // the store bounds count and age, never the words themselves.
        let long = String(repeating: "line of a pasted file\n", count: 12_000)
        DraftStore.save(long, hostId: host, sessionId: "s-1", in: directory)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "s-1", in: directory), long)
    }

    func testOldestDraftsGoFirstPastTheCap() {
        let directory = freshDirectory()
        let host = UUID()
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        for index in 0...(DraftStore.maxDrafts + 5) {
            DraftStore.save(
                "draft \(index)", hostId: host, sessionId: "s-\(index)", in: directory,
                now: start.addingTimeInterval(TimeInterval(index))
            )
        }
        // Reads run at the saves' own synthetic clock: the real one would
        // expire every 2001-dated draft before the assertions see it.
        let readNow = start.addingTimeInterval(10_000)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "s-0", in: directory, now: readNow), "")
        let newest = "s-\(DraftStore.maxDrafts + 5)"
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: newest, in: directory, now: readNow), "draft \(DraftStore.maxDrafts + 5)")
    }

    func testReaffirmingADraftKeepsItFromEvictingFirst() {
        let directory = freshDirectory()
        let host = UUID()
        let start = Date(timeIntervalSinceReferenceDate: 2_000_000)
        DraftStore.save("keep me", hostId: host, sessionId: "live", in: directory, now: start)
        for index in 0..<(DraftStore.maxDrafts - 1) {
            DraftStore.save(
                "filler \(index)", hostId: host, sessionId: "f-\(index)", in: directory,
                now: start.addingTimeInterval(TimeInterval(index + 1))
            )
        }
        // The same words saved again still count as use.
        let later = start.addingTimeInterval(10_000)
        DraftStore.save("keep me", hostId: host, sessionId: "live", in: directory, now: later)
        DraftStore.save("newcomer", hostId: host, sessionId: "new", in: directory, now: later.addingTimeInterval(1))
        let readNow = later.addingTimeInterval(2)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "live", in: directory, now: readNow), "keep me")
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "f-0", in: directory, now: readNow), "")
    }

    func testDraftsOlderThanAMonthAreForgotten() {
        let directory = freshDirectory()
        let host = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 5_000_000)
        DraftStore.save("stale", hostId: host, sessionId: "old", in: directory, now: now.addingTimeInterval(-DraftStore.maxAge - 1))
        DraftStore.save("fresh", hostId: host, sessionId: "new", in: directory, now: now)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "old", in: directory, now: now), "")
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "new", in: directory, now: now), "fresh")
    }

    func testAnExpiredDraftStaysForgottenOnReadAlone() {
        let directory = freshDirectory()
        let host = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 6_000_000)
        DraftStore.save("stale", hostId: host, sessionId: "old", in: directory, now: now)
        // No later save prunes it; the read itself must refuse it.
        let later = now.addingTimeInterval(DraftStore.maxAge + 60)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "old", in: directory, now: later), "")
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "old", in: directory, now: now), "stale")
    }

    func testExpiryPrunedByAnEmptySaveReachesTheFile() throws {
        let directory = freshDirectory()
        let host = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 7_000_000)
        DraftStore.save("stale", hostId: host, sessionId: "old", in: directory, now: now.addingTimeInterval(-DraftStore.maxAge - 1))
        // An empty save for a thread with no draft changes nothing of its
        // own, but the expiry it pruned must still reach the file.
        DraftStore.save("", hostId: host, sessionId: "never-existed", in: directory, now: now)
        let data = try Data(contentsOf: DraftStore.fileURL(in: directory))
        let table = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(table?.count, 0)
    }

    func testAClearedDraftCannotBeResurrectedByAStaleWrite() {
        let directory = freshDirectory()
        let host = UUID()
        DraftStore.save("sent words", hostId: host, sessionId: "s-1", in: directory, generation: 4)
        // Sending clears with the next generation; the generation is kept
        // after the clear precisely so this late write loses.
        DraftStore.save("", hostId: host, sessionId: "s-1", in: directory, generation: 5)
        DraftStore.save("sent words", hostId: host, sessionId: "s-1", in: directory, generation: 4)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "s-1", in: directory), "")
    }

    func testAnOlderGenerationCannotOverwriteANewerDraft() {
        let directory = freshDirectory()
        let host = UUID()
        DraftStore.save("newest", hostId: host, sessionId: "s-1", in: directory, generation: 7)
        // A debounced write launched before the newest edit lands late
        // and must lose, not resurrect the stale words.
        DraftStore.save("stale words", hostId: host, sessionId: "s-1", in: directory, generation: 3)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "s-1", in: directory), "newest")
        DraftStore.save("next", hostId: host, sessionId: "s-1", in: directory, generation: 8)
        XCTAssertEqual(DraftStore.draft(hostId: host, sessionId: "s-1", in: directory), "next")
    }
}
