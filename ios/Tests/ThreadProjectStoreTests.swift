import XCTest
@testable import Clutch

final class ThreadProjectStoreTests: XCTestCase {
    @MainActor
    func testSameSessionIDIsIndependentAcrossToolsAndHosts() throws {
        let suite = "codes.clutch.tests.projects.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThreadProjectStore(defaults: defaults)
        let id = try XCTUnwrap(store.create(name: "  Fleet  "))
        let macID = UUID()
        let linuxID = UUID()
        let muse = ProjectThread(hostID: macID, hostName: "Mac", engineID: "muse",
                                 session: AcpSessionInfo(sessionId: "same", cwd: "/Mac/Repo", title: "Muse"))
        let miniMax = ProjectThread(hostID: macID, hostName: "Mac", engineID: "mcode",
                                    session: AcpSessionInfo(sessionId: "same", cwd: "/Mac/Second"))
        let server = ProjectThread(hostID: linuxID, hostName: "Linux", engineID: "muse",
                                   session: AcpSessionInfo(sessionId: "same", cwd: "/server/Repo"))

        for thread in [muse, miniMax, server, muse] { store.add(thread, to: id) }

        let restored = ThreadProjectStore(defaults: defaults)
        XCTAssertEqual(restored.projects.first?.name, "Fleet")
        XCTAssertEqual(restored.projects.first?.threads, [muse, miniMax, server])
        XCTAssertEqual(restored.projects.first?.threads.map { $0.session.cwd }, ["/Mac/Repo", "/Mac/Second", "/server/Repo"])
        XCTAssertEqual(restored.projects.first?.threads.map { $0.id.engineID }, ["muse", "mcode", "muse"])
        restored.remove(miniMax.id, from: id)
        XCTAssertEqual(ThreadProjectStore(defaults: defaults).projects.first?.threads, [muse, server])
    }

    func testOpeningRequiresTheExactPairedHost() throws {
        let origin = try XCTUnwrap(URL(string: "https://localhost"))
        let original = ClutchHost(name: "Original", origin: origin)
        let other = ClutchHost(name: "Original", origin: origin)
        let ref = ProjectThread(hostID: original.id, hostName: original.name, engineID: "muse",
                                session: AcpSessionInfo(sessionId: "thread"))
        XCTAssertNil(ref.pairedHost(in: [other]))
        XCTAssertEqual(ref.pairedHost(in: [other, original])?.id, original.id)
        XCTAssertEqual(ref.session.sessionId, "thread")
    }

    @MainActor
    func testUnreadableStoreDoesNotOverwriteSavedProjects() throws {
        let suite = "codes.clutch.tests.projects.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data("not-json".utf8)
        defaults.set(data, forKey: ThreadProjectStore.storageKey)
        let store = ThreadProjectStore(defaults: defaults)
        XCTAssertTrue(store.storageError)
        XCTAssertNil(store.create(name: "New"))
        XCTAssertEqual(defaults.data(forKey: ThreadProjectStore.storageKey), data)
    }

    @MainActor
    func testMembershipWriteFailureDoesNotChangeStoredOrVisibleReferences() throws {
        struct EncodingUnavailable: Error {}
        let suite = "codes.clutch.tests.projects.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ThreadProjectStore(defaults: defaults)
        let projectID = try XCTUnwrap(first.create(name: "Fleet"))
        let hostID = UUID()
        let existing = ProjectThread(hostID: hostID, hostName: "Mac", engineID: "muse",
                                     session: AcpSessionInfo(sessionId: "kept"))
        let extra = ProjectThread(hostID: hostID, hostName: "Mac", engineID: "muse",
                                  session: AcpSessionInfo(sessionId: "new"))
        XCTAssertTrue(first.add(existing, to: projectID))
        var encodeAttempts = 0
        let failed = ThreadProjectStore(defaults: defaults) { _ in
            encodeAttempts += 1
            throw EncodingUnavailable()
        }
        XCTAssertFalse(failed.storageError)
        XCTAssertFalse(failed.add(extra, to: projectID))
        XCTAssertTrue(failed.storageError)
        XCTAssertNil(failed.create(name: "Blocked"))
        XCTAssertFalse(failed.remove(existing.id, from: projectID))
        XCTAssertEqual(encodeAttempts, 1)
        XCTAssertEqual(failed.projects.first?.threads, [existing])
        XCTAssertEqual(ThreadProjectStore(defaults: defaults).projects.first?.threads, [existing])
    }

    func testInvalidSessionPagesDoNotLookLikeCompleteEmptyLists() throws {
        XCTAssertThrowsError(try SessionsClient.decodeSessionList(Data("{".utf8), limit: 100))
        XCTAssertThrowsError(try SessionsClient.decodeSessionList(Data(#"{"sessions":42}"#.utf8), limit: 100))
        let empty = try SessionsClient.decodeSessionList(Data(#"{"sessions":[]}"#.utf8), limit: 100)
        XCTAssertTrue(empty.sessions.isEmpty)
        XCTAssertFalse(empty.hasMore)
    }

    func testWidePagePreservesExistingRowsAndSortsNewArrivalsFirst() {
        let previous = AcpSessionInfo(sessionId: "current", title: "Before", updatedAt: "2026-11-25T12:00:00Z")
        let current = AcpSessionInfo(sessionId: "current", title: "After", updatedAt: "2026-11-25T12:00:00Z")
        let newest = AcpSessionInfo(sessionId: "new", updatedAt: "2026-11-25T12:01:00Z")
        let older = AcpSessionInfo(sessionId: "old", updatedAt: "2026-11-25T11:00:00Z")
        let page = SessionsClient.SessionListPage(sessions: [current, newest], hasMore: true, limit: 300)
        XCTAssertEqual(page.merging(into: [previous, older]), [newest, current, older])
    }
}
