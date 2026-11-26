import XCTest
@testable import Clutch

/// The Live Activity's contract with the owner.
///
/// The tests here are about what the surfaces say.  The activity shows
/// without being opened, so the rule it has to keep is small and strict:
/// thread names and a status, and nothing about the request itself.
final class ClutchActivityTests: XCTestCase {
    // MARK: - The summary line

    func testSummaryNamesWhatIsWaitingAndWhatIsRunning() {
        XCTAssertEqual(ClutchActivitySummary.text(waiting: 2, running: 1), "2 Waiting, 1 Running")
    }

    func testSummaryNamesOnlyTheHalfThatIsHappening() {
        XCTAssertEqual(ClutchActivitySummary.text(waiting: 3, running: 0), "3 Waiting")
        XCTAssertEqual(ClutchActivitySummary.text(waiting: 0, running: 2), "2 Running")
    }

    func testSummarySaysAllQuietWhenNothingIsHappening() {
        XCTAssertEqual(ClutchActivitySummary.text(waiting: 0, running: 0), "All Quiet")
    }

    // MARK: - The published state

    func testStateCountsEveryApprovalEvenWhenOnlyThreeSessionsFit() {
        let waiting = (1...5).map {
            ClutchActivitySession(id: "s\($0)", title: "Thread \($0)", status: .waiting)
        }
        let state = ClutchActivityAttributes.ContentState(waiting: waiting, running: [])

        XCTAssertEqual(state.waitingCount, 5)
        XCTAssertEqual(state.sessions.count, 3)
    }

    func testStatePutsTheApprovalsBeforeTheRuns() {
        let waiting = [ClutchActivitySession(id: "w1", title: "Needs Me", status: .waiting)]
        let running = [ClutchActivitySession(id: "r1", title: "Working", status: .running)]
        let state = ClutchActivityAttributes.ContentState(waiting: waiting, running: running)

        XCTAssertEqual(state.sessions.map(\.title), ["Needs Me", "Working"])
        XCTAssertEqual(state.sessions.map(\.status), [.waiting, .running])
    }

    func testStateCarriesTitlesAndStatusesAndNothingElse() {
        // The state is what the lock screen renders, so the fields it has
        // are the fields the lock screen may show.  A tool name, a command
        // or a path has no field here to live in.
        let session = ClutchActivitySession(id: "s1", title: "Refactor The Parser", status: .waiting)
        let state = ClutchActivityAttributes.ContentState(
            waiting: [session],
            running: []
        )

        XCTAssertEqual(state.sessions.first?.title, "Refactor The Parser")
        XCTAssertEqual(state.sessions.first?.status, .waiting)
        let encoded = try? JSONEncoder().encode(state)
        let text = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(text.contains("bash"))
        XCTAssertFalse(text.contains("rm -rf"))
    }

    // MARK: - The state the host pushes

    func testTheStateCarriesTheTimestampAsSecondsSince2001() {
        // A pushed content-state is decoded by the system with its default
        // strategies, where a Date is seconds since 2001-01-01, so the app
        // writes exactly that:  no custom coding, the same shape the
        // system expects when it decodes the host's push.
        let state = ClutchActivityAttributes.ContentState(
            waitingCount: 1,
            runningCount: 0,
            sessions: [ClutchActivitySession(id: "s1", title: "Needs Me", status: .waiting)],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try? JSONEncoder().encode(state)
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        // 1_700_000_000 - 978_307_200:  the same moment on Apple's scale.
        XCTAssertTrue(text.contains("721692800"))
        let decoded = try? JSONDecoder().decode(ClutchActivityAttributes.ContentState.self, from: data ?? Data())
        XCTAssertEqual(decoded?.updatedAt.timeIntervalSince1970, 1_700_000_000)
    }

    func testTheStateReadsTheShapeTheHostPushes() {
        // The host writes the state as the system reads it:  the counts,
        // the sessions with their status, and the timestamp on Apple's
        // date scale (seconds since 2001), because that is the coding a
        // pushed content-state is decoded with.
        let json = """
        {"waitingCount":1,"runningCount":2,"sessions":[{"id":"s1","title":"Needs Me","status":"waiting"}],"updatedAt":721692800}
        """

        let decoded = try? JSONDecoder().decode(
            ClutchActivityAttributes.ContentState.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded?.waitingCount, 1)
        XCTAssertEqual(decoded?.runningCount, 2)
        XCTAssertEqual(decoded?.sessions.count, 1)
        XCTAssertEqual(decoded?.sessions.first?.id, "s1")
        XCTAssertEqual(decoded?.sessions.first?.status, .waiting)
        XCTAssertEqual(decoded?.updatedAt.timeIntervalSince1970, 1_700_000_000)
    }

    // MARK: - The waiting and the running work

    func testAThreadWaitingOnTheOwnerIsNotAlsoRunning() {
        // The turn has not ended while the approval is open, so the store
        // holds the thread in both lists.  Counting it twice would say
        // there is more work than there is, and the island would show it
        // twice.
        let hostId = UUID()
        let approval = TurnActivityApproval(hostId: hostId, engine: "mcode", sessionId: "s1", requestId: "r1", title: "Needs Me")
        let run = TurnActivityRun(hostId: hostId, engine: "mcode", sessionId: "s1", title: "Needs Me")

        let split = ClutchActivityWork.split(approvals: [approval], runs: [run])

        XCTAssertEqual(split.waiting.count, 1)
        XCTAssertTrue(split.running.isEmpty)
    }

    func testARunningThreadThatIsNotWaitingIsStillRunning() {
        let hostId = UUID()
        let run = TurnActivityRun(hostId: hostId, engine: "mcode", sessionId: "s2", title: "Working")

        let split = ClutchActivityWork.split(approvals: [], runs: [run])

        XCTAssertTrue(split.waiting.isEmpty)
        XCTAssertEqual(split.running.count, 1)
    }

    func testAThreadWaitingOnTwoRequestsIsOneThreadAndNotTwo() {
        // The engine can hold a session that waits on more than one request,
        // and the approval's own id carries the request:  the thread is
        // still one thread, the island shows it once, and the run that is
        // blocked behind it is not counted as running as well.
        let hostId = UUID()
        let first = TurnActivityApproval(hostId: hostId, engine: "mcode", sessionId: "s1", requestId: "r1", title: "Needs Me")
        let second = TurnActivityApproval(hostId: hostId, engine: "mcode", sessionId: "s1", requestId: "r2", title: "Needs Me")
        let run = TurnActivityRun(hostId: hostId, engine: "mcode", sessionId: "s1", title: "Needs Me")

        let split = ClutchActivityWork.split(approvals: [first, second], runs: [run])

        XCTAssertEqual(split.waiting.count, 1)
        XCTAssertTrue(split.running.isEmpty)
    }

    func testAThreadOnAnotherHostIsStillRunning() {
        // Two hosts can hold a session with the same id, and one host's
        // waiting thread is not the other host's running thread.
        let hostA = UUID()
        let hostB = UUID()
        let approval = TurnActivityApproval(hostId: hostA, engine: "mcode", sessionId: "s1", requestId: "r1", title: "Needs Me")
        let run = TurnActivityRun(hostId: hostB, engine: "mcode", sessionId: "s1", title: "Working")

        let split = ClutchActivityWork.split(approvals: [approval], runs: [run])

        XCTAssertEqual(split.waiting.count, 1)
        XCTAssertEqual(split.running.count, 1)
    }

    // MARK: - The shared count

    func testSnapshotRoundTripsThroughTheSharedContainer() {
        let suite = "codes.clutch.tests.snapshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("the test suite could not be created")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let snapshot = ClutchApprovalSnapshot(waitingCount: 2, runningCount: 1)
        ClutchSharedStore.write(snapshot, to: defaults)

        XCTAssertEqual(ClutchSharedStore.read(from: defaults), snapshot)
    }

    func testAnUnwrittenContainerReadsAsNothingWaiting() {
        let suite = "codes.clutch.tests.empty.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("the test suite could not be created")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ClutchSharedStore.read(from: defaults), .empty)
    }

    func testTheSharedContainerCarriesCountsAndNoTitles() {
        // The Lock Screen shows a number.  A thread title in the container
        // would be a thread title on a lock screen.
        let snapshot = ClutchApprovalSnapshot(waitingCount: 1, runningCount: 0)
        let data = try? JSONEncoder().encode(snapshot)
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        XCTAssertFalse(text.contains("title"))
        XCTAssertFalse(text.contains("tool"))
    }

    // MARK: - The link

    func testTheApprovalsLinkIsReadAndOtherLinksAreNot() {
        XCTAssertTrue(ClutchApprovalsLink.matches(ClutchApprovalsLink.url))
        XCTAssertFalse(ClutchApprovalsLink.matches(URL(string: "clutch://thread/abc")!))
        XCTAssertFalse(ClutchApprovalsLink.matches(URL(string: "https://clutch.codes/approvals")!))
    }

    @MainActor
    func testTheRouterTakesTheRequestOnce() {
        let router = ApprovalsLinkRouter()
        router.request()

        XCTAssertTrue(router.take())
        XCTAssertFalse(router.take())
    }

    // MARK: - Two engines, one host

    func testATwoEngineIdCollisionIsTwoThreadsInTheIsland() {
        // Muse and MiniMax Code both hold a session with this id.  The Muse
        // approval does not make the MiniMax Code turn look blocked.
        let hostId = UUID()
        let approval = TurnActivityApproval(
            hostId: hostId, engine: "muse", sessionId: "s1", requestId: "r1", title: "Muse"
        )
        let run = TurnActivityRun(
            hostId: hostId, engine: "mcode", sessionId: "s1", title: "MiniMax"
        )

        let split = ClutchActivityWork.split(approvals: [approval], runs: [run])

        XCTAssertEqual(split.waiting.count, 1)
        XCTAssertEqual(split.running.count, 1)
    }
}
