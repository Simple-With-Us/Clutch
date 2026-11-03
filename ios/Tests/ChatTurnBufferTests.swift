import XCTest
@testable import Clutch

final class ChatTurnBufferTests: XCTestCase {
    func testKeepsPartialTextAndLatestToolStateWhenStreamEnds() {
        var turn = ChatTurnBuffer()
        turn.append("Already received. ")
        turn.append("Still visible.")
        turn.updateTool(id: "t", name: "Read File", status: "running")
        turn.updateTool(id: "t", name: "", status: "completed")
        let snapshot = turn.finish()
        XCTAssertEqual(snapshot?.text, "Already received. Still visible.")
        XCTAssertEqual(snapshot?.tools, [.init(id: "t", name: "Read File", status: "completed")])
        XCTAssertEqual(turn.text, "")
        XCTAssertTrue(turn.tools.isEmpty)
    }

    func testCancelRacingCompletionCommitsOnlyOnceAndIgnoresLateChunks() {
        var turn = ChatTurnBuffer()
        turn.append("Keep this partial reply")
        XCTAssertNotNil(turn.finish())
        turn.append("late text")
        turn.updateTool(id: "late", name: "Late Tool", status: "running")
        XCTAssertNil(turn.finish())
        XCTAssertEqual(turn.text, "")
        XCTAssertTrue(turn.tools.isEmpty)
    }

    func testNewTurnStartsWithAnIndependentBuffer() {
        var old = ChatTurnBuffer()
        old.append("Previous reply")
        _ = old.finish()
        var current = ChatTurnBuffer()
        current.append("New reply")
        XCTAssertEqual(current.finish()?.text, "New reply")
        XCTAssertNil(old.finish())
    }

    func testSteeringCanRetainEarlierTextWithoutEndingTheTurn() {
        var turn = ChatTurnBuffer()
        turn.append("Before steering")
        XCTAssertEqual(turn.drain().text, "Before steering")
        XCTAssertFalse(turn.finished)
        turn.append("After steering")
        XCTAssertEqual(turn.finish()?.text, "After steering")
    }
}
