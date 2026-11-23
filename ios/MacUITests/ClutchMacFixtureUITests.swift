import XCTest

/// The Mac surface, driven through one synthetic turn.
///
/// This is the fixture the C-137 handoff asks for:  a running turn, its
/// permission card, and the transcript the turn ends in, all from the stub
/// sidecar and all of it fake.
///
/// Nothing here touches an owner window, a live engine, a live approval, a
/// push or a biometric.  The permission card is looked at and never
/// answered, because a fixture that approved something would be evidence of
/// an approval rather than of the surface.
///
/// The sequence is the same on every machine, so two captures of it can be
/// compared with each other:  the thread is named, the turn streams the same
/// text, and the tool call is the same one.
final class ClutchMacFixtureUITests: XCTestCase {
    private var setup: MacSurfaceSetup!

    override func setUpWithError() throws {
        continueAfterFailure = false
        setup = try MacSurfaceSetup(test: self, fixture: true)
    }

    override func tearDownWithError() throws {
        // The turn is held open until the test says it has seen the card,
        // so a test that failed before that leaves the stream waiting for
        // as long as the stub allows.  The gate is opened here, so the
        // stream ends and the stub can stop instead of holding its
        // connection open into the next run.
        setup?.stub.releaseTurn()
        setup?.stub.armPermission()
        setup?.shutdown()
        setup?.stub.stop()
        setup = nil
    }

    /// Finds the first element whose label or value carries the given text.
    ///
    /// SwiftUI exposes the words of a label as its value, and a control that
    /// carries an icon and a word exposes both, so a lookup that reads only
    /// the label misses half of what is on screen.
    private func carrying(_ query: XCUIElementQuery, _ text: String) -> XCUIElement {
        query
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch
    }

    func testTheFixtureTurnRunsStopsAtItsPermissionCardAndEndsInATranscript() throws {
        let app = setup.app
        app.launch()

        try setup.waitForWindow()
        // The app is a window on a desktop that belongs to somebody else, and
        // a control another window covers cannot be tapped at all.
        setup.bringToFront()

        // The fixture thread, by the name the stub gives it.  The name is
        // the identity of the fixture, so a capture says which sequence it
        // captured.
        let thread = app.buttons["Thread, \(StubSidecar.fixtureSessionTitle)"].firstMatch
        guard thread.waitForExistence(timeout: 60) else {
            setup.snap("mac-fixture-thread-missing")
            setup.dump("mac-fixture-thread-tree")
            XCTFail("the fixture thread did not appear in the Mac thread list")
            return
        }
        guard setup.tap(thread) else {
            setup.snap("mac-fixture-thread-not-hittable")
            setup.dump("mac-fixture-thread-tree")
            XCTFail("the fixture thread could not be tapped")
            return
        }

        // The Mac app previews a thread before it resumes it, and the
        // composer stays closed until the thread is resumed.
        let resume = app.buttons["Resume"].firstMatch
        guard resume.waitForExistence(timeout: 60) else {
            setup.snap("mac-fixture-resume-missing")
            setup.dump("mac-fixture-resume-tree")
            XCTFail("the fixture thread did not open its preview")
            return
        }
        guard setup.tap(resume) else {
            setup.snap("mac-fixture-resume-not-hittable")
            setup.dump("mac-fixture-resume-tree")
            XCTFail("the fixture thread's resume control could not be tapped")
            return
        }

        // The replayed history is on screen before the turn starts, and it
        // is not the transcript the turn ends in:  the replayed words and
        // the streamed words are different on purpose.
        let replayed = carrying(app.staticTexts, "Fixture: reading")
        guard replayed.waitForExistence(timeout: 60) else {
            setup.snap("mac-fixture-history-missing")
            setup.dump("mac-fixture-history-tree")
            XCTFail("the fixture thread's replayed history did not appear")
            return
        }

        // The turn: a draft in the composer and the send button the Mac and
        // the phone share.
        let draft = app.descendants(matching: .any).matching(identifier: "message-draft").firstMatch
        guard draft.waitForExistence(timeout: 30) else {
            setup.snap("mac-fixture-composer-missing")
            setup.dump("mac-fixture-composer-tree")
            XCTFail("the Mac composer did not offer its draft field")
            return
        }
        guard setup.tap(draft) else {
            setup.snap("mac-fixture-composer-not-hittable")
            setup.dump("mac-fixture-composer-tree")
            XCTFail("the Mac composer could not be typed into")
            return
        }
        draft.typeText("Run the fixture turn")
        let send = app.buttons["Send Message"].firstMatch
        guard send.waitForExistence(timeout: 30) else {
            setup.snap("mac-fixture-send-missing")
            setup.dump("mac-fixture-send-tree")
            XCTFail("the Mac composer did not offer its send button")
            return
        }
        guard setup.tap(send) else {
            setup.snap("mac-fixture-send-not-hittable")
            setup.dump("mac-fixture-send-tree")
            XCTFail("the Mac composer could not be sent from")
            return
        }

        // Moment one:  the turn is running.
        let running = carrying(app.staticTexts, "Fixture running")
        guard running.waitForExistence(timeout: 60) else {
            setup.snap("mac-fixture-running-missing")
            setup.dump("mac-fixture-running-tree")
            XCTFail("the fixture turn did not show its running text")
            return
        }
        XCTAssertTrue(
            app.buttons["Stop"].firstMatch.waitForExistence(timeout: 30),
            "the composer did not swap its send button for a stop button while the turn ran"
        )
        // The app is in front before the capture, so the picture is of the
        // surface and not of whatever the desktop holds behind it.
        setup.bringToFront()
        setup.snap("mac-fixture-running")
        // The turn asks for permission only once the test opens the gate, so
        // a running-turn picture cannot carry the card that comes after it.
        setup.stub.armPermission()

        // Moment two:  the permission card.  The turn is held at its
        // request until the test has looked at it, and nothing here answers
        // it.
        let permission = carrying(app.staticTexts, "Permission Needed")
        guard permission.waitForExistence(timeout: 60) else {
            setup.snap("mac-fixture-permission-missing")
            setup.dump("mac-fixture-permission-tree")
            XCTFail("the fixture turn did not show its permission card")
            return
        }
        XCTAssertTrue(
            carrying(app.staticTexts, "Run the login test suite").waitForExistence(timeout: 30),
            "the permission card did not say what the tool wanted"
        )
        XCTAssertTrue(
            carrying(app.buttons, "Allow once").waitForExistence(timeout: 30),
            "the permission card did not offer the engine's own options"
        )
        setup.bringToFront()
        setup.snap("mac-fixture-permission")

        // The turn only ends once the card has been looked at.
        setup.stub.releaseTurn()

        // Moment three:  the transcript the turn ended in.
        let final = carrying(app.staticTexts, StubSidecar.fixtureFinalText)
        guard final.waitForExistence(timeout: 60) else {
            setup.snap("mac-fixture-transcript-missing")
            setup.dump("mac-fixture-transcript-tree")
            XCTFail("the fixture turn did not end in its transcript")
            return
        }
        XCTAssertTrue(
            carrying(app.buttons, "read_file").waitForExistence(timeout: 30),
            "the fixture turn's tool call did not reach the transcript"
        )
        XCTAssertTrue(
            setup.waitForGone(app.buttons["Stop"].firstMatch, timeout: 30),
            "the composer still offered a stop button after the turn ended"
        )
        setup.bringToFront()
        setup.snap("mac-fixture-transcript")
    }
}
