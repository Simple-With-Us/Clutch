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
}
