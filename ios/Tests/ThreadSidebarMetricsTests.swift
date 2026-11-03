import XCTest
@testable import Clutch

final class ThreadSidebarMetricsTests: XCTestCase {
    func testCumulativeTotalsDoNotBecomeContextOccupancy() {
        let usage = AcpSessionUsage(
            contextWindow: 1_000,
            inputTokens: 400,
            outputTokens: 100,
            totalTokens: 500,
            basis: "session-totals"
        )

        XCTAssertNil(ThreadMetricPresentation.contextOccupancyLabel(usage))
    }

    func testExplicitZeroContextIsDistinctFromUnreportedContext() {
        let unreported = AcpSessionUsage(
            contextWindow: 1_000,
            totalTokens: 0,
            basis: "latest-response"
        )
        let reportedZero = AcpSessionUsage(
            contextWindow: 1_000,
            totalTokens: 0,
            basis: "latest-response",
            contextUsedTokens: 0
        )

        XCTAssertNil(ThreadMetricPresentation.contextOccupancyLabel(unreported))
        XCTAssertEqual(ThreadMetricPresentation.contextOccupancyLabel(reportedZero), "0% · 0 / 1.0k")
    }

    func testResponseRateUsesOnlyWholeResponseMetric() {
        let intervalRateOnly = AcpSessionUsage(outputTokensPerSecond: 22)
        let wholeResponseRate = AcpSessionUsage(outputTokensPerSecond: 22, responseTokensPerSecond: 14.26)
        let invalidResponseRate = AcpSessionUsage(responseTokensPerSecond: .infinity)

        XCTAssertEqual(ThreadMetricPresentation.responseRateLabel(intervalRateOnly), "Not reported")
        XCTAssertEqual(ThreadMetricPresentation.responseRateLabel(wholeResponseRate), "14.3 tok/s")
        XCTAssertEqual(ThreadMetricPresentation.responseRateLabel(invalidResponseRate), "Not reported")
    }
}
