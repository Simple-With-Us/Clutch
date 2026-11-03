import XCTest
@testable import Clutch

final class MuseContextPolicyTests: XCTestCase {
    func testPreferencesDefaultOffClampThresholdAndStayHostScoped() throws {
        XCTAssertEqual(MuseContextPreferences.policy(hostKey: "host-a", preferencesJSON: nil), .defaultPolicy)
        XCTAssertFalse(MuseContextPolicy.defaultPolicy.autoCompact)
        XCTAssertEqual(MuseContextPolicy.defaultPolicy.thresholdPercent, 85)

        let encoded = MuseContextPreferences.setting(
            MuseContextPolicy(autoCompact: true, thresholdPercent: 120),
            hostKey: "host-a",
            preferencesJSON: nil
        )
        XCTAssertEqual(
            MuseContextPreferences.policy(hostKey: "host-a", preferencesJSON: encoded),
            MuseContextPolicy(autoCompact: true, thresholdPercent: 95)
        )
        let outOfRange = #"{"hosts":{"host-a":{"autoCompact":true,"thresholdPercent":120}}}"#
        XCTAssertEqual(
            MuseContextPreferences.policy(hostKey: "host-a", preferencesJSON: outOfRange),
            MuseContextPolicy(autoCompact: true, thresholdPercent: 95)
        )
        XCTAssertEqual(MuseContextPreferences.policy(hostKey: "host-a", preferencesJSON: "bad json"), .defaultPolicy)
        XCTAssertEqual(MuseContextPreferences.policy(hostKey: "host-b", preferencesJSON: encoded), .defaultPolicy)

        let lower = MuseContextPreferences.setting(
            MuseContextPolicy(autoCompact: true, thresholdPercent: 10),
            hostKey: "host-b",
            preferencesJSON: encoded
        )
        XCTAssertEqual(
            MuseContextPreferences.policy(hostKey: "host-b", preferencesJSON: lower),
            MuseContextPolicy(autoCompact: true, thresholdPercent: 50)
        )
        XCTAssertEqual(
            MuseContextPreferences.policy(hostKey: "host-a", preferencesJSON: lower),
            MuseContextPolicy(autoCompact: true, thresholdPercent: 95)
        )
    }

    func testContextPolicyIsSentOnlyForMuseRequests() throws {
        let host = ClutchHost(name: "Test Host", origin: try XCTUnwrap(URL(string: "https://example.test")))
        let policy = MuseContextPolicy(autoCompact: true, thresholdPercent: 73)
        let muse = ChatSessionClient(
            host: host,
            model: "muse-spark-1.3-contributor",
            relayReceiverUid: "",
            engine: "muse",
            contextPolicy: policy
        )
        let contextPolicyBody = try XCTUnwrap(
            muse.requestPayload(prompt: "hello")["contextPolicy"] as? [String: Any]
        )
        XCTAssertEqual(contextPolicyBody["autoCompact"] as? Bool, true)
        XCTAssertEqual(contextPolicyBody["thresholdPercent"] as? Int, 73)

        let other = ChatSessionClient(
            host: host,
            model: "",
            relayReceiverUid: "",
            engine: "mcode",
            contextPolicy: policy
        )
        XCTAssertNil(other.requestPayload(prompt: "hello")["contextPolicy"])
    }

    func testDecodesContextControlEventAndOccupancy() {
        let event = ChatSessionClient.decode(
            event: "context_controls",
            payload: #"{"supportsCompaction":true,"contextUsedTokens":700,"contextWindow":1000}"#
        )
        guard case .contextControls(let controls) = event else {
            return XCTFail("expected context controls, got \(String(describing: event))")
        }
        XCTAssertTrue(controls.supportsCompaction)
        XCTAssertEqual(controls.contextUsedTokens, 700)
        XCTAssertEqual(controls.contextWindow, 1000)
        XCTAssertEqual(controls.occupancyPercent ?? -1, 70, accuracy: 0.001)
        XCTAssertNil(ChatSessionClient.decode(event: "context_controls", payload: #"{"contextWindow":1000}"#))
    }
}
