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

    func testUsageStripUsesWholeResponseRateForMuse() {
        let usage = AcpSessionUsage(outputTokensPerSecond: 22, responseTokensPerSecond: 14.26)

        XCTAssertEqual(ThreadMetricPresentation.usageStripRateLabel(engineID: "muse", usage: usage), "Response 14.3 tok/s")
    }

    func testUsageStripUsesIntervalRateFallbackForMcode() {
        let intervalRateOnly = AcpSessionUsage(outputTokensPerSecond: 22)

        XCTAssertEqual(ThreadMetricPresentation.usageStripRateLabel(engineID: "mcode", usage: intervalRateOnly), "Interval 22.0 tok/s")
    }

    func testUsageStripDoesNotInventOrMislabelMissingRates() {
        XCTAssertNil(ThreadMetricPresentation.usageStripRateLabel(engineID: "mcode", usage: nil))
        XCTAssertNil(ThreadMetricPresentation.usageStripRateLabel(engineID: "mcode", usage: AcpSessionUsage()))
        XCTAssertNil(ThreadMetricPresentation.usageStripRateLabel(engineID: "muse", usage: AcpSessionUsage(outputTokensPerSecond: 22)))
        XCTAssertNil(ThreadMetricPresentation.usageStripRateLabel(engineID: "mcode", usage: AcpSessionUsage(outputTokensPerSecond: .infinity)))
    }

    func testUsageStripPrefersWholeResponseRateWhenBothArePresent() {
        let usage = AcpSessionUsage(outputTokensPerSecond: 22, responseTokensPerSecond: 14.26)

        XCTAssertEqual(ThreadMetricPresentation.usageStripRateLabel(engineID: "mcode", usage: usage), "Response 14.3 tok/s")
    }

    func testUsageStripFallsBackToValidMcodeIntervalWhenResponseRateIsInvalid() {
        let usage = AcpSessionUsage(outputTokensPerSecond: 22, responseTokensPerSecond: .infinity)

        XCTAssertEqual(ThreadMetricPresentation.usageStripRateLabel(engineID: "mcode", usage: usage), "Interval 22.0 tok/s")
    }
}
