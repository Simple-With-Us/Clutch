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

    func testUncorrelatedToolsRemainDistinctAndUseSafeFallbackNames() {
        var turn = ChatTurnBuffer()
        turn.updateTool(id: "", name: "Read File", status: "running")
        turn.updateTool(id: "", name: "Read File", status: "completed")
        turn.updateTool(id: "", name: "", status: "running")

        let tools = turn.finish()?.tools ?? []
        XCTAssertEqual(tools.count, 3)
        XCTAssertEqual(Set(tools.map(\.id)).count, 3)
        XCTAssertEqual(tools.map(\.name), ["Read File", "Read File", "Tool Call"])
    }

    func testToolUpdatesCannotMatchRowsFromEarlierTurns() {
        let priorTurn = [
            AcpHistoryEntry(sessionId: "s", kind: "tool_call", text: "Earlier call", toolCallId: "reused"),
            AcpHistoryEntry(sessionId: "s", kind: "agent_message_chunk", text: "Earlier reply"),
            AcpHistoryEntry(sessionId: "s", kind: "tool_call", text: "Current call", toolCallId: "current"),
        ]

        XCTAssertNil(ChatTurnBuffer.latestToolIndex(in: priorTurn, matching: "reused", from: 2))
        XCTAssertEqual(ChatTurnBuffer.latestToolIndex(in: priorTurn, matching: "current", from: 2), 2)
        XCTAssertNil(ChatTurnBuffer.latestToolIndex(in: priorTurn, matching: "other", from: 1))
        XCTAssertNil(ChatTurnBuffer.latestToolIndex(in: priorTurn, matching: "reused", from: priorTurn.count + 1))
    }
}
