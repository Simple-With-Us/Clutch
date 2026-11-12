import XCTest
@testable import Clutch

/// The dsh host's mux frames, and the argument envelope the host insists on.
///
/// The host's Typert descriptors put an endpoint's business object under one
/// wire key, and the gateway refuses an argument set that does not match the
/// descriptor exactly.  The client puts the business object under that key
/// itself, so a caller cannot get it wrong, and these tests pin the envelope
/// per endpoint and the frames the client reads off the mux.
final class DshHostMuxTests: XCTestCase {
    // MARK: - The argument envelope

    func testTheListRidesItsOwnRequestKey() {
        let args = DshHostContract.envelope(endpoint: DshHostContract.sessionListEndpoint, args: [:])
        XCTAssertEqual(args, ["_request": .object([:])])
    }

    func testEveryOtherSessionEndpointRidesTheRequestKey() {
        let endpoints = [
            DshHostContract.sessionCreateEndpoint,
            DshHostContract.sessionSelectModelEndpoint,
            DshHostContract.sessionPromptEndpoint,
            DshHostContract.sessionFollowEndpoint,
            DshHostContract.sessionPageEndpoint,
        ]
        for endpoint in endpoints {
            let args = DshHostContract.envelope(endpoint: endpoint, args: ["cwd": .string("/work")])
            XCTAssertEqual(args, ["request": .object(["cwd": .string("/work")])])
        }
    }

    func testAnEndpointWithNoKnownKeyTakesItsArgumentsFlat() {
        let args = DshHostContract.envelope(endpoint: "commands/list", args: ["a": .number(1)])
        XCTAssertEqual(args, ["a": .number(1)])
    }

    func testTheFollowRequestRidesTheRequestKey() {
        let request = SessionFollowRequest(
            address: SessionAddress(sessionId: "session-1"),
            maxMessages: 200
        )
        let args = DshHostContract.envelope(
            endpoint: DshHostContract.sessionFollowEndpoint,
            args: request.arguments
        )
        let envelope = args["request"]
        XCTAssertNotNil(envelope)
        let inner = request.arguments
        let address = DshJSONValue.encoded(SessionAddress(sessionId: "session-1"))
        XCTAssertEqual(inner["address"], address)
        XCTAssertEqual(inner["maxMessages"], DshJSONValue.number(200))
    }

    // MARK: - The endpoint rule

    func testTheEndpointRuleTakesTheHostsSegments() {
        XCTAssertTrue(DshHostContract.isValidEndpoint("session/list"))
        XCTAssertTrue(DshHostContract.isValidEndpoint("$events/result"))
        XCTAssertTrue(DshHostContract.isValidEndpoint("workspaceFiles/list"))
        XCTAssertFalse(DshHostContract.isValidEndpoint(""))
        XCTAssertFalse(DshHostContract.isValidEndpoint("session//list"))
        XCTAssertFalse(DshHostContract.isValidEndpoint("session/../list"))
        XCTAssertFalse(DshHostContract.isValidEndpoint("session/li st"))
    }

    // MARK: - JSON values

    func testANumberIsNotABoolean() throws {
        let one = try JSONDecoder().decode(DshJSONValue.self, from: Data("1".utf8))
        XCTAssertEqual(one, .number(1))
        let yes = try JSONDecoder().decode(DshJSONValue.self, from: Data("true".utf8))
        XCTAssertEqual(yes, .bool(true))
    }

    // MARK: - Failures

    func testAFailureWithNullDetailsDecodes() throws {
        let json = #"{"code":"gateway/arguments-invalid","message":"bad arguments","details":null}"#
        let error = try JSONDecoder().decode(DshHostRpcError.self, from: Data(json.utf8))
        XCTAssertEqual(error.code, "gateway/arguments-invalid")
        XCTAssertEqual(error.message, "bad arguments")
        XCTAssertEqual(error.details, [:])
    }

    func testAFailureWithNoDetailsKeyDecodes() throws {
        let json = #"{"code":"unknown","message":"no details here"}"#
        let error = try JSONDecoder().decode(DshHostRpcError.self, from: Data(json.utf8))
        XCTAssertEqual(error.details, [:])
    }

    // MARK: - The frames

    func testTheReadyFrameNamesTheClient() throws {
        let json = #"{"type":"ready","clientId":"client-1","host":{"home":"/work"}}"#
        let value = try JSONDecoder().decode(DshJSONValue.self, from: Data(json.utf8))
        let ready = try XCTUnwrap(DshHostReadyFrame(value: value))
        XCTAssertEqual(ready.clientId, "client-1")
        XCTAssertEqual(ready.host?.home, "/work")
    }

    func testAValueThatIsNotAReadyFrameIsNotOne() throws {
        let json = #"{"type":"waterfall","event":"approval/request","eventId":"event-1"}"#
        let value = try JSONDecoder().decode(DshJSONValue.self, from: Data(json.utf8))
        XCTAssertNil(DshHostReadyFrame(value: value))
    }

    func testAWaterfallFrameCarriesTheEventId() throws {
        let json = #"{"type":"waterfall","event":"approval/request","eventId":"event-1","agentId":"session-7","request":{"toolName":"bash"}}"#
        let value = try JSONDecoder().decode(DshJSONValue.self, from: Data(json.utf8))
        let waterfall = try XCTUnwrap(DshHostWaterfallFrame(value: value))
        XCTAssertEqual(waterfall.event, "approval/request")
        XCTAssertEqual(waterfall.eventId, "event-1")
        XCTAssertEqual(waterfall.agentId, "session-7")
    }

    func testAFollowSnapshotCarriesItsRecords() throws {
        let json = #"{"type":"snapshot","header":{},"cursor":null,"records":[{"type":"event","event":{"type":"user/message","seq":1,"time":2,"data":{"content":[]}}}],"hasMore":false}"#
        let value = try JSONDecoder().decode(DshJSONValue.self, from: Data(json.utf8))
        let data = try JSONEncoder().encode(value)
        let frame = try JSONDecoder().decode(SessionFollowFrame.self, from: data)
        XCTAssertTrue(frame.isSnapshot)
        XCTAssertEqual(frame.records?.count, 1)
        XCTAssertEqual(frame.records?.first?.event?.type, "user/message")
        XCTAssertEqual(frame.records?.first?.event?.seq, 1)
    }

    func testABareEventIsTheSessionEventItself() throws {
        let json = #"{"type":"user/message","seq":7,"time":8,"data":{"content":[]}}"#
        let data = Data(json.utf8)
        let frame = try JSONDecoder().decode(SessionFollowFrame.self, from: data)
        XCTAssertFalse(frame.isSnapshot)
        XCTAssertEqual(frame.sessionEvent?.type, "user/message")
        XCTAssertEqual(frame.sessionEvent?.seq, 7)
    }

    func testTheRefusalAnswerSaysItIsARejection() throws {
        let outcome = DshHostEventOutcome(kind: .rejected, reason: "not yet")
        let data = try JSONEncoder().encode(outcome)
        let decoded = try JSONDecoder().decode(DshJSONValue.self, from: data)
        // The answer carries the kind and the reason, and nothing else.
        XCTAssertEqual(decoded, .object([
            "kind": .string("rejected"),
            "reason": .string("not yet"),
        ]))
    }
}
