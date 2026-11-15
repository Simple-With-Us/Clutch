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

    func testUsageStripIsShownForZCode() {
        let usage = AcpSessionUsage(responseTokensPerSecond: 27.6)

        XCTAssertTrue(ThreadMetricPresentation.showsUsageStrip(engineID: "zcode"))
        XCTAssertEqual(ThreadMetricPresentation.usageStripRateLabel(engineID: "zcode", usage: usage), "Response 27.6 tok/s")
    }

    func testUsageStripIsShownForTheEnginesThatReportUsage() {
        XCTAssertTrue(ThreadMetricPresentation.showsUsageStrip(engineID: "mcode"))
        XCTAssertTrue(ThreadMetricPresentation.showsUsageStrip(engineID: "muse"))
    }

    func testUsageStripIsNotShownForAnEngineThatNeverReportsUsage() {
        XCTAssertFalse(ThreadMetricPresentation.showsUsageStrip(engineID: "deepseek"))
        XCTAssertFalse(ThreadMetricPresentation.showsUsageStrip(engineID: "minimax"))
    }

    func testUsageStripRowRendersForMuseAsWellAsMiniMaxCode() {
        // The Mac header renders the strip row under this same predicate, so
        // Muse threads get the strip the metrics work always intended for
        // them, and Z Code threads get it too.
        XCTAssertTrue(ThreadMetricPresentation.showsUsageStrip(engineID: "muse"))
        XCTAssertTrue(ThreadMetricPresentation.showsUsageStrip(engineID: "mcode"))
        XCTAssertTrue(ThreadMetricPresentation.showsUsageStrip(engineID: "zcode"))
    }

    func testZCodeOccupancyStaysAbsentWithoutAContextWindow() {
        // Z Code's log carries no window, so the strip shows the rate and no
        // percentage, rather than a guessed one.
        let usage = AcpSessionUsage(
            inputTokens: 699_542,
            outputTokens: 424,
            totalTokens: 699_966,
            basis: "latest-response",
            responseTokensPerSecond: 30.8
        )

        XCTAssertNil(usage.contextUsedPercent)
        XCTAssertNil(ThreadMetricPresentation.contextOccupancyLabel(usage))
        XCTAssertEqual(ThreadMetricPresentation.usageStripRateLabel(engineID: "zcode", usage: usage), "Response 30.8 tok/s")
    }
}
