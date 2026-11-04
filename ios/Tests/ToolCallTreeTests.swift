import XCTest
@testable import Clutch

/// The tool call tree.
///
/// A tool that runs other tools is the parent of them, and the clients show
/// the children hanging under it, the way the web canvas shows them.  These
/// tests pin the two halves of that: the relation the sidecar sends, and the
/// depth the client works out from it.
final class ToolCallTreeTests: XCTestCase {
    func testDecodesAToolCallWithItsParentAndInput() throws {
        let payload = """
        {"id":"call-2","name":"Read","status":"running",
         "parentId":"call-1","input":"{\\"path\\":\\"README.md\\"}"}
        """
        let event = ChatSessionClient.decode(event: "tool", payload: payload)
        guard case .tool(let call) = event else {
            return XCTFail("expected a tool event, got \(String(describing: event))")
        }
        XCTAssertEqual(call.id, "call-2")
        XCTAssertEqual(call.name, "Read")
        XCTAssertEqual(call.status, "running")
        XCTAssertEqual(call.parentId, "call-1")
        XCTAssertEqual(call.input, "{\"path\":\"README.md\"}")
    }

    func testDecodesAToolCallThatHasNoParent() throws {
        let payload = """
        {"id":"call-1","name":"Bash","status":"completed"}
        """
        let event = ChatSessionClient.decode(event: "tool", payload: payload)
        guard case .tool(let call) = event else {
            return XCTFail("expected a tool event, got \(String(describing: event))")
        }
        XCTAssertNil(call.parentId)
        XCTAssertNil(call.input)
    }

    func testACallWithNoParentSitsAtTheTop() {
        let parents = ["call-2": "call-1"]
        XCTAssertEqual(ToolCallDepth.depth(of: "call-1", parents: parents), 0)
        XCTAssertEqual(ToolCallDepth.depth(of: "call-2", parents: parents), 1)
    }

    func testACallUnderACallUnderACallSitsTwoDeep() {
        let parents = ["call-2": "call-1", "call-3": "call-2"]
        XCTAssertEqual(ToolCallDepth.depth(of: "call-3", parents: parents), 2)
    }

    func testACallWhoseParentWasNeverSeenStillShows() {
        // The parent is missing, so the call sits one down rather than
        // disappearing from the thread.
        XCTAssertEqual(ToolCallDepth.depth(of: "call-9", parents: ["call-9": "call-8"]), 1)
    }

    func testALoopInTheCallsDoesNotSpinForever() {
        let parents = ["call-1": "call-2", "call-2": "call-1"]
        let depth = ToolCallDepth.depth(of: "call-1", parents: parents)
        XCTAssertLessThanOrEqual(depth, ToolCallDepth.maximum)
    }

    func testACallWithNoIdSitsAtTheTop() {
        XCTAssertEqual(ToolCallDepth.depth(of: nil, parents: [:]), 0)
        XCTAssertEqual(ToolCallDepth.depth(of: "", parents: [:]), 0)
    }

    func testTheTurnBufferKeepsTheRelationAndTheInput() {
        var buffer = ChatTurnBuffer()
        buffer.updateTool(id: "call-2", name: "Read", status: "running", parentId: "call-1", input: "{}")
        XCTAssertEqual(buffer.tools.count, 1)
        XCTAssertEqual(buffer.tools[0].parentId, "call-1")
        XCTAssertEqual(buffer.tools[0].input, "{}")
    }

    func testTheTurnBufferKeepsTheRelationWhenTheCallIsUpdated() {
        var buffer = ChatTurnBuffer()
        buffer.updateTool(id: "call-2", name: "Read", status: "running", parentId: "call-1")
        buffer.updateTool(id: "call-2", name: "Read", status: "completed")
        XCTAssertEqual(buffer.tools.count, 1)
        XCTAssertEqual(buffer.tools[0].status, "completed")
        XCTAssertEqual(buffer.tools[0].parentId, "call-1")
    }

    @MainActor
    func testAReloadedThreadKeepsTheTree() {
        // A reloaded thread is built from the history, not from the live
        // events, so the relation and the input have to travel with the
        // history too.  Without them the cards come back flat.
        let history = [
            AcpHistoryEntry(sessionId: "s", kind: "tool_call", text: "Bash", toolCallId: "call-1", toolStatus: "completed"),
            AcpHistoryEntry(
                sessionId: "s",
                kind: "tool_call",
                text: "Read",
                toolCallId: "call-2",
                toolStatus: "completed",
                parentToolCallId: "call-1",
                toolInput: "{\"path\":\"README.md\"}"
            )
        ]
        let bubbles = SessionThreadModel.bubbles(from: history)
        XCTAssertEqual(bubbles.count, 2)
        XCTAssertEqual(bubbles[1].toolCallId, "call-2")
        XCTAssertEqual(bubbles[1].toolParentId, "call-1")
        XCTAssertEqual(bubbles[1].toolInput, "{\"path\":\"README.md\"}")

        var parents: [String: String] = [:]
        for bubble in bubbles {
            guard let id = bubble.toolCallId, let parent = bubble.toolParentId else { continue }
            parents[id] = parent
        }
        XCTAssertEqual(ToolCallDepth.depth(of: bubbles[1].toolCallId, parents: parents), 1)
    }
}
