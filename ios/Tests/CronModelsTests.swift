import XCTest
@testable import Clutch

final class CronModelsTests: XCTestCase {
    func testDecodesACronList() throws {
        let payload = """
        {"crons":[
          {"id":"a1","sessionId":"sess-1","kind":"after","prompt":"water plants","scheduledAt":"2026-11-26T13:00:00.000Z","afterSeconds":600,"state":"scheduled","deliveryMode":"session-local"},
          {"id":"b2","sessionId":"sess-2","kind":"every","prompt":"standup notes","scheduledAt":"2026-11-26T11:00:00.000Z","everySeconds":3600,"state":"overdue","deliveryMode":"session-local"}
        ]}
        """
        let list = try JSONDecoder().decode(CronList.self, from: Data(payload.utf8))
        XCTAssertEqual(list.crons.count, 2)
        XCTAssertEqual(list.crons[0].ruleLabel, "In 10 min")
        XCTAssertEqual(list.crons[1].ruleLabel, "Every 1 hr")
        XCTAssertEqual(list.crons[1].state, "overdue")
        XCTAssertNotNil(list.crons[0].scheduledDate)
    }

    func testAtRuleNamesTheInstant() {
        let cron = CronItem(
            id: "c3", sessionId: "sess-1", kind: "at", prompt: "call",
            scheduledAt: "2026-12-01T09:00:00.000Z", state: "scheduled"
        )
        XCTAssertTrue(cron.ruleLabel.contains("2026"))
        XCTAssertNotNil(cron.scheduledDate)
    }
}
