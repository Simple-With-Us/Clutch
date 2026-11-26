import XCTest
@testable import Clutch

final class ContextBreakdownTests: XCTestCase {
    func testSplitsUsedIntoInputCachedAndOutput() {
        let usage = AcpSessionUsage(
            contextWindow: 1_000_000,
            inputTokens: 500_000,
            outputTokens: 100_000,
            totalTokens: 610_000,
            cacheReadTokens: 200_000,
            contextUsedTokens: 610_000
        )
        let breakdown = usage.contextBreakdown
        XCTAssertEqual(breakdown?.usedTokens, 610_000)
        XCTAssertEqual(breakdown?.usedPercent, 61)
        XCTAssertEqual(breakdown?.segments.first(where: { $0.kind == .cached })?.tokens, 200_000)
        XCTAssertEqual(breakdown?.segments.first(where: { $0.kind == .output })?.tokens, 100_000)
        XCTAssertEqual(breakdown?.segments.first(where: { $0.kind == .input })?.tokens, 310_000)
        XCTAssertEqual(breakdown?.segments.first(where: { $0.kind == .free })?.tokens, 390_000)
    }

    func testClampsPartsToTheWindow() {
        let usage = AcpSessionUsage(
            contextWindow: 100,
            inputTokens: 500,
            outputTokens: 500,
            totalTokens: 900,
            cacheReadTokens: 800,
            contextUsedTokens: 900
        )
        let breakdown = usage.contextBreakdown
        XCTAssertEqual(breakdown?.usedTokens, 100)
        XCTAssertEqual(breakdown?.usedPercent, 100)
        XCTAssertEqual(breakdown?.segments.reduce(0) { $0 + $1.tokens }, 100)
    }

    func testNoWindowBuildsNothing() {
        let usage = AcpSessionUsage(inputTokens: 10, outputTokens: 5, totalTokens: 15)
        XCTAssertNil(usage.contextBreakdown)
    }

    func testSessionTotalsBasisBuildsNothing() {
        let usage = AcpSessionUsage(
            contextWindow: 1_000,
            inputTokens: 10,
            totalTokens: 10,
            basis: "session-totals"
        )
        XCTAssertNil(usage.contextBreakdown)
    }
}
