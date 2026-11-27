import XCTest
@testable import Clutch

/// The gate that decides whether the native app can talk to the active host.
///
/// The web canvas used to draw this state from the web origin's auth wall.
/// The native apps ask the sidecar, so the gate is the sidecar's own answer.
final class HostGateTests: XCTestCase {
    func testAcceptedHealthAnswerIsReady() {
        XCTAssertEqual(HostGate.classify(status: 200), .ready)
        XCTAssertTrue(HostGate.classify(status: 200).isReady)
    }

    func testRefusedTokenNeedsPairing() {
        XCTAssertEqual(HostGate.classify(status: 401), .needsPairing)
        XCTAssertEqual(HostGate.classify(status: 403), .needsPairing)
    }

    func testAnyOtherAnswerIsLeftToTheSurfaces() {
        // The sidecar answered, so the app shows what went wrong there
        // rather than a gate card over it.
        XCTAssertEqual(HostGate.classify(status: 404), .ready)
    }

    func testABrokenSidecarReadsAsUnreachableNotReady() {
        // A 5xx is the sidecar speaking but failing: green at the gate
        // would send every surface into its own opaque error instead.
        guard case .unreachable(let reason500) = HostGate.classify(status: 500) else {
            return XCTFail("expected 500 to read as unreachable")
        }
        XCTAssertTrue(reason500.contains("500"))
        guard case .unreachable = HostGate.classify(status: 503) else {
            return XCTFail("expected 503 to read as unreachable")
        }
        XCTAssertFalse(HostGate.classify(status: 500).isReady)
        XCTAssertEqual(HostGate.classify(status: 500).pickerStatus, .offline)
    }

    func testThePickerFollowsTheGateRatherThanTheProbe() {
        // The probe reads an auth wall as "online", so a host that is
        // running but has dropped this device's token would say green.  The
        // gate knows better, and the picker has to show it.
        XCTAssertNil(HostGateState.ready.pickerStatus)
        XCTAssertEqual(HostGateState.needsPairing.pickerStatus, .notClutch)
        XCTAssertEqual(HostGateState.unreachable("no route to host").pickerStatus, .offline)
    }

    func testHostWithoutATokenNeedsPairing() async {
        let host = ClutchHost(name: "Mac", origin: URL(string: "http://127.0.0.1:3180")!, chatToken: nil)
        let state = await HostGate.check(host: host)
        XCTAssertEqual(state, .needsPairing)
    }

    func testHostWithAnEmptyTokenNeedsPairing() async {
        let host = ClutchHost(name: "Mac", origin: URL(string: "http://127.0.0.1:3180")!, chatToken: "")
        let state = await HostGate.check(host: host)
        XCTAssertEqual(state, .needsPairing)
    }

    func testUnreachableHostIsNotReady() async {
        // Nothing is listening on this port, so the gate cannot ask.
        let host = ClutchHost(
            name: "Mac",
            origin: URL(string: "http://127.0.0.1:3180")!,
            chatToken: "chat-one",
            chatPort: 1
        )
        let state = await HostGate.check(host: host, timeout: 2)
        guard case .unreachable = state else {
            return XCTFail("expected an unreachable host, got \(state)")
        }
    }
}
