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
}
