import XCTest
@testable import Clutch

/// The typed tool card.
///
/// The tests below are about what the card is allowed to claim:  a card
/// shows what the engine wrote and nothing it did not, and a call whose
/// answer names no exit code has no exit code on its card.
final class TypedToolCardTests: XCTestCase {

    func testAFileReadNamesTheFileItRead() {
        let card = TypedToolCard.make(
            name: "read_file",
            status: "completed",
            input: #"{"path": "src/App/Models/AcpSession.swift"}"#,
            output: "public struct AcpSession {}"
        )

        XCTAssertEqual(card.kind, .fileRead)
        XCTAssertEqual(card.path, "src/App/Models/AcpSession.swift")
        XCTAssertEqual(card.headline, "Read src/App/Models/AcpSession.swift")
    }

    func testAnEditCountsTheLinesItAddedAndRemoved() {
        let card = TypedToolCard.make(
            name: "edit_file",
            status: "completed",
            input: #"{"path": "a.ts", "old_string": "one\ntwo", "new_string": "one\ntwo\nthree"}"#,
            output: "ok"
        )

        XCTAssertEqual(card.kind, .fileEdit)
        XCTAssertEqual(card.addedLines, 1)
        XCTAssertEqual(card.removedLines, 0)
        XCTAssertEqual(card.headline, "Changed a.ts  +1  −0")
    }

    func testAnEditThatReplacesLinesCountsBothSides() {
        let card = TypedToolCard.make(
            name: "apply_patch",
            status: "completed",
            input: #"{"path": "a.ts", "old_string": "one\ntwo", "new_string": "one\nthree"}"#,
            output: "ok"
        )

        XCTAssertEqual(card.addedLines, 1)
        XCTAssertEqual(card.removedLines, 1)
    }

    func testAUnifiedDiffIsCountedFromTheDiffItself() {
        let card = TypedToolCard.make(
            name: "edit_file",
            status: "completed",
            input: #"{"path": "a.ts", "diff": "@@ -1,2 +1,3 @@\n one\n-two\n+two\n+three"}"#,
            output: "ok"
        )

        XCTAssertEqual(card.addedLines, 2)
        XCTAssertEqual(card.removedLines, 1)
    }

    func testAShellCallShowsTheCommandAndTheExitCodeItNamed() {
        let card = TypedToolCard.make(
            name: "bash",
            status: "failed",
            input: #"{"command": "npm test"}"#,
            output: "Process exited with code 1"
        )

        XCTAssertEqual(card.kind, .shell)
        XCTAssertEqual(card.command, "npm test")
        XCTAssertEqual(card.exitCode, 1)
        XCTAssertEqual(card.detail, "Exit 1")
    }

    func testAShellCallThatNamedNoExitCodeHasNoExitCode() {
        let card = TypedToolCard.make(
            name: "bash",
            status: "completed",
            input: #"{"command": "ls"}"#,
            output: "README.md"
        )

        // The status the call reported is not an exit code, and a card
        // that shows a number nobody recorded is lying.
        XCTAssertNil(card.exitCode)
        XCTAssertNil(card.detail)
    }

    func testATestCallShowsHowManyPassedAndWhichFailed() {
        let card = TypedToolCard.make(
            name: "run_tests",
            status: "failed",
            input: #"{"command": "npm test"}"#,
            output: """
            12 passed
            1 failed
            FAIL tests/login.test.ts
            """
        )

        XCTAssertEqual(card.kind, .test)
        XCTAssertEqual(card.passed, 12)
        XCTAssertEqual(card.failed, 1)
        XCTAssertEqual(card.failingNames, ["tests/login.test.ts"])
        XCTAssertEqual(card.detail, "12 passed  1 failed  tests/login.test.ts")
    }

    func testTheRawCallAndTheRawAnswerAreKeptForTheReaderWhoWantsThem() {
        let card = TypedToolCard.make(
            name: "read_file",
            status: "completed",
            input: #"{"path": "a.ts"}"#,
            output: "hello"
        )

        XCTAssertEqual(card.rawInput, #"{"path": "a.ts"}"#)
        XCTAssertEqual(card.rawOutput, "hello")
    }

    func testACallWithNoArgumentsIsStillACall() {
        let card = TypedToolCard.make(name: "list_sessions", status: "completed")

        XCTAssertEqual(card.kind, .unknown)
        XCTAssertNil(card.path)
        XCTAssertNil(card.command)
        XCTAssertEqual(card.headline, "list_sessions")
    }

    func testArgumentsThatAreNotJSONDoNotBreakTheCard() {
        let card = TypedToolCard.make(name: "bash", status: "completed", input: "not json at all")

        XCTAssertEqual(card.kind, .shell)
        XCTAssertNil(card.command)
    }

    func testTheKindIsReadFromTheNameBeforeTheArguments() {
        XCTAssertEqual(TypedToolCard.classify(name: "run_tests"), .test)
        XCTAssertEqual(TypedToolCard.classify(name: "read_file"), .fileRead)
        XCTAssertEqual(TypedToolCard.classify(name: "edit_file"), .fileEdit)
        XCTAssertEqual(TypedToolCard.classify(name: "bash"), .shell)
        // A thread is not a file, whatever else it ends with.
        XCTAssertEqual(TypedToolCard.classify(name: "send_thread"), .unknown)
    }
}
