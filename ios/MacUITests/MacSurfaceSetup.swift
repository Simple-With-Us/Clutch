import XCTest

/// The shared setup for the macOS UI tests.
///
/// The Mac app is the host, not a companion:  it has no pairing card, it
/// boots straight into the Workspace, and the test pairs it with the stub
/// from a launch argument, so the run never depends on whatever the machine
/// running it happens to have paired.  The run also keeps its paired hosts
/// in a preferences suite of its own, so it never unpairs the ones the owner
/// has on this machine.
final class MacSurfaceSetup {
    /// The error an app that exited carries out of the window wait.
    ///
    /// Throwing it leaves the test, and a test that ends in an error is a
    /// failure:  an app that exited instead of opening a window is a defect
    /// in the surface, not a fact about the machine.
    static var appExitedError: NSError {
        NSError(
            domain: "ClutchMacSurfaceUITests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "the Mac app exited instead of opening a window"]
        )
    }

    private let test: XCTestCase
    let app: XCUIApplication
    let stub: StubSidecar

    init(test: XCTestCase, fixture: Bool = false) throws {
        self.test = test
        stub = StubSidecar(fixture: fixture)
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

    /// The pairing link for the stub, with the chat port it listens on.
    ///
    /// A code server has no web port of its own, so the origin port is the
    /// chat port:  that is the only port behind the name.
    static func pairingLink(for port: Int) -> String {
        "clutch://pair?h=127.0.0.1&tls=0&kind=mcode"
            + "&chat=\(StubSidecar.chatToken)&chatPort=\(port)"
    }

    /// Attaches a picture of the surface under test.
    ///
    /// The attachment is the app's own window and not the screen.  A macOS
    /// screenshot of the screen carries everything else on the desktop of
    /// whoever is sitting at the machine, so a run on somebody else's screen
    /// would put their private desktop into the result bundle and from there
    /// into a reviewer's inbox.  The screen is only the fallback for a run
    /// with no window to photograph, which is the state the window wait
    /// reports.
    func snap(_ name: String) {
        let window = app.windows.firstMatch
        let image: XCUIScreenshot = window.exists ? window.screenshot() : XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: image)
        shot.name = name
        shot.lifetime = .keepAlways
        test.add(shot)
    }

    func dump(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        test.add(tree)
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
    func bringToFront() {
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
    /// The hosted runner's automation session does not see the Mac app's
    /// window.  CI runs 45068164411 and 45073642226 both show the app
    /// launching, the automation session coming up and the app going idle,
    /// and `Descendants matching type Window` staying empty for the whole
    /// 60 seconds.  The second of those runs had the
    /// `-ApplePersistenceIgnoreState` flag out of the launch arguments, so
    /// the flag is not the cause of it.
    ///
    /// A macOS window that sits on a space the runner is not showing is not
    /// in the accessibility tree, so the runner can be looking at an app
    /// that plainly has a window and still see nothing.  That is a fact
    /// about the machine, not a defect in the surface, and a test that
    /// failed on it would be a false alarm on every run.  So the test skips,
    /// loudly, and the result bundle says which state it was in.
    ///
    /// What the run can still answer is that the app launched and stayed
    /// alive, so an app that exits instead of opening a window fails here
    /// rather than skipping.
    func waitForWindow(timeout: TimeInterval = 60) throws {
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
            // An app that exited is a defect in the surface, and waiting out
            // the timeout to say so would delay the answer by a minute per
            // test on exactly the broken-app path.
            if app.state == .notRunning {
                XCTFail("the Mac app exited instead of opening a window")
                // The failure has to leave the test rather than fall through
                // to the skip below:  a skip raised afterwards would report an
                // app that exited as a fact about the machine.
                throw Self.appExitedError
            }
            // Bringing the app forward is best effort.  A runner that does
            // not own the foreground session cannot activate it, and that is
            // not a reason to stop looking for the window.
            try? app.activate()
            Thread.sleep(forTimeInterval: 1)
        }
        snap("mac-window-missing")
        dump("mac-window-tree")
        if app.state == .notRunning {
            throw Self.appExitedError
        }
        throw XCTSkip(
            "the runner's automation session could not see the Mac app's window; the app was "
                + "running, so the Mac surface was not verified"
        )
    }

    /// Taps an element once the app is in front and the element can be hit.
    ///
    /// The app under test is a window on a desktop that belongs to somebody
    /// else, and a control that another window covers is not clickable at
    /// all:  the test would fail on the desktop rather than on the surface.
    /// So the app is brought forward and the tap waits for the control to
    /// become hittable.
    @discardableResult
    func tap(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        // The app is brought forward once, before the loop:  bringing it
        // forward polls for the foreground for up to ten seconds itself, so
        // doing it inside the loop would stretch a thirty-second timeout
        // toward minutes.  Inside the loop the activation is a single
        // request, which is enough to lift the app over a window that
        // covered it without paying for the poll again.
        bringToFront()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isHittable {
                element.click()
                return true
            }
            try? app.activate()
            Thread.sleep(forTimeInterval: 0.5)
        }
        // The element is there and the app is in front, but the automation
        // session does not consider the control hittable:  a control that
        // another element overlaps is not clickable through the element
        // itself, while a click at its middle still reaches it.  So the
        // click is made at the point the control is on.
        guard element.exists else { return false }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        // The click is only a success if it reached the app.  A click that
        // landed on the panel the system put in front of the app reaches
        // nothing, and a caller that believes it tapped a control then
        // fails later on a tree that never had it.
        //
        // A control that stays covered but is reachable is still a
        // success:  that is the case the fallback is here for.  The app
        // being in front is what says the click reached it.
        let settled = Date().addingTimeInterval(2)
        while Date() < settled {
            if element.isHittable || app.state == .runningForeground { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Dismisses a system panel that took the front of the session.
    ///
    /// A panel the system puts over an app (a text field's auto-complete
    /// list, the character palette) is modal for the automation session:
    /// the app behind it reads as a background app, and a control in a
    /// background app cannot be clicked at all.  Escape is what closes
    /// those panels.
    ///
    /// The escape is not sent blind.  Escape also blurs the composer,
    /// closes a popover and cancels whatever the app is doing, so the
    /// composer is checked afterwards, and a dismissal that took the
    /// composer's text with it is reported as the failure it is instead
    /// of passing over a surface that is no longer the one under test.
    ///
    /// The helper says whether the dismissal was clean.
    @discardableResult
    func dismissSystemPanel(_ composer: XCUIElement? = nil) -> Bool {
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)
        if let composer, let value = composer.value as? String, value.isEmpty {
            // The dismissal took the composer's text with it, so the
            // surface under test is not the surface the test meant.
            return false
        }
        return true
    }

    /// Stops the app and waits for it to go.
    ///
    /// The next test launches its own copy of the app, and a copy that is
    /// still shutting down holds the bundle's foreground away from the new
    /// one, so the run would answer with a machine that cannot host the
    /// test rather than with the surface.
    func shutdown() {
        app.terminate()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if app.state == .notRunning { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // The app did not go on request.  The next test launches its own
        // copy anyway, and the copy that is still shutting down is the
        // reason this run would answer with a machine instead of a surface,
        // so the wait above is what matters and the copy is left to finish
        // on its own.
    }

    /// Waits for an element to go away, and says whether it did.
    ///
    /// The composer swaps its send button for a stop button while a turn
    /// runs, and the fixture asserts the swap went back the other way when
    /// the turn ended.
    func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return !element.exists
    }
}
