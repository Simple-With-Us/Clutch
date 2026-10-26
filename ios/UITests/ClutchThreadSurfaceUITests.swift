import XCTest

/// The thread surfaces, exercised against a local stub sidecar.
///
/// The stub answers the sidecar's own routes (health, engines, sessions,
/// load, chat), so the app's real code path runs: the Workspace tab lists the
/// stub's threads, a thread replays the stub's history, and the find bar
/// highlights a match inside it.  Screenshots are kept as attachments named
/// `ios-<state>`, which is the visual evidence the review rules ask for.
final class ClutchThreadSurfaceUITests: XCTestCase {
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

    /// The on-screen tree, so a failure says what was actually there.
    private func dump(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
    }

    func testFindInThreadShowsMatches() throws {
        // The find bar opens with the query already in it: the simulator's
        // keyboard is not dependable in CI, and the point of this test is
        // the highlighted match, not the typing.
        app.launchArguments = ["-ClutchResetHosts", "-ClutchShowFind", "1", "-ClutchFindText", "login"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Pair With Clutch"].waitForExistence(timeout: 30))

        // Pair with the stub: the chat token is what the sidecar expects, and
        // the chat port is where the stub listens.
        let link = try XCTUnwrap(URL(string:
            "clutch://pair?h=127.0.0.1&tls=0&kind=mcode&chat=\(StubSidecar.chatToken)&chatPort=\(stub.port)"))
        app.open(link)

        let workspaceTab = app.tabBars.buttons["Workspace"]
        XCTAssertTrue(workspaceTab.waitForExistence(timeout: 30))
        workspaceTab.tap()
        snap("ios-workspace-threads")

        // Open the stub's one thread.
        let thread = app.staticTexts["Fix The Login Redirect"]
        if !thread.waitForExistence(timeout: 30) {
            snap("ios-workspace-threads-missing")
            dump("ios-workspace-threads-tree")
            XCTFail("the stub's thread did not appear in the Workspace tab")
        }
        thread.tap()
        snap("ios-thread-open")

        // The find bar is open with the query in it, and the match count is
        // the bar's own feedback that the search ran.  Only one stub message
        // mentions "login", so the count is exactly one.
        XCTAssertTrue(app.staticTexts["1 match"].waitForExistence(timeout: 30))
        snap("ios-find-match")
    }
}
