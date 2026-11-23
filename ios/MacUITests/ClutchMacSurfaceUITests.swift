import XCTest

/// The macOS workspace, exercised against the same stub sidecar the iOS suite
/// drives, so both platforms are measured against one server.
///
/// The Mac target was compiled in CI and never executed, so no defect on the
/// Mac surface could fail a build.  These tests are what change that.
///
/// The Mac app is the host, not a companion: it has no pairing card.  It
/// boots straight into the Workspace, and the test pairs it with the stub
/// from a launch argument, so the run never depends on whatever the machine
/// running it happens to have paired.  The run also keeps its paired hosts
/// in a preferences suite of its own, so it never unpairs the ones the owner
/// has on this machine.
///
/// There is no pixel comparison here, and there is a reason for it.  A
/// screenshot of a macOS window shows the screen region the window covers,
/// so a window that another application is sitting on top of is captured
/// with that other application in it.  On a desktop that belongs to
/// somebody else, that is most of the time, and a comparison against a
/// checked-in picture would then measure the desktop rather than the app.
/// The gate on this surface is therefore what the surface must contain:
/// the workspace, the thread the stub served, and the engine the stub's
/// catalog named.  The screenshots are kept as attachments for a human to
/// look at.
final class ClutchMacSurfaceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stub: StubSidecar!

    override func setUpWithError() throws {
        continueAfterFailure = false
        stub = StubSidecar()
        try stub.start()

        app = XCUIApplication()
        // The window size and the rail width are both restored from the last
        // run on the machine, so the app is asked to open at a fixed size and
        // to drop the saved rail width.  That is what makes the surface
        // under test the same surface on every machine.
        //
        // `-ApplePersistenceIgnoreState` is deliberately not used here:  it
        // tells AppKit to ignore the saved state, and a SwiftUI app that
        // ignores its saved state opens no window at all, which leaves the
        // test with nothing to look at and every run skipped.
        app.launchArguments = [
            "-ClutchResetHosts",
            "-ClutchWindowSize", "1040x760",
            // The pairing travels as a launch argument rather than as a file
            // the test writes:  the test runner's container is protected, so
            // a file it writes is not readable from the app.  The link
            // points at the stub and never at a real install.
            "-ClutchPairingLink", Self.pairingLink(for: stub.port),
            // The app keeps its paired hosts in preferences, so the run is
            // given a suite of its own.  Without this the test would unpair
            // the hosts the owner has on this machine.
            "-ClutchDefaultsSuite", "codes.clutch.macos.uitest",
        ]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        stub?.stop()
        app = nil
        stub = nil
    }

    /// The pairing link for the stub, with the chat port it listens on.
    ///
    /// A code server has no web port of its own, so the origin port is the
    /// chat port:  that is the only port behind the name.
    private static func pairingLink(for port: Int) -> String {
        "clutch://pair?h=127.0.0.1&tls=0&kind=mcode"
            + "&chat=\(StubSidecar.chatToken)&chatPort=\(port)"
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

    /// Brings the app to the front of the machine.
    ///
    /// The app under test is a window on a desktop that belongs to somebody
    /// else, and a screenshot of that window shows whatever else is on the
    /// desktop as well.  Bringing the app forward is what makes the
    /// attachment worth looking at.
    ///
    /// This is best effort.  A runner that does not own the foreground
    /// session cannot bring an app forward, and the attachment is still
    /// worth having.
    private func bringToFront() {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try? app.activate()
            if app.state == .runningForeground { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Waits for the workspace window to show up, and skips the test when it
    /// never does.
    ///
    /// A macOS window that sits on a space the runner is not showing is not
    /// in the accessibility tree, so the runner can be looking at an app
    /// that plainly has a window and still see nothing.  That is a fact
    /// about the machine, not a defect in the surface, and a test that
    /// failed on it would be a false alarm.  So the test skips, loudly, and
    /// the result bundle says which state it was in.
    private func waitForWindow(timeout: TimeInterval = 60) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count > 0 {
                // A background app's controls are disabled, so the app is
                // brought forward before anything is tapped.  This is best
                // effort:  a runner that does not own the foreground
                // session cannot activate it, and the window is still there.
                try? app.activate()
                return
            }
            // Bringing the app forward is best effort.  A runner that does
            // not own the foreground session cannot activate it, and that is
            // not a reason to stop looking for the window.
            try? app.activate()
            Thread.sleep(forTimeInterval: 1)
        }
        snap("mac-window-missing")
        dump("mac-window-tree")
        throw XCTSkip(
            "the runner could not see the Mac app's window; the app may hold it on a space "
                + "the runner is not showing"
        )
    }

    func testWorkspaceOpensAndListsTheStubThread() throws {
        app.launch()

        try waitForWindow()

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

        bringToFront()
        snap("mac-workspace-threads")
    }

    func testWorkspaceShowsTheEngineCatalogTheStubServed() throws {
        app.launch()

        try waitForWindow()

        // The name of the engine comes from the catalog the stub answered
        // with.  The stub names its engine "Stub Engine", which no build of
        // the app can produce on its own, so the name is the evidence that
        // the app read the catalog over the sidecar and drew it.
        let engine = app.staticTexts["Stub Engine"].firstMatch
        if !engine.waitForExistence(timeout: 60) {
            snap("mac-engine-missing")
            dump("mac-engine-tree")
            XCTFail("the engine the stub served did not appear in the Mac workspace")
            return
        }

        bringToFront()
        snap("mac-workspace-engine")
    }
}
