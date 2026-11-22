import XCTest
@testable import Clutch

final class SteerFailureTests: XCTestCase {
    func testMissingTokenAndBadHostNeverReachedTheSidecar() {
        XCTAssertTrue(SteerFailure.failedBeforeSend(ChatClientError.missingToken))
        XCTAssertTrue(SteerFailure.failedBeforeSend(ChatClientError.badHost))
    }

    func testRefusedSteerNeverInjectedTheText() {
        XCTAssertTrue(SteerFailure.failedBeforeSend(ChatClientError.steerRejected("Muse has no active turn to steer.")))
    }

    func testAnswerThatIsNotHTTPLeavesTheOutcomeUnknown() {
        XCTAssertFalse(SteerFailure.failedBeforeSend(ChatClientError.http(-1)))
    }

    func testTimeoutAndLostConnectionLeaveTheOutcomeUnknown() {
        XCTAssertFalse(SteerFailure.failedBeforeSend(URLError(.timedOut)))
        XCTAssertFalse(SteerFailure.failedBeforeSend(URLError(.networkConnectionLost)))
        XCTAssertFalse(SteerFailure.failedBeforeSend(URLError(.cancelled)))
    }

    func testUnreadableAnswerLeavesTheOutcomeUnknown() {
        XCTAssertFalse(SteerFailure.failedBeforeSend(URLError(.cannotParseResponse)))
    }

    func testFailuresBeforeTheRequestLeftPutTheTextBack() {
        XCTAssertTrue(SteerFailure.failedBeforeSend(URLError(.cannotFindHost)))
        XCTAssertTrue(SteerFailure.failedBeforeSend(URLError(.cannotConnectToHost)))
        XCTAssertTrue(SteerFailure.failedBeforeSend(URLError(.notConnectedToInternet)))
        XCTAssertTrue(SteerFailure.failedBeforeSend(URLError(.secureConnectionFailed)))
    }

    func testUnknownErrorIsTreatedAsOneThatNeverLeft() {
        struct Boom: Error {}
        XCTAssertTrue(SteerFailure.failedBeforeSend(Boom()))
    }
}
