import XCTest
@testable import Clutch

/// The transcript a Mac thread shows.
///
/// The tests below are about what the reader is told:  a row that does not
/// know when it happened says so, a live turn is part of the transcript
/// rather than a pane beside it, and the verbosity the reader picked is
/// the only thing that decides how much of the transcript there is.
final class MacTranscriptModelTests: XCTestCase {

    private func model() -> MacTranscriptModel {
        var model = MacTranscriptModel()
        model.workspace = true
        return model
    }

    func testAReplayedRowCarriesTheTimeTheEngineRecordedAndNothingElseDoes() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "First", at: Date(timeIntervalSince1970: 1_700_000_000)),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "Second"),
        ]

        let rows = model.rows

        XCTAssertEqual(rows[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        // A row with no recorded time carries none.  A client that shows
        // the time it read the row back tells the reader that a three week
        // old thread happened now.
        XCTAssertNil(rows[1].date)
    }

    func testTheLiveTurnIsPartOfTheTranscript() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Earlier answer", at: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        model.live = MacTranscriptModel.Live(text: "Streaming now", running: true)

        let rows = model.rows

        // The answer that is streaming is the last row of the transcript,
        // not a pane beside it.
        XCTAssertEqual(rows.last?.kind, .live)
        XCTAssertEqual(rows.last?.text, "Streaming now")
    }

    func testARunningTurnWithNothingToSaySaysThatItIsWorking() {
        var model = self.model()
        model.live = MacTranscriptModel.Live(text: "", running: true)

        let rows = model.rows

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .live)
        XCTAssertEqual(rows[0].text, "Working…")
    }

    func testAFailedTurnIsARowOfItsOwn() {
        var model = self.model()
        model.live = MacTranscriptModel.Live(failure: "The turn failed.", running: false)

        let rows = model.rows

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .failure)
        XCTAssertEqual(rows[0].text, "The turn failed.")
    }

    func testToolCallsCarryNoTimeOfTheirOwn() {
        var model = self.model()
        model.tools = [
            MacTranscriptModel.ToolCall(id: "t1", name: "read_file", status: "completed"),
        ]

        let rows = model.rows

        // The time the client read the call back is not the time the call
        // happened, so the row carries no time.
        XCTAssertNil(rows[0].date)
        XCTAssertEqual(rows[0].toolStatus, "completed")
    }

    func testNormalCollapsesEachRunOfToolCallsIntoOneRow() {
        var model = self.model()
        model.tools = [
            MacTranscriptModel.ToolCall(id: "t1", name: "read_file", status: "completed"),
            MacTranscriptModel.ToolCall(id: "t2", name: "read_file", status: "completed"),
            MacTranscriptModel.ToolCall(id: "t3", name: "grep", status: "failed"),
        ]
        model.verbosity = .normal

        let rows = model.rows

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .toolGroup)
        // The line names what the run did, and a call the classifier does
        // not know is counted rather than guessed at.
        XCTAssertEqual(rows[0].text, "2 files, 1 more")
        XCTAssertEqual(rows[0].toolCount, 3)
        // The group carries the outcome of the run.
        XCTAssertEqual(rows[0].toolStatus, "failed")
    }

    func testVerboseKeepsEveryToolCallOnItsOwn() {
        var model = self.model()
        model.tools = [
            MacTranscriptModel.ToolCall(id: "t1", name: "read_file", status: "completed"),
            MacTranscriptModel.ToolCall(id: "t2", name: "grep", status: "failed"),
        ]
        model.verbosity = .verbose

        let rows = model.rows

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].kind, .tool)
        XCTAssertEqual(rows[1].kind, .tool)
    }

    func testSummaryLeavesTheThoughtsOutAndCountsTheToolCalls() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Thinking about it", isThought: true),
        ]
        model.tools = [
            MacTranscriptModel.ToolCall(id: "t1", name: "read_file", status: "completed"),
            MacTranscriptModel.ToolCall(id: "t2", name: "read_file", status: "completed"),
        ]
        model.verbosity = .summary

        let rows = model.rows

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .toolGroup)
    }

    func testNormalKeepsTheThoughtAndCollapsesTheToolCalls() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Thinking about it", isThought: true),
        ]
        model.tools = [
            MacTranscriptModel.ToolCall(id: "t1", name: "read_file", status: "completed"),
            MacTranscriptModel.ToolCall(id: "t2", name: "read_file", status: "completed"),
        ]
        model.verbosity = .normal

        let rows = model.rows

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].kind, .thought)
        XCTAssertEqual(rows[1].kind, .toolGroup)
    }

    func testTheChatSurfaceOrdersRowsByTheTimeTheyHappened() {
        var model = MacTranscriptModel()
        model.prompts = [
            MacTranscriptModel.Prompt(id: "p1", text: "Second prompt", at: Date(timeIntervalSince1970: 200)),
        ]
        model.messages = [
            MacTranscriptModel.Message(id: "m1", text: "First answer", date: Date(timeIntervalSince1970: 100)),
        ]

        let rows = model.rows

        XCTAssertEqual(rows.map(\.text), ["First answer", "Second prompt"])
    }

    func testARowWithNoTimeIsOrderedAsTheOldestThingThereIs() {
        var model = MacTranscriptModel()
        model.prompts = [
            MacTranscriptModel.Prompt(id: "p1", text: "A prompt", at: Date(timeIntervalSince1970: 100)),
        ]
        model.messages = [
            MacTranscriptModel.Message(id: "m1", text: "A message with no time", date: nil),
        ]

        let rows = model.rows

        // It does not know when it happened, and it is not put at the end
        // as if it had just happened.
        XCTAssertEqual(rows.map(\.text), ["A message with no time", "A prompt"])
    }

    func testTheWorkspaceKeepsTheOrderTheEngineRecorded() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Third", at: Date(timeIntervalSince1970: 300)),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "First", at: Date(timeIntervalSince1970: 100)),
            MacTranscriptModel.HistoryEntry(id: "h3", text: "Second", at: Date(timeIntervalSince1970: 200)),
        ]

        let rows = model.rows

        // The replay is already chronological, and the transcript does not
        // re-order what the engine recorded.
        XCTAssertEqual(rows.map(\.text), ["Third", "First", "Second"])
    }

    // MARK: - The Turn Ledger

    func testAPromptStartsATurnAndTheRowsAfterItBelongToThatTurn() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Fix the login redirect", fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "On it."),
            MacTranscriptModel.HistoryEntry(id: "h3", text: "Next question", fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h4", text: "On it again."),
        ]

        let turns = model.turns

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].summary, "Fix the login redirect")
        XCTAssertEqual(turns[1].summary, "Next question")
        XCTAssertEqual(model.rows.map { $0.turn }, [1, 1, 2, 2])
    }

    func testATurnCountsTheCallsItMadeAndTheFilesItTouched() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Do the work", fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "read_file", isTool: true),
            MacTranscriptModel.HistoryEntry(id: "h3", text: "edit_file", isTool: true),
            MacTranscriptModel.HistoryEntry(id: "h4", text: "bash", isTool: true),
            MacTranscriptModel.HistoryEntry(id: "h5", text: "run_tests", isTool: true),
        ]

        let turn = model.turns[0]

        XCTAssertEqual(turn.toolCount, 4)
        XCTAssertEqual(turn.fileCount, 2)
        XCTAssertEqual(turn.commandCount, 1)
        XCTAssertEqual(turn.testCount, 1)
    }

    func testATurnCarriesTheTimeItStartedAndHowLongItTook() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Do the work", at: Date(timeIntervalSince1970: 1_000), fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "On it.", at: Date(timeIntervalSince1970: 1_030)),
        ]

        let turn = model.turns[0]

        XCTAssertEqual(turn.startedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(turn.duration ?? 0, 30, accuracy: 0.001)
    }

    func testATurnWithNoRecordedTimeHasNoLength() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Do the work", fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "On it."),
        ]

        // The length of a turn that was never timed is not the time it was
        // read back.
        XCTAssertNil(model.turns[0].startedAt)
        XCTAssertNil(model.turns[0].duration)
    }

    func testTheTurnKeepsTheSameIdentityAcrossLaunches() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Do the work", fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "On it."),
        ]

        let first = model.turns[0].id
        // A second model built from the same thread is a second launch.
        var again = self.model()
        again.history = model.history
        XCTAssertEqual(again.turns[0].id, first)
    }

    func testFindCanSayWhereARowIs() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "First", fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "read_file", isTool: true),
            MacTranscriptModel.HistoryEntry(id: "h3", text: "bash", isTool: true),
            MacTranscriptModel.HistoryEntry(id: "h4", text: "Second", fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h5", text: "edit_file", isTool: true),
        ]

        // The second tool of the second turn:  "turn 2, tool 1".
        let location = model.location(of: "h5")

        XCTAssertEqual(location?.turn, 2)
        XCTAssertEqual(location?.tool, 1)
        // A row that is not a tool call has no tool number.
        XCTAssertNil(model.location(of: "h4")?.tool)
    }

    func testTheCountsDoNotChangeWhenTheToolCallsAreCollapsed() {
        var model = self.model()
        model.verbosity = .normal
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Do the work", fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "read_file", isTool: true),
            MacTranscriptModel.HistoryEntry(id: "h3", text: "edit_file", isTool: true),
            MacTranscriptModel.HistoryEntry(id: "h4", text: "bash", isTool: true),
        ]

        // The ledger counts the calls that really happened, not the rows
        // that survived the collapsing.
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.turns[0].toolCount, 3)
        XCTAssertEqual(model.turns[0].fileCount, 2)
    }

    func testTheRowsBeforeAnyPromptAreATurnOfTheirOwn() {
        var model = self.model()
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "An earlier answer"),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "Do the work", fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h3", text: "On it."),
        ]

        XCTAssertEqual(model.turns.count, 2)
        XCTAssertEqual(model.turns[0].rowIDs, ["h1"])
        XCTAssertEqual(model.turns[1].rowIDs, ["h2", "h3"])
    }

    func testACollapsedRunSaysWhatItDid() {
        var model = self.model()
        model.verbosity = .normal
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Do the work", fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "read_file", isTool: true),
            MacTranscriptModel.HistoryEntry(id: "h3", text: "edit_file", isTool: true),
            MacTranscriptModel.HistoryEntry(id: "h4", text: "bash", isTool: true),
            MacTranscriptModel.HistoryEntry(id: "h5", text: "run_tests", isTool: true),
        ]

        // The count alone says how much happened and not what, so the row
        // names the kinds.
        let group = model.rows.first { $0.kind == .toolGroup }
        XCTAssertEqual(group?.text, "2 files, 1 command, 1 test")
        XCTAssertEqual(group?.toolCount, 4)
    }

    func testACollapsedRunOfOneCallKeepsTheCall() {
        var model = self.model()
        model.verbosity = .normal
        model.history = [
            MacTranscriptModel.HistoryEntry(id: "h1", text: "Do the work", fromAgent: false),
            MacTranscriptModel.HistoryEntry(id: "h2", text: "read_file", isTool: true),
            MacTranscriptModel.HistoryEntry(id: "h3", text: "On it."),
        ]

        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.rows[1].kind, .tool)
    }
}
