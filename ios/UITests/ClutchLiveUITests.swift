import XCTest

/// End-to-end run against a live clutch web on the Mac hosting the Simulator.
///
/// Opt-in: skipped unless `CLUTCH_PAIR_LINK` reaches the runner, e.g.
///
///     TEST_RUNNER_CLUTCH_PAIR_LINK="$(node src/web/pair-ios.ts --simulator --print)" \
///       xcodebuild … -only-testing:ClutchUITests test
///
/// Screenshots are kept as attachments named `ios-<state>`.
final class ClutchLiveUITests: XCTestCase {
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

    private func dump(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func waitAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) { return true }
            usleep(500_000)
        }
        return false
    }

    private func pairLink() throws -> URL {
        let raw = ProcessInfo.processInfo.environment["CLUTCH_PAIR_LINK"] ?? ""
        try XCTSkipIf(raw.isEmpty, "CLUTCH_PAIR_LINK not set; live run skipped")
        return try XCTUnwrap(URL(string: raw))
    }

    func testPairConnectPromptAndSwitchModel() throws {
        let link = try pairLink()
        app.launch()

        XCTAssertTrue(app.staticTexts["Pair With Clutch"].waitForExistence(timeout: 30))
        snap("ios-pairing")

        app.open(link)
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 60))
        XCTAssertTrue(waitAny([web.buttons["New Session"], web.buttons["Settings"], web.staticTexts["Into the Unknown"]], timeout: 90),
                      "clutch web did not render after pairing")
        sleep(2)
        snap("ios-connected")
        dump("tree-connected")

        // New session in a workspace, then a short prompt with a streamed reply.
        let workspace = ProcessInfo.processInfo.environment["CLUTCH_WORKSPACE_HINT"] ?? "clutch"
        tapFirst([web.buttons["New Session"], web.buttons["New session"]])
        let chooser = web.buttons["Choose workspace"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 30), "no workspace chooser")
        chooser.tap()
        sleep(2)
        dump("tree-workspace-menu")
        snap("ios-workspace-menu")
        let candidates = web.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", workspace))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 20), "workspace \(workspace) not offered")
        candidates.firstMatch.tap()
        sleep(2)

        let composer = web.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "no composer")
        composer.tap()
        composer.typeText("Reply with exactly the single word pong and nothing else.")
        snap("ios-session-open")
        tapFirst([web.buttons["Send message"]])
        let reply = web.staticTexts.matching(NSPredicate(format: "label ==[c] 'pong' OR label ==[c] 'pong.'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 180), "no streamed reply")
        sleep(2)
        snap("ios-streamed-reply")
        dump("tree-reply")

        // Switch model through the clutch web model picker.
        let picker = web.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Select model'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 30), "no model picker")
        let before = picker.label
        picker.tap()
        sleep(2)
        dump("tree-model-menu")
        snap("ios-model-menu")
        let options = web.descendants(matching: .any)
            .matching(NSPredicate(format: "(elementType == %d OR elementType == %d OR elementType == %d) AND (label CONTAINS[c] 'MiniMax' OR label CONTAINS[c] 'DeepSeek')",
                                  XCUIElement.ElementType.menuItem.rawValue,
                                  XCUIElement.ElementType.button.rawValue,
                                  XCUIElement.ElementType.radioButton.rawValue))
        let target = options.allElementsBoundByIndex.first { option in
            option.isHittable && !before.localizedCaseInsensitiveContains(option.label) && !option.label.hasPrefix("Select model")
        }
        XCTAssertNotNil(target, "no alternative model offered")
        target?.tap()
        sleep(2)
        let after = web.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Select model'")).firstMatch
        XCTAssertTrue(after.waitForExistence(timeout: 20))
        XCTAssertNotEqual(after.label, before, "model did not change")
        snap("ios-model-switched")
    }

    private func tapFirst(_ elements: [XCUIElement]) {
        for element in elements where element.waitForExistence(timeout: 5) {
            element.tap()
            return
        }
    }
}
