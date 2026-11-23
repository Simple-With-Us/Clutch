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
    private var harness: MacSurfaceHarness!

    override func setUpWithError() throws {
        continueAfterFailure = false
        harness = try MacSurfaceHarness(test: self, fixture: true)
    }

    override func tearDownWithError() throws {
        harness?.shutdown()
        harness?.stub.stop()
        harness = nil
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
        let app = harness.app
        app.launch()

        try harness.waitForWindow()

        // The fixture thread, by the name the stub gives it.  The name is
        // the identity of the fixture, so a capture says which sequence it
        // captured.
        let thread = app.buttons["Thread, \(StubSidecar.fixtureSessionTitle)"].firstMatch
        guard thread.waitForExistence(timeout: 60) else {
            harness.snap("mac-fixture-thread-missing")
            harness.dump("mac-fixture-thread-tree")
            XCTFail("the fixture thread did not appear in the Mac thread list")
            return
        }
        thread.click()

        // The Mac app previews a thread before it resumes it, and the
        // composer stays closed until the thread is resumed.
        let resume = app.buttons["Resume"].firstMatch
        guard resume.waitForExistence(timeout: 60) else {
            harness.snap("mac-fixture-resume-missing")
            harness.dump("mac-fixture-resume-tree")
            XCTFail("the fixture thread did not open its preview")
            return
        }
        resume.click()

        // The replayed history is on screen before the turn starts, and it
        // is not the transcript the turn ends in:  the replayed words and
        // the streamed words are different on purpose.
        let replayed = carrying(app.staticTexts, "Fixture: reading")
        guard replayed.waitForExistence(timeout: 60) else {
            harness.snap("mac-fixture-history-missing")
            harness.dump("mac-fixture-history-tree")
            XCTFail("the fixture thread's replayed history did not appear")
            return
        }

        // The turn: a draft in the composer and the send button the Mac and
        // the phone share.
        let draft = app.descendants(matching: .any).matching(identifier: "message-draft").firstMatch
        guard draft.waitForExistence(timeout: 30) else {
            harness.snap("mac-fixture-composer-missing")
            harness.dump("mac-fixture-composer-tree")
            XCTFail("the Mac composer did not offer its draft field")
            return
        }
        draft.click()
        draft.typeText("Run the fixture turn")
        let send = app.buttons["Send Message"].firstMatch
        guard send.waitForExistence(timeout: 30) else {
            harness.snap("mac-fixture-send-missing")
            harness.dump("mac-fixture-send-tree")
            XCTFail("the Mac composer did not offer its send button")
            return
        }
        send.click()

        // Moment one:  the turn is running.
        let running = carrying(app.staticTexts, "Fixture running")
        guard running.waitForExistence(timeout: 60) else {
            harness.snap("mac-fixture-running-missing")
            harness.dump("mac-fixture-running-tree")
            XCTFail("the fixture turn did not show its running text")
            return
        }
        XCTAssertTrue(
            app.buttons["Stop"].firstMatch.waitForExistence(timeout: 30),
            "the composer did not swap its send button for a stop button while the turn ran"
        )
        harness.bringToFront()
        harness.snap("mac-fixture-running")

        // Moment two:  the permission card.  The turn is held at its
        // request until the test has looked at it, and nothing here answers
        // it.
        let permission = carrying(app.staticTexts, "Permission Needed")
        guard permission.waitForExistence(timeout: 60) else {
            harness.snap("mac-fixture-permission-missing")
            harness.dump("mac-fixture-permission-tree")
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
        harness.bringToFront()
        harness.snap("mac-fixture-permission")

        // The turn only ends once the card has been looked at.
        harness.stub.releaseTurn()

        // Moment three:  the transcript the turn ended in.
        let final = carrying(app.staticTexts, StubSidecar.fixtureFinalText)
        guard final.waitForExistence(timeout: 60) else {
            harness.snap("mac-fixture-transcript-missing")
            harness.dump("mac-fixture-transcript-tree")
            XCTFail("the fixture turn did not end in its transcript")
            return
        }
        XCTAssertTrue(
            carrying(app.buttons, "read_file").waitForExistence(timeout: 30),
            "the fixture turn's tool call did not reach the transcript"
        )
        XCTAssertTrue(
            harness.waitForGone(app.buttons["Stop"].firstMatch, timeout: 30),
            "the composer still offered a stop button after the turn ended"
        )
        harness.bringToFront()
        harness.snap("mac-fixture-transcript")
    }
}
