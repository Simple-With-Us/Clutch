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

        // The home list is the root surface; the thread list needs no tab
        // tap anymore.
        snap("ios-workspace-threads")
        try assertSnapshot("ios-workspace-threads", of: app.windows.firstMatch)

        // Open the stub's one thread.  The row is a selection-driven List
        // row whose combined element carries the thread's name and button
        // semantics, so the query targets that element, not a bare text.
        let thread = app.buttons["Thread, Fix The Login Redirect"].firstMatch
        if !thread.waitForExistence(timeout: 30) {
            snap("ios-workspace-threads-missing")
            dump("ios-workspace-threads-tree")
            XCTFail("the stub's thread did not appear in the Workspace tab")
        }
        thread.tap()
        snap("ios-thread-open")
        try assertSnapshot("ios-thread-open", of: app.windows.firstMatch)

        // The find bar is open with the query in it, and the position label
        // ("1 of 1") is the bar's own feedback that the search ran and can
        // be navigated.  Only one stub message mentions "login", so the
        // position is exactly one.
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 30))
        snap("ios-find-match")
        try assertSnapshot("ios-find-match", of: app.windows.firstMatch)
    }

    func testProjectCombinesThreadsFromDifferentHostsAndCodingTools() throws {
        let mac = StubSidecar(projectEngine: "mcode")
        let server = StubSidecar(projectEngine: "muse")
        try mac.start()
        defer { mac.stop() }
        try server.start()
        defer { server.stop() }

        func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            let control = app.descendants(matching: .any).matching(identifier: label).firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 20), label, file: file, line: line)
            control.tap()
        }

        func pair(_ host: StubSidecar, name: String) throws {
            let link = try XCTUnwrap(URL(string:
                "clutch://pair?h=127.0.0.1&tls=0&kind=mcode&name=\(name)&chat=\(StubSidecar.chatToken)&chatPort=\(host.port)"))
            app.open(link)
            XCTAssertTrue(app.buttons["Host: \(name)"].firstMatch.waitForExistence(timeout: 20))
        }

        func back(from title: String) {
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 20))
            bar.buttons.firstMatch.tap()
        }

        app.launch()
        try pair(mac, name: "FixtureMac")
        try pair(server, name: "FixtureServer")
        tap("clutch-projects")
        tap("clutch-projects-create")
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Mixed Fleet \(UUID().uuidString.prefix(6))")
        tap("Create")

        tap("clutch-project-add-threads")
        tap("clutch-project-host-FixtureMac")
        tap("clutch-project-add-mcode-same")
        back(from: "FixtureMac")
        tap("clutch-project-host-FixtureServer")
        tap("clutch-project-add-muse-same")
        back(from: "FixtureServer")
        back(from: "Choose A Host")

        XCTAssertTrue(app.staticTexts["FixtureMac · MiniMax Code"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["FixtureServer · Muse Code"].exists)
        snap("ios-cross-host-project")
        tap("clutch-project-member-mcode-same")
        XCTAssertTrue(app.staticTexts["Preview from mcode"].waitForExistence(timeout: 20))
        back(from: "Thread mcode")
        tap("clutch-project-member-muse-same")
        XCTAssertTrue(app.staticTexts["Preview from muse"].waitForExistence(timeout: 20))
    }
}
