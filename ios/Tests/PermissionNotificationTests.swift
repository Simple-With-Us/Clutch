import XCTest
import UserNotifications
@testable import Clutch

final class PermissionNotificationTests: XCTestCase {
    private func payload() -> PermissionNotificationPayload {
        PermissionNotificationPayload(
            hostId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            sessionId: "session-7",
            engine: "muse",
            requestId: "perm-7",
            denyOptionId: "reject-once"
        )
    }

    // MARK: - The deep link

    func testALinkThatNamesAThreadOpensThatThread() throws {
        let url = try XCTUnwrap(URL(string: "clutch://thread/session-7"))
        let link = try XCTUnwrap(ThreadLink.parse(url))
        XCTAssertEqual(link.sessionId, "session-7")
        XCTAssertNil(link.hostId)
    }

    func testALinkThatNamesAHostCarriesIt() throws {
        let url = try XCTUnwrap(URL(string: "clutch://thread/session-7?host=11111111-2222-3333-4444-555555555555"))
        let link = try XCTUnwrap(ThreadLink.parse(url))
        XCTAssertEqual(link.sessionId, "session-7")
        XCTAssertEqual(link.hostId?.uuidString, "11111111-2222-3333-4444-555555555555")
    }

    func testAThreadLinkRoundTrips() throws {
        let hostId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        let url = try XCTUnwrap(ThreadLink.url(sessionId: "session 7", hostId: hostId))
        let link = try XCTUnwrap(ThreadLink.parse(url))
        XCTAssertEqual(link.sessionId, "session 7")
        XCTAssertEqual(link.hostId, hostId)
    }

    func testAPairingLinkIsNotAThreadLink() throws {
        // The pairing link owns the same scheme, and the two must not be
        // confused for one another.
        let url = try XCTUnwrap(URL(string: "clutch://pair?h=example.test&p=3180&t=token"))
        XCTAssertNil(ThreadLink.parse(url))
    }

    func testALinkThatNamesNothingIsNotAThreadLink() throws {
        let url = try XCTUnwrap(URL(string: "clutch://thread/"))
        XCTAssertNil(ThreadLink.parse(url))
    }

    // MARK: - The payload

    func testThePayloadCarriesIdentifiersOnly() {
        // The lock screen shows the thread's name and nothing else, so the
        // payload holds identifiers and never the request itself.
        XCTAssertEqual(
            Set(payload().userInfo.keys),
            ["hostId", "sessionId", "engine", "requestId", "denyOptionId"]
        )
    }

    func testThePayloadReadsBackWhatItCarried() {
        let carried = payload()
        let read = PermissionNotificationPayload(userInfo: carried.userInfo)
        XCTAssertEqual(read, carried)
    }

    func testAPayloadWithoutADenyOptionReadsBackWithoutOne() {
        var carried = payload()
        carried.denyOptionId = nil
        let read = PermissionNotificationPayload(userInfo: carried.userInfo)
        XCTAssertEqual(read?.denyOptionId, nil)
    }

    func testAPayloadIsOnlyMadeWhenTheAnswerHasSomewhereToGo() {
        // A request with no session id cannot be answered from a
        // notification, because the answer has nowhere to go.
        XCTAssertNil(PermissionNotificationPayload.make(hostId: UUID(), sessionId: nil, requestId: "perm-7", denyOptionId: "reject-once"))
        XCTAssertNil(PermissionNotificationPayload.make(hostId: UUID(), sessionId: "", requestId: "perm-7", denyOptionId: "reject-once"))
        XCTAssertNil(PermissionNotificationPayload.make(hostId: nil, sessionId: "session-7", requestId: "perm-7", denyOptionId: "reject-once"))
        XCTAssertNotNil(PermissionNotificationPayload.make(hostId: UUID(), sessionId: "session-7", requestId: "perm-7", denyOptionId: "reject-once"))
    }

    // MARK: - The notification

    func testThePermissionNotificationCarriesItsCategoryAndItsAction() {
        let content = TurnNotifier.permissionContent(threadTitle: "Fix the failing test", payload: payload())
        // The category is what gives the notification its Deny action.
        XCTAssertEqual(content.categoryIdentifier, TurnNotifier.permissionCategory)
        // An approval the owner cannot see coming is not worth waking for.
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
    }

    func testThePermissionNotificationNamesTheThreadAndNothingElse() {
        let request = AcpPermissionRequest(
            requestId: "perm-7",
            title: "Run rm -rf build",
            toolName: "bash",
            options: [AcpPermissionOption(optionId: "reject-once", kind: "reject_once", name: "Reject")],
            evidence: AcpPermissionEvidence(command: "rm -rf build")
        )
        let content = TurnNotifier.permissionContent(threadTitle: "Fix the failing test", payload: payload())
        // The lock screen gets the thread's name only:  no tool name, no
        // command, no path and no diff.
        XCTAssertEqual(content.body, "Fix the failing test")
        XCTAssertFalse(content.body.contains(request.toolName))
        XCTAssertFalse(content.body.contains("rm -rf"))
        XCTAssertFalse(content.body.contains(request.title))
        for value in content.userInfo.values {
            XCTAssertFalse((value as? String ?? "").contains("rm -rf"))
        }
    }

    func testThePermissionNotificationWithoutAPayloadCarriesNoActions() {
        // A request with nowhere to send an answer is a plain notification.
        let content = TurnNotifier.permissionContent(threadTitle: "Fix the failing test", payload: nil)
        XCTAssertTrue(content.categoryIdentifier.isEmpty)
        XCTAssertTrue(content.userInfo.isEmpty)
    }

    func testTheCategoryOffersDenyAndNotAllow() {
        // The lock screen cannot show the command, the path or the diff that
        // an informed allow needs, so it offers no Allow at all:  the only
        // action is Deny, and the tap opens the app.
        let category = TurnNotifier.permissionCategoryDefinition()
        XCTAssertEqual(category.identifier, TurnNotifier.permissionCategory)
        XCTAssertEqual(category.actions.map { $0.identifier }, [TurnNotifier.denyAction])
        XCTAssertEqual(category.actions.first?.title, "Deny")
    }

    // MARK: - The request

    func testARequestNamesTheOptionThatRefusesIt() {
        let request = AcpPermissionRequest(
            requestId: "perm-8",
            title: "Run a command",
            toolName: "bash",
            options: [
                AcpPermissionOption(optionId: "allow-once", kind: "allow_once", name: "Allow once"),
                AcpPermissionOption(optionId: "reject-once", kind: "reject_once", name: "Reject"),
            ]
        )
        XCTAssertEqual(request.denyOptionId, "reject-once")
    }

    func testARequestWithNoRefusalHasNoDenyOption() {
        // A deny then cancels the request, which is what a deny amounts to
        // when the engine offered no reject option of its own.
        let request = AcpPermissionRequest(
            requestId: "perm-9",
            title: "Run a command",
            toolName: "bash",
            options: [AcpPermissionOption(optionId: "allow-once", kind: "allow_once", name: "Allow once")]
        )
        XCTAssertNil(request.denyOptionId)
    }

    // MARK: - The engine the link names

    func testALinkCarriesTheEngineItNames() throws {
        let hostId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        let url = try XCTUnwrap(ThreadLink.url(sessionId: "session-7", hostId: hostId, engine: "muse"))

        let link = try XCTUnwrap(ThreadLink.parse(url))

        XCTAssertEqual(link.sessionId, "session-7")
        XCTAssertEqual(link.hostId, hostId)
        XCTAssertEqual(link.engine, "muse")
    }

    func testAnOlderLinkNamesNoEngine() throws {
        // A link written before the engine rode in it still opens.
        let url = try XCTUnwrap(
            URL(string: "clutch://thread/session-7?host=11111111-2222-3333-4444-555555555555")
        )

        let link = try XCTUnwrap(ThreadLink.parse(url))

        XCTAssertEqual(link.sessionId, "session-7")
        XCTAssertNil(link.engine)
    }

    func testALinkThatNamesAnEngineOpensItEvenWhenTheSidebarIsElsewhere() {
        // A Muse approval opens Muse while the sidebar stays on MiniMax
        // Code:  the destination carries its own engine and never borrows
        // the sidebar's.
        XCTAssertEqual(
            ThreadLink.resolveEngine(named: "muse", activityEngines: ["mcode", "muse"]),
            "muse"
        )
    }

    func testAnOlderLinkResolvesToTheOneEngineThatHasActivity() {
        XCTAssertEqual(ThreadLink.resolveEngine(named: nil, activityEngines: ["muse"]), "muse")
    }

    func testAnOlderLinkThatIsAmbiguousNamesNoEngine() {
        // Two engines carry the same raw id, and none carries it, so there
        // is nothing to resolve without guessing:  the surface keeps the
        // engine it is already showing.
        XCTAssertNil(ThreadLink.resolveEngine(named: nil, activityEngines: ["mcode", "muse"]))
        XCTAssertNil(ThreadLink.resolveEngine(named: nil, activityEngines: []))
    }

    func testALinkThatNamesAnEngineTheSidebarDoesNotOfferIsRefused() {
        // A link is untrusted input:  a crafted one must not be able to point
        // the session client at an engine the host never advertised.
        XCTAssertNil(
            ThreadLink.resolveEngine(
                named: "crafted",
                activityEngines: [],
                known: ["mcode", "muse"]
            )
        )
        XCTAssertEqual(
            ThreadLink.resolveEngine(named: "muse", activityEngines: [], known: ["mcode", "muse"]),
            "muse"
        )
    }

    func testALinkResolvesWhileTheEngineCatalogIsStillLoading() {
        // No catalog yet is not the same as no such engine:  refusing the
        // name before the host has said what it offers would break every
        // link during the first moment after launch.
        XCTAssertEqual(
            ThreadLink.resolveEngine(named: "muse", activityEngines: [], known: []),
            "muse"
        )
        XCTAssertEqual(
            ThreadLink.resolveEngine(named: "muse", activityEngines: [], known: nil),
            "muse"
        )
    }

    func testThePayloadCarriesTheEngineAndReadsItBack() throws {
        XCTAssertEqual(payload().userInfo["engine"], "muse")

        let read = try XCTUnwrap(PermissionNotificationPayload(userInfo: payload().userInfo))

        XCTAssertEqual(read.engine, "muse")
    }

    func testAPayloadFromBeforeTheEngineReadsBackWithoutOne() throws {
        let older: [String: String] = [
            "hostId": "11111111-2222-3333-4444-555555555555",
            "sessionId": "session-7",
            "requestId": "perm-7",
        ]

        let read = try XCTUnwrap(PermissionNotificationPayload(userInfo: older))

        XCTAssertNil(read.engine)
    }
}
