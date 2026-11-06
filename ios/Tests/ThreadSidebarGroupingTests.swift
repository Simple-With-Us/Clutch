import XCTest
@testable import Clutch

final class ThreadSidebarGroupingTests: XCTestCase {
    func testGroupsProjectsByNamePinnedFirstAndKeepsEverySessionOnce() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(AcpSessionInfo.updatedDate("2026-11-03T12:00:00Z"))
        let projects = [
            SessionsClient.Project(id: "proj-socratic", name: "Socratic Trade"),
            SessionsClient.Project(id: "proj-clutch", name: "Clutch"),
        ]
        let sessions = [
            AcpSessionInfo(sessionId: "pinned", updatedAt: "2026-10-01T00:00:00Z", projectId: "proj-clutch"),
            AcpSessionInfo(sessionId: "clutch", updatedAt: "2026-10-04T00:00:00Z", projectId: "proj-clutch"),
            AcpSessionInfo(sessionId: "socratic", updatedAt: "2026-10-02T00:00:00Z", projectId: "proj-socratic"),
            AcpSessionInfo(sessionId: "unknown", updatedAt: "2026-10-03T00:00:00Z", projectId: "proj-unknown-secret"),
            AcpSessionInfo(sessionId: "unassigned", updatedAt: "2026-11-03T08:00:00Z"),
        ]

        let groups = ThreadSidebarGrouping.groups(
            ordered: sessions,
            projects: projects,
            pinned: ["pinned"],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.title), ["Pinned", "Clutch", "Socratic Trade", "Other Projects", "Today"])
        XCTAssertEqual(groups.map(\.id).first, "pinned")
        XCTAssertFalse(groups.contains { $0.title.contains("proj-unknown-secret") })
        let listedIds = groups.flatMap(\.sessions).map(\.sessionId)
        XCTAssertEqual(listedIds.count, sessions.count)
        XCTAssertEqual(Set(listedIds), Set(sessions.map(\.sessionId)))
    }

    func testSearchMatchesProjectNameWithoutDisplayingProjectId() {
        let project = SessionsClient.Project(id: "private-project-id", name: "Socratic Trade")
        let assigned = AcpSessionInfo(sessionId: "s-1", projectId: project.id)
        let other = AcpSessionInfo(sessionId: "s-2")

        XCTAssertEqual(
            ThreadSidebarGrouping.filtered([assigned, other], query: "socratic trade", projects: [project]).map(\.sessionId),
            ["s-1"]
        )
    }

    func testOmitsAProjectGroupWhenEverySessionInItIsPinned() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(AcpSessionInfo.updatedDate("2026-11-03T12:00:00Z"))
        let projects = [SessionsClient.Project(id: "proj-clutch", name: "Clutch")]
        let sessions = [
            AcpSessionInfo(sessionId: "pinned", updatedAt: "2026-10-01T00:00:00Z", projectId: "proj-clutch"),
        ]

        let groups = ThreadSidebarGrouping.groups(
            ordered: sessions,
            projects: projects,
            pinned: ["pinned"],
            now: now,
            calendar: calendar
        )

        // A pinned thread leaves its project group, and a project with nothing
        // left to show gets no heading of its own.
        XCTAssertEqual(groups.map(\.title), ["Pinned"])
        XCTAssertEqual(groups.flatMap(\.sessions).map(\.sessionId), ["pinned"])
    }
}
