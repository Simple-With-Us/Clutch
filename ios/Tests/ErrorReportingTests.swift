import XCTest
@testable import Clutch

/// Turn-failure report lines: what travels to telemetry when a turn fails.
///
/// The report carries the sidecar's safe display copy and the engine name
/// only.  Transport error descriptions can embed URLs, so only the error's
/// type name travels for those — these tests pin that boundary.
final class ErrorReportingTests: XCTestCase {
    struct FakeTransportError: Error {}

    func testEngineFailureKeepsEngineAndMessage() {
        XCTAssertEqual(
            ErrorReporting.turnMessage(engine: "muse", message: "Muse request failed (ACP code -32603)."),
            "[turn-failed engine=muse] Muse request failed (ACP code -32603)."
        )
    }

    func testTransportFailureKeepsTheTypeNotTheDescription() {
        let line = ErrorReporting.transportMessage(engine: "mcode", error: FakeTransportError())
        XCTAssertTrue(line.contains("mcode"))
        XCTAssertTrue(line.contains("FakeTransportError"))
    }

    func testRedactionStripsUrlsAndPaths() {
        XCTAssertEqual(
            ErrorReporting.redacted("fetch https://provider.example/v1/chat?key=abc failed"),
            "fetch [url] failed"
        )
        XCTAssertEqual(
            ErrorReporting.redacted("open /private/tmp/clutch/x failed"),
            "open [path] failed"
        )
    }

    func testRedactionLeavesSafeCopyAlone() {
        let safe = "Muse request failed (ACP code -32603)."
        XCTAssertEqual(ErrorReporting.redacted(safe), safe)
    }
}
