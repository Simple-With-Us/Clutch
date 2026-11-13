import XCTest
@testable import Clutch

final class MacThreadWindowRequestTests: XCTestCase {
    func testWindowRequestRoundTripsHostEngineAndOptionalThreadIdentity() throws {
        let request = MacThreadWindowRequest(
            windowID: UUID(uuidString: "1391DD58-5A73-46D2-9E26-38B42EF12345")!,
            hostID: UUID(uuidString: "92CECF14-FDB9-4D43-BA9A-0CE5B0946A3D")!,
            engineID: "muse",
            sessionID: "remote-session-7",
            cwd: "/srv/work/tree",
            title: "Review the migration"
        )
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(MacThreadWindowRequest.self, from: data), request)

        let newThread = MacThreadWindowRequest(hostID: request.hostID, engineID: request.engineID, cwd: request.cwd)
        XCTAssertNotEqual(newThread.windowID, request.windowID)
        XCTAssertNil(newThread.sessionID)
        XCTAssertNil(newThread.title)
    }

    func testPreviewUsesItsCwdOrMatchingSidebarTargetFallback() {
        XCTAssertEqual(
            MacThreadPreviewWorkspace.cwd(
                previewCwd: nil,
                previewSessionID: "session-a",
                targetSessionID: "session-a",
                targetCwd: "/srv/work/a"
            ),
            "/srv/work/a"
        )
        XCTAssertEqual(
            MacThreadPreviewWorkspace.cwd(
                previewCwd: "/srv/work/preview",
                previewSessionID: "session-a",
                targetSessionID: "session-a",
                targetCwd: "/srv/work/a"
            ),
            "/srv/work/preview"
        )
        XCTAssertNil(
            MacThreadPreviewWorkspace.cwd(
                previewCwd: nil,
                previewSessionID: "session-a",
                targetSessionID: "session-b",
                targetCwd: "/srv/work/b"
            )
        )
        XCTAssertEqual(
            MacThreadPreviewWorkspace.cwd(
                previewCwd: "  ",
                previewSessionID: "session-a",
                targetSessionID: "session-a",
                targetCwd: "/srv/work/a"
            ),
            "/srv/work/a"
        )
    }

    func testFolderChoicesIncludeAncestorFoldersAndHideFilesystemRoot() {
        XCTAssertEqual(
            MacThreadFolderScope.folderOptions(from: ["/srv/work/clutch", "/srv/work/other"]),
            ["/srv", "/srv/work", "/srv/work/clutch", "/srv/work/other"]
        )
        XCTAssertEqual(MacThreadFolderScope.folderOptions(from: []), [])
    }

    func testLoadMoreLimitsGrowByOneHundredAndStopAtOneThousand() {
        XCTAssertEqual(MacThreadFolderScope.nextLimit(after: 100), 200)
        XCTAssertEqual(MacThreadFolderScope.nextLimit(after: 950), 1000)
        XCTAssertNil(MacThreadFolderScope.nextLimit(after: 1000))
    }
}

@MainActor
final class MacRunningSessionRegistryTests: XCTestCase {
    func testClaimsAreExclusivePerHostEngineAndSessionUntilOwnerReleases() {
        let registry = MacRunningSessionRegistry()
        let firstOwner = UUID()
        let secondOwner = UUID()
        let host = UUID()

        XCTAssertTrue(registry.claim(hostID: host, engineID: "muse", sessionID: "thread-1", owner: firstOwner))
        XCTAssertTrue(registry.isRunning(hostID: host, engineID: "muse", sessionID: "thread-1"))
        XCTAssertFalse(registry.claim(hostID: host, engineID: "muse", sessionID: "thread-1", owner: secondOwner))
        XCTAssertTrue(registry.claim(hostID: host, engineID: "muse", sessionID: "thread-2", owner: secondOwner))
        XCTAssertTrue(registry.claim(hostID: UUID(), engineID: "muse", sessionID: "thread-1", owner: secondOwner))
        XCTAssertTrue(registry.claim(hostID: host, engineID: "minimax", sessionID: "thread-1", owner: secondOwner))

        registry.release(owner: firstOwner)
        XCTAssertFalse(registry.isRunning(hostID: host, engineID: "muse", sessionID: "thread-1"))
        XCTAssertTrue(registry.isRunning(hostID: host, engineID: "muse", sessionID: "thread-2"))
    }
}
