import XCTest

/// Offline Chat-tab run: pairs via a deep link (no web server needed) and
/// screenshots the tab.  The fake host carries a chat token but nothing
/// listens on its chat port, so the tab lands in its "Chat Unavailable"
/// setup state — the artifact proves the CometChat-linked build launches,
/// pairs, renders the thread surface, and reports sidecar trouble instead
/// of spinning.  Screenshots are kept as attachments named `ios-<state>`.
final class ClutchChatTabUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ClutchResetHosts"]
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testChatTabShowsSetupStateWithoutSidecar() throws {
        app.launch()
        XCTAssertTrue(app.staticTexts["Pair With Clutch"].waitForExistence(timeout: 30))

        let link = try XCTUnwrap(URL(string:
            "clutch://pair?host=127.0.0.1&port=3180&chat=ui-test-token&chatPort=3811"))
        app.open(link)

        let chatTab = app.tabBars.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 30))
        chatTab.tap()

        XCTAssertTrue(app.staticTexts["Chat Unavailable"].waitForExistence(timeout: 30))
        snap("ios-chat-unavailable")
    }
}
