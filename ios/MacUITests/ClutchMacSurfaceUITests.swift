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
    private var setup: MacSurfaceSetup!

    override func setUpWithError() throws {
        continueAfterFailure = false
        setup = try MacSurfaceSetup(test: self)
    }

    override func tearDownWithError() throws {
        setup?.shutdown()
        setup?.stub.stop()
        setup = nil
    }

    func testWorkspaceOpensAndListsTheStubThread() throws {
        let app = setup.app
        app.launch()

        try setup.waitForWindow()

        // The sidebar is the Mac app's own chrome.  Its presence says the
        // window rendered rather than sat on a spinner.
        guard app.staticTexts["Threads"].waitForExistence(timeout: 60) else {
            setup.snap("mac-sidebar-missing")
            setup.dump("mac-sidebar-tree")
            XCTFail("the Mac workspace did not draw its thread sidebar")
            return
        }

        // The thread row is the proof the app really talked to the stub over
        // the sidecar's own session route.  Nothing else in this test can
        // fake that.
        let thread = app.buttons["Thread, Fix The Login Redirect"].firstMatch
        if !thread.waitForExistence(timeout: 60) {
            setup.snap("mac-workspace-threads-missing")
            setup.dump("mac-workspace-threads-tree")
            XCTFail("the stub's thread did not appear in the Mac thread list")
            return
        }

        setup.bringToFront()
        setup.snap("mac-workspace-threads")
    }

    func testWorkspaceShowsTheEngineCatalogTheStubServed() throws {
        let app = setup.app
        app.launch()

        try setup.waitForWindow()

        // The name of the engine comes from the catalog the stub answered
        // with.  The stub names its engine "Stub Engine", which no build of
        // the app can produce on its own, so the name is the evidence that
        // the app read the catalog over the sidecar and drew it.
        let engine = app.staticTexts["Stub Engine"].firstMatch
        if !engine.waitForExistence(timeout: 60) {
            setup.snap("mac-engine-missing")
            setup.dump("mac-engine-tree")
            XCTFail("the engine the stub served did not appear in the Mac workspace")
            return
        }

        setup.bringToFront()
        setup.snap("mac-workspace-engine")
    }
}
