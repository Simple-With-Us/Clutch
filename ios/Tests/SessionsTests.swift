import XCTest
@testable import Clutch

final class AcpSessionTests: XCTestCase {
    func testMuseAuthenticationOnlyAcceptsSafeBrowserURLs() throws {
        let valid = EngineAuthenticationAttempt(attemptId: "a", state: "waiting", url: "https://auth.meta.ai/device", message: "Enter the code", error: nil)
        XCTAssertEqual(valid.verificationURL?.host, "auth.meta.ai")
        for address in ["file:///etc/passwd", "javascript:alert(1)", "http://example.com", "https://user:password@example.com"] {
            var attempt = valid
            attempt.url = address
            XCTAssertNil(attempt.verificationURL)
        }
        let payload = Data(#"{"attemptId":"a","state":"complete"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(EngineAuthenticationAttempt.self, from: payload).state, "complete")
        XCTAssertTrue(EngineAuthenticationAttempt.isRequired("log in to Muse before opening a session"))
        XCTAssertFalse(EngineAuthenticationAttempt.isRequired("Session already open"))
    }

    func testDecodesAPermissionRequestFromTheStream() throws {
        let payload = """
        {"requestId":"perm-7","title":"Run rm -rf build","toolName":"bash",
         "options":[{"optionId":"allow-once","kind":"allow_once","name":"Allow once"},
                    {"optionId":"reject-once","kind":"reject_once","name":"Reject"}]}
        """
        let event = ChatSessionClient.decode(event: "permission", payload: payload)
        guard case .permission(let request) = event else {
            return XCTFail("expected a permission event, got \(String(describing: event))")
        }
        XCTAssertEqual(request.requestId, "perm-7")
        XCTAssertEqual(request.headline, "Run rm -rf build")
        XCTAssertEqual(request.options.count, 2)
        XCTAssertTrue(request.options[0].allows)
        XCTAssertFalse(request.options[1].allows)
    }

    func testDecodesThePlanFromTheStream() throws {
        let payload = """
        {"entries":[{"content":"Read the failing test","priority":"high","status":"in_progress"},
                    {"content":"Fix it","priority":"medium","status":"pending"}]}
        """
        let event = ChatSessionClient.decode(event: "plan", payload: payload)
        guard case .plan(let entries) = event else {
            return XCTFail("expected a plan event, got \(String(describing: event))")
        }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].content, "Read the failing test")
        XCTAssertTrue(entries[0].isActive)
        XCTAssertFalse(entries[0].isDone)
        XCTAssertFalse(entries[1].isActive)
    }

    func testPermissionHeadlineFallsBackToTheToolName() {
        let request = AcpPermissionRequest(
            requestId: "perm-1",
            title: "  ",
            toolName: "write_file",
            options: []
        )
        XCTAssertEqual(request.headline, "write_file")
    }

    func testDecodesSidecarSessionPayload() throws {
        let json = """
        {"sessions":[{"sessionId":"s-1","cwd":"/Users/jay/lanes/foo","title":"Fix the flaky test","updatedAt":"2026-10-16T09:41:07.412Z"}]}
        """
        struct Payload: Decodable { var sessions: [AcpSessionInfo] }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.sessions.count, 1)
        let session = try XCTUnwrap(payload.sessions.first)
        XCTAssertEqual(session.sessionId, "s-1")
        XCTAssertEqual(session.cwd, "/Users/jay/lanes/foo")
        XCTAssertEqual(session.title, "Fix the flaky test")
        XCTAssertEqual(session.id, "s-1")
        XCTAssertNotNil(session.updated)
    }

    func testDisplayTitleFallsBackToWorkspaceThenUntitled() {
        let titled = AcpSessionInfo(sessionId: "a", cwd: "/tmp/x", title: "Named")
        XCTAssertEqual(titled.displayTitle, "Named")

        let blankTitle = AcpSessionInfo(sessionId: "b", cwd: "/Users/jay/lanes/foo", title: "   ")
        XCTAssertEqual(blankTitle.displayTitle, "foo")

        let bare = AcpSessionInfo(sessionId: "c")
        XCTAssertEqual(bare.displayTitle, "Untitled Session")
    }

    func testUpdatedDateToleratesBothISO8601Forms() {
        let fractional = AcpSessionInfo.updatedDate("2026-10-16T09:41:07.412Z")
        let plain = AcpSessionInfo.updatedDate("2026-10-16T09:41:07Z")
        XCTAssertNotNil(fractional)
        XCTAssertNotNil(plain)
        // Both forms name the same wall-clock second, and the fractional one
        // simply carries the extra precision, so they land well inside a
        // second of each other rather than in different minutes or days.
        XCTAssertEqual(fractional?.timeIntervalSince1970 ?? 0, plain?.timeIntervalSince1970 ?? -1, accuracy: 1.0)
        XCTAssertNil(AcpSessionInfo.updatedDate(nil))
        XCTAssertNil(AcpSessionInfo.updatedDate(""))
        XCTAssertNil(AcpSessionInfo.updatedDate("not a date"))
    }

    func testHistoryVisibilityKeepsConversationAndDropsToolChatter() {
        func entry(_ kind: String) -> AcpHistoryEntry {
            AcpHistoryEntry(sessionId: "s", kind: kind, text: "t")
        }
        XCTAssertTrue(entry("user_message").isVisible)
        XCTAssertTrue(entry("assistant_message").isVisible)
        XCTAssertFalse(entry("tool_call").isVisible)
        XCTAssertFalse(entry("thought").isVisible)
        XCTAssertTrue(entry("user_message").isUser)
        XCTAssertFalse(entry("assistant_message").isUser)
    }

    /// The sidecar replays ACP chunk kinds; if those are filtered out the
    /// phone transcript renders blank even though the thread loaded.
    func testHistoryVisibilityAcceptsReplayedChunkKinds() {
        func entry(_ kind: String) -> AcpHistoryEntry {
            AcpHistoryEntry(sessionId: "s", kind: kind, text: "t")
        }
        XCTAssertTrue(entry("user_message_chunk").isVisible)
        XCTAssertTrue(entry("agent_message_chunk").isVisible)
        XCTAssertTrue(entry("user_message_chunk").isUser)
        XCTAssertFalse(entry("agent_message_chunk").isUser)
        XCTAssertFalse(entry("agent_thought_chunk").isVisible)
    }

    func testFilteredMatchesTitleCwdAndIdCaseInsensitively() {
        let a = AcpSessionInfo(sessionId: "s-1", cwd: "/srv/Clutch", title: "Fix Login")
        let b = AcpSessionInfo(sessionId: "s-2", cwd: "/srv/other", title: "Write Docs")
        XCTAssertEqual(AcpSessionInfo.filtered([a, b], query: "login").map(\.sessionId), ["s-1"])
        XCTAssertEqual(AcpSessionInfo.filtered([a, b], query: "CLUTCH").map(\.sessionId), ["s-1"])
        XCTAssertEqual(AcpSessionInfo.filtered([a, b], query: "s-2").map(\.sessionId), ["s-2"])
        XCTAssertEqual(AcpSessionInfo.filtered([a, b], query: "  ").count, 2)
        XCTAssertTrue(AcpSessionInfo.filtered([a, b], query: "nope").isEmpty)
    }

    func testFilteredAlsoMatchesModelProviderAndProject() {
        let a = AcpSessionInfo(
            sessionId: "s-1",
            title: "One",
            usage: AcpSessionUsage(provider: "minimax", model: "MiniMax-M3"),
            projectId: "proj-clutch"
        )
        let b = AcpSessionInfo(sessionId: "s-2", title: "Two")
        XCTAssertEqual(AcpSessionInfo.filtered([a, b], query: "m3").map(\.sessionId), ["s-1"])
        XCTAssertEqual(AcpSessionInfo.filtered([a, b], query: "MINIMAX").map(\.sessionId), ["s-1"])
        XCTAssertEqual(AcpSessionInfo.filtered([a, b], query: "proj-clutch").map(\.sessionId), ["s-1"])
    }

    func testToolHistoryEntriesAreMarkedForCards() {
        let entry = AcpHistoryEntry(sessionId: "s", kind: "tool_call", text: "Read file", toolCallId: "t1", toolStatus: "completed")
        XCTAssertTrue(entry.isTool)
        XCTAssertFalse(entry.isVisible)
        let plain = AcpHistoryEntry(sessionId: "s", kind: "agent_message_chunk", text: "hi")
        XCTAssertFalse(plain.isTool)
        XCTAssertNil(plain.toolCallId)
    }

    func testGroupedFloatsPinnedAboveDateBuckets() {
        let pinned = AcpSessionInfo(sessionId: "old-but-pinned", updatedAt: "2026-09-01T12:00:00Z")
        let today = AcpSessionInfo(sessionId: "today", updatedAt: "2026-10-16T08:00:00Z")
        let now = AcpSessionInfo.updatedDate("2026-10-16T12:00:00Z")!
        let groups = AcpSessionInfo.grouped([pinned, today], pinned: ["old-but-pinned"], now: now)
        XCTAssertEqual(groups.map(\.title), ["Pinned", "Today"])
        XCTAssertEqual(groups.first?.sessions.map(\.sessionId), ["old-but-pinned"])
    }

    func testTranscriptExportRendersRolesAndTools() {
        let markdown = TranscriptExport.markdown(
            title: "Fix Login",
            cwd: "/srv/app",
            entries: [
                TranscriptExport.Entry(role: .user, text: "Fix it"),
                TranscriptExport.Entry(role: .tool, text: "Read file"),
                TranscriptExport.Entry(role: .assistant, text: "Done"),
            ],
            exportedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(markdown.contains("# Fix Login"))
        XCTAssertTrue(markdown.contains("## You"))
        XCTAssertTrue(markdown.contains("**Tool:** Read file"))
        XCTAssertTrue(markdown.contains("## Assistant"))
    }

    func testGroupedBucketsByRecencyAndSinksUndated() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(AcpSessionInfo.updatedDate("2026-10-16T12:00:00Z"))
        func session(_ id: String, _ stamp: String?) -> AcpSessionInfo {
            AcpSessionInfo(sessionId: id, updatedAt: stamp)
        }
        let groups = AcpSessionInfo.grouped([
            session("older", "2026-09-01T12:00:00Z"),
            session("today", "2026-10-16T08:00:00Z"),
            session("undated", nil),
            session("week", "2026-10-12T12:00:00Z"),
            session("yesterday", "2026-10-15T12:00:00Z"),
        ], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "Previous 7 Days", "Older", "Undated"])
        XCTAssertEqual(groups.first?.sessions.map(\.sessionId), ["today"])
        XCTAssertEqual(groups.last?.sessions.map(\.sessionId), ["undated"])
    }

    func testEngineCatalogDecodesTheSidecarCatalog() throws {
        let json = """
        {"engines":[
          {"id":"muse","label":"Muse Code","available":true,
           "models":[{"id":"muse-wonder-1.0","label":"muse-wonder-1.0","value":"muse-wonder-1.0","contextWindow":1007997}],
           "effortLevels":["none","high"],"effortConfigId":"reasoningEffort","modelConfigId":"model"},
          {"id":"mcode","label":"MiniMax Code","available":false,"models":[],"effortLevels":[],"effortConfigId":"thinkingEffort","modelConfigId":"model"}
        ]}
        """
        let catalog = try JSONDecoder().decode(EngineCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.engines.count, 2)
        XCTAssertEqual(catalog.availableEngines.map(\.id), ["muse"])
        XCTAssertEqual(catalog.defaultEngineId, "muse")

        let muse = try XCTUnwrap(catalog.descriptor("muse"))
        XCTAssertTrue(muse.supportsThreads)
        XCTAssertEqual(muse.models.map(\.id), ["muse-wonder-1.0"])
        XCTAssertEqual(muse.models[0].contextSummary, "1.0M")
        XCTAssertEqual(muse.effortLevels, ["none", "high"])

        let mcode = try XCTUnwrap(catalog.descriptor("mcode"))
        XCTAssertFalse(mcode.available)
        XCTAssertTrue(mcode.supportsThreads)
    }

    func testEngineCatalogReadsThePublishedThreadCapability() throws {
        // The sidecar publishes which engines list their threads, so the app
        // never hardcodes it.
        let json = """
        {"engines":[
          {"id":"deepseek","label":"DeepSeek","available":true,"supportsThreads":true,
           "models":[],"effortLevels":["high"],"effortConfigId":"reasoning_effort","modelConfigId":"model"},
          {"id":"minimax","label":"MiniMax","available":true,"supportsThreads":false,
           "models":[],"effortLevels":[],"effortConfigId":"reasoning_effort","modelConfigId":"model"}
        ]}
        """
        let catalog = try JSONDecoder().decode(EngineCatalog.self, from: Data(json.utf8))
        let deepseek = try XCTUnwrap(catalog.descriptor("deepseek"))
        XCTAssertTrue(deepseek.supportsThreads)
        let minimax = try XCTUnwrap(catalog.descriptor("minimax"))
        XCTAssertFalse(minimax.supportsThreads)
    }

    func testEngineLabelsCoverEveryEngine() {
        XCTAssertEqual(EngineLabels.label(for: "deepseek"), "DeepSeek")
        XCTAssertEqual(EngineLabels.label(for: "minimax"), "MiniMax")
        XCTAssertEqual(EngineLabels.label(for: "mcode"), "MiniMax Code")
        XCTAssertEqual(EngineLabels.label(for: "muse"), "Muse Code")
        XCTAssertEqual(EngineLabels.label(for: "something-new"), "something-new")
    }

    func testPinStoreTogglesPerHost() {
        let name = "PinStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let hostA = UUID()
        let hostB = UUID()
        XCTAssertFalse(ThreadPinStore.isPinned("s-1", forHost: hostA, defaults: defaults))
        XCTAssertTrue(ThreadPinStore.toggle("s-1", forHost: hostA, defaults: defaults))
        XCTAssertTrue(ThreadPinStore.isPinned("s-1", forHost: hostA, defaults: defaults))
        XCTAssertFalse(ThreadPinStore.isPinned("s-1", forHost: hostB, defaults: defaults))
        XCTAssertFalse(ThreadPinStore.toggle("s-1", forHost: hostA, defaults: defaults))
        XCTAssertTrue(ThreadPinStore.pinnedIDs(forHost: hostA, defaults: defaults).isEmpty)
    }

    /// The Mac rail and the iOS sidebar share this ordering, so a thread must
    /// land in the same slot on both platforms.
    func testNewestFirstOrdersDatedRowsAndSinksUnreadableStamps() {
        let old = AcpSessionInfo(sessionId: "old", updatedAt: "2026-10-15T09:00:00Z")
        let new = AcpSessionInfo(sessionId: "new", updatedAt: "2026-10-16T09:00:00Z")
        let brokenA = AcpSessionInfo(sessionId: "broken-a", updatedAt: "not a date")
        let brokenB = AcpSessionInfo(sessionId: "broken-b", updatedAt: nil)

        let ordered = AcpSessionInfo.newestFirst([old, brokenA, new, brokenB])
        XCTAssertEqual(ordered.map(\.sessionId), ["new", "old", "broken-a", "broken-b"])
    }

    /// Two rows sharing an instant must not swap places between reloads of the
    /// same payload, or the list flickers under the user's finger.
    func testNewestFirstIsStableForEqualInstants() {
        let stamp = "2026-10-16T09:00:00Z"
        let first = AcpSessionInfo(sessionId: "first", updatedAt: stamp)
        let second = AcpSessionInfo(sessionId: "second", updatedAt: stamp)
        let ordered = AcpSessionInfo.newestFirst([first, second])
        XCTAssertEqual(ordered.map(\.sessionId), ["first", "second"])
    }

    func testNewestFirstHandlesEmptyInput() {
        XCTAssertTrue(AcpSessionInfo.newestFirst([]).isEmpty)
    }
}
