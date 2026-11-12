import XCTest

/// Offline Chat-tab run: pairs via a deep link (no web server needed) and
/// screenshots the tab.
///
/// The stub answers the sidecar's health route but not its CometChat config,
/// so the gate opens, the Chat surface draws, and the surface then reports
/// its own trouble instead of spinning.  The artifact proves the
/// CometChat-linked build launches, pairs, renders the thread surface, and
/// says what is wrong.
///
/// The second run pairs with a chat port nothing listens on.  There the gate
/// is closed, and the app draws the "Cannot Reach" card instead of asking a
/// host that is not there.  Screenshots are kept as attachments named
/// `ios-<state>`.
final class ClutchChatTabUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stub: StubSidecar!

    override func setUpWithError() throws {
        continueAfterFailure = false
        stub = try StubSidecar()
        try stub.start()
        app = XCUIApplication()
        app.launchArguments = ["-ClutchResetHosts"]
    }

    override func tearDownWithError() throws {
        stub?.stop()
        app = nil
        stub = nil
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testChatTabShowsSetupStateWithoutCometChat() throws {
        app.launch()
        XCTAssertTrue(app.staticTexts["Pair With Clutch"].waitForExistence(timeout: 30))

        // The sidecar answers, so the gate opens and the Chat surface draws;
        // the CometChat config is the thing it cannot get.
        let link = try XCTUnwrap(URL(string:
            "clutch://pair?host=127.0.0.1&port=3180&chat=\(StubSidecar.chatToken)&chatPort=\(stub.port)"))
        app.open(link)

        let chatTab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 30))
        chatTab.tap()

        XCTAssertTrue(app.staticTexts["Chat Unavailable"].waitForExistence(timeout: 30))
        snap("ios-chat-unavailable")
    }

    func testASidecarThatIsNotThereShowsTheGateCard() throws {
        app.launch()
        XCTAssertTrue(app.staticTexts["Pair With Clutch"].waitForExistence(timeout: 30))

        // Nothing listens on this port, so the gate stays closed.
        let link = try XCTUnwrap(URL(string:
            "clutch://pair?host=127.0.0.1&port=3180&chat=\(StubSidecar.chatToken)&chatPort=3811"))
        app.open(link)

        let chatTab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 30))
        chatTab.tap()

        XCTAssertTrue(app.staticTexts["Try Again"].waitForExistence(timeout: 30))
        snap("ios-cannot-reach")
    }
}
