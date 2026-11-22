import XCTest

/// The macOS workspace, exercised against the same stub sidecar the iOS suite
/// drives, so both platforms are measured against one server.
///
/// The Mac target was compiled in CI and never executed, so no defect on the
/// Mac surface could fail a build.  These tests are what change that.
///
/// The Mac app is the host, not a companion: it has no pairing card.  It
/// boots straight into the Workspace and finds its first host by adopting
/// `$CLUTCH_HOME/web-launch-url`, which the test points at the stub.  That is
/// the same path a real first run takes, and it means the test never depends
/// on whatever the machine running it happens to have paired.
final class ClutchMacSurfaceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stub: StubSidecar!
    private var home: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        stub = StubSidecar()
        try stub.start()

        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("clutch-mac-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // The launch URL is the pairing the Mac app adopts on first run, and
        // the token file is the sidecar credential it backfills onto a
        // loopback host.  Both point at the stub, never at a real install.
        try Self.write(
            "clutch://pair?host=127.0.0.1&port=3180&kind=mcode"
                + "&chat=\(StubSidecar.chatToken)&chatPort=\(stub.port)",
            to: home.appendingPathComponent("web-launch-url")
        )
        try Self.write(
            StubSidecar.chatToken,
            to: home.appendingPathComponent("chat-token")
        )

        app = XCUIApplication()
        // The window size and the rail width are both restored from the last
        // run on the machine, so the app is asked to open at a fixed size and
        // to drop the saved rail width.  That is what makes the surface
        // under test the same surface on every machine.
        //
        // `-ApplePersistenceIgnoreState` is deliberately not used here:  it
        // tells AppKit to ignore the saved state, and a SwiftUI app that
        // ignores its saved state opens no window at all, which leaves the
        // test with nothing to look at.
        app.launchArguments = [
            "-ClutchResetHosts",
            "-ClutchWindowSize", "1040x760",
        ]
        app.launchEnvironment["CLUTCH_HOME"] = home.path
    }

    override func tearDownWithError() throws {
        app?.terminate()
        stub?.stop()
        app = nil
        stub = nil
        if let home {
            try? FileManager.default.removeItem(at: home)
        }
        home = nil
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func dump(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
    }

    /// The window under test.
    ///
    /// The launch arguments make the app open one window at its declared
    /// size, so the capture is the same picture on every machine.
    private func normalizedWindow() -> XCUIElement {
        app.windows.firstMatch
    }

    /// Waits for the workspace window to show up, and fails the test when it
    /// never does.
    ///
    /// A macOS window that sits on a space the runner is not showing is not
    /// in the accessibility tree, so the runner can be looking at an app
    /// that plainly has a window and still see nothing.  The app answers
    /// that case itself:  the test window modifier moves its window to the
    /// active space and brings it to the front, so a runner that can host
    /// the test at all sees the window too.
    ///
    /// A window that still never appears is a defect in the surface, and the
    /// test says so.  Skipping here would be a green build that proved
    /// nothing, which is the state this test exists to end.
    private func waitForWindow(timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count > 0 { return }
            app.activate()
            Thread.sleep(forTimeInterval: 1)
        }
        snap("mac-window-missing")
        dump("mac-window-tree")
        XCTFail(
            "the Mac app never opened a window the runner could see; the app may hold it on a "
                + "space the runner is not showing"
        )
    }

    func testWorkspaceOpensAndListsTheStubThread() throws {
        app.launch()

        waitForWindow()

        // The sidebar is the Mac app's own chrome.  Its presence says the
        // window rendered rather than sat on a spinner.
        guard app.staticTexts["Threads"].waitForExistence(timeout: 60) else {
            snap("mac-sidebar-missing")
            dump("mac-sidebar-tree")
            XCTFail("the Mac workspace did not draw its thread sidebar")
            return
        }

        // The thread row is the proof the app really talked to the stub over
        // the sidecar's own session route.  Nothing else in this test can
        // fake that.
        let thread = app.buttons["Thread, Fix The Login Redirect"].firstMatch
        if !thread.waitForExistence(timeout: 60) {
            snap("mac-workspace-threads-missing")
            dump("mac-workspace-threads-tree")
            XCTFail("the stub's thread did not appear in the Mac thread list")
            return
        }

        let window = normalizedWindow()
        snap("mac-workspace-threads")
        try assertSnapshot("mac-workspace-threads", of: window)
    }

    func testWorkspaceShowsTheEngineCatalogTheStubServed() throws {
        app.launch()

        waitForWindow()

        // The engine picker carries the name the stub's engine catalog
        // served.  A workspace with no host shows a different engine, so the
        // name is the evidence that the app read the catalog over the
        // sidecar and drew it.
        let engine = app.menuButtons["MiniMax Code"].firstMatch
        if !engine.waitForExistence(timeout: 60) {
            snap("mac-engine-missing")
            dump("mac-engine-tree")
            XCTFail("the engine the stub served did not appear in the Mac workspace")
            return
        }

        let window = normalizedWindow()
        snap("mac-workspace-engine")
        try assertSnapshot("mac-workspace-engine", of: window)
    }
}
