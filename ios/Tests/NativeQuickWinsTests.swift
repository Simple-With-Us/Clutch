import XCTest
@testable import Clutch

/// The first native quick-wins batch (C-155): bounded streams, honest
/// telemetry environments, and widget freshness.
final class NativeQuickWinsTests: XCTestCase {
    func testAStreamInboxIsBoundedAndCountsWhatItDropped() {
        let stream = DshHostStream(id: "s", endpoint: "session/follow")
        let appended = DshHostStream.maxInboxItems + 25
        for index in 0..<appended {
            stream.append(.number(Double(index)))
        }
        // Eviction drops to half the cap in one shift at the first frame
        // over it, so the accounting is dropped plus held equals sent.
        let half = DshHostStream.maxInboxItems / 2
        XCTAssertEqual(stream.items.count, half + 24)
        XCTAssertEqual(stream.droppedCount, appended - stream.items.count)
        XCTAssertLessThanOrEqual(stream.items.count, DshHostStream.maxInboxItems)
        // The oldest frames went first; the newest are still there.
        XCTAssertEqual(stream.items.first, .number(Double(stream.droppedCount)))
        XCTAssertEqual(stream.items.last, .number(Double(appended - 1)))
        // A reader that keeps up loses nothing more.
        XCTAssertEqual(stream.take().count, half + 24)
        XCTAssertTrue(stream.items.isEmpty)
    }

    func testApprovalSnapshotSpeaksItsCountsAndFreshness() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let fresh = ClutchApprovalSnapshot(waitingCount: 2, runningCount: 1, updatedAt: now)
        XCTAssertFalse(fresh.isStale(now: now))
        XCTAssertEqual(fresh.accessibilitySummary(now: now), "2 approvals waiting, 1 running")

        let quiet = ClutchApprovalSnapshot(waitingCount: 0, runningCount: 0, updatedAt: now)
        XCTAssertEqual(quiet.accessibilitySummary(now: now), "No approvals waiting")

        // Past the timeline backstop the count stops presenting as fact.
        let later = now.addingTimeInterval(ClutchApprovalSnapshot.staleAfter + 1)
        XCTAssertTrue(fresh.isStale(now: later))
        XCTAssertTrue(fresh.accessibilitySummary(now: later).hasSuffix("may be out of date"))
        XCTAssertTrue(ClutchApprovalSnapshot.empty.isStale(now: now))
    }

    func testSentryEnvironmentSplitsBuildStreams() {
        XCTAssertEqual(
            SentryTelemetry.environmentName(isDebug: true, receiptLastPathComponent: "receipt"),
            "development"
        )
        XCTAssertEqual(
            SentryTelemetry.environmentName(isDebug: false, receiptLastPathComponent: "sandboxReceipt"),
            "testflight"
        )
        XCTAssertEqual(
            SentryTelemetry.environmentName(isDebug: false, receiptLastPathComponent: "receipt"),
            "production"
        )
        XCTAssertEqual(
            SentryTelemetry.environmentName(isDebug: false, receiptLastPathComponent: nil),
            "production"
        )
    }
}
