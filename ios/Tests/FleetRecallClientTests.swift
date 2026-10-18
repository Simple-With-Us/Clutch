import XCTest
@testable import Clutch

/// Covers the client-side rules and response mapping for fleet recall.  Nothing
/// here touches the network: the transport is a private helper, and what matters
///  is that a bad lesson never reaches it and that the corpus's answer is read
///  honestly once it comes back.
final class FleetRecallClientTests: XCTestCase {

    // MARK: - Category

    func testRejectsCategoryOutsideTheAllowedSet() {
        for bad in ["", "finding", "note", "doc", "board", "lesson;decision", "  "] {
            var draft = validDraft()
            draft.category = bad
            XCTAssertEqual(draft.validate(), .invalidCategory, "category \"\(bad)\" should be rejected")
        }
    }

    func testAcceptsEveryAllowedCategory() {
        for name in ["lesson", "preference", "infrastructure", "decision", "runbook"] {
            var draft = validDraft()
            draft.category = name
            XCTAssertNil(draft.validate(), "category \(name) should be accepted")
        }
    }

    func testNormalizesCategoryCaseAndWhitespace() {
        var draft = validDraft()
        draft.category = "  Runbook  "
        XCTAssertNil(draft.validate())
        XCTAssertEqual(draft.normalizedCategory, "runbook")
        XCTAssertEqual(draft.arguments["category"] as? String, "runbook")
    }

    func testAllowedCategoriesMatchTheServerEnum() {
        XCTAssertEqual(
            RecallCategory.allCases.map(\.rawValue),
            ["lesson", "preference", "infrastructure", "decision", "runbook"]
        )
    }

    // MARK: - Length

    func testRejectsTextBelowTheMinimum() {
        for count in [0, 1, 39] {
            var draft = validDraft()
            draft.text = String(repeating: "a", count: count)
            XCTAssertEqual(draft.validate(), .textTooShort, "\(count) characters should be too short")
        }
    }

    func testAcceptsTextAtTheExactBounds() {
        var draft = validDraft()
        draft.text = String(repeating: "a", count: RecallContributionDraft.minTextLength)
        XCTAssertNil(draft.validate(), "the exact minimum should be accepted")

        draft.text = String(repeating: "a", count: RecallContributionDraft.maxTextLength)
        XCTAssertNil(draft.validate(), "the exact maximum should be accepted")
    }

    func testRejectsTextAboveTheMaximum() {
        var draft = validDraft()
        draft.text = String(repeating: "a", count: RecallContributionDraft.maxTextLength + 1)
        XCTAssertEqual(draft.validate(), .textTooLong)
    }

    func testLeadingWhitespaceDoesNotCountTowardTheMinimum() {
        var draft = validDraft()
        draft.text = "   " + String(repeating: "a", count: RecallContributionDraft.minTextLength - 1)
        XCTAssertEqual(draft.validate(), .textTooShort)
    }

    func testCategoryIsCheckedBeforeLength() {
        var draft = validDraft()
        draft.category = "nonsense"
        draft.text = "too short"
        XCTAssertEqual(draft.validate(), .invalidCategory)
    }

    // MARK: - Contribute arguments

    func testArgumentsOmitBlankOptionalFields() {
        var draft = validDraft()
        draft.title = "   "
        draft.app = ""
        draft.seat = "  "
        let arguments = draft.arguments
        XCTAssertNil(arguments["title"])
        XCTAssertNil(arguments["app"])
        XCTAssertNil(arguments["seat"])
        XCTAssertEqual(arguments["text"] as? String, draft.text)
    }

    func testArgumentsCarrySeatAndTitleWhenPresent() {
        var draft = validDraft()
        draft.title = "  Recall Endpoint Lessons  "
        draft.seat = "MM"
        XCTAssertEqual(draft.arguments["title"] as? String, "Recall Endpoint Lessons")
        XCTAssertEqual(draft.arguments["seat"] as? String, "MM")
    }

    // MARK: - Response mapping

    func testDuplicateStatusIsTreatedAsSuccess() {
        let outcome = RecallContributionResponse.outcome(from: ["status": "duplicate", "id": "doc-7"])
        XCTAssertEqual(outcome, .duplicate)
        XCTAssertEqual(outcome?.isSuccess, true)
        XCTAssertEqual(outcome?.confirmationTitle, "Already In The Corpus")
        XCTAssertFalse(outcome?.confirmationMessage.isEmpty ?? true)
    }

    func testDuplicateStatusIsRecognizedUnderItsAliasesAndCasing() {
        for raw in ["duplicate", "Duplicate", "  DUPLICATE  ", "already_exists", "exists"] {
            XCTAssertEqual(
                RecallContributionResponse.outcome(from: ["status": raw]),
                .duplicate,
                "\(raw) should read as an existing lesson, not an error"
            )
        }
    }

    func testStoredStatusCarriesTheDocumentID() {
        XCTAssertEqual(RecallContributionResponse.outcome(from: ["status": "stored", "id": "doc-1"]), .stored(docID: "doc-1"))
        XCTAssertEqual(RecallContributionResponse.outcome(from: ["status": "created", "doc_id": "doc-2"]), .stored(docID: "doc-2"))
        XCTAssertEqual(RecallContributionResponse.outcome(from: ["status": "ok", "docId": "doc-3"]), .stored(docID: "doc-3"))
        XCTAssertEqual(RecallContributionResponse.outcome(from: ["status": "added"]), .stored(docID: nil))
        XCTAssertEqual(RecallContributionResponse.outcome(from: ["status": "stored"])?.confirmationTitle, "Lesson Contributed")
    }

    func testUnknownOrMissingStatusIsNotReportedAsSuccess() {
        XCTAssertNil(RecallContributionResponse.outcome(from: ["id": "doc-1"]))
        XCTAssertNil(RecallContributionResponse.outcome(from: ["status": "queued"]))
        XCTAssertNil(RecallContributionResponse.outcome(from: [:]))
        XCTAssertNil(RecallContributionResponse.outcome(from: ["status": 7]))
    }

    func testNonStringDocumentIDsAreRendered() {
        XCTAssertEqual(RecallContributionResponse.outcome(from: ["status": "stored", "id": 42]), .stored(docID: "42"))
    }

    // MARK: - Transport error mapping

    func testTransportFailuresMapToReadableContributionErrors() {
        XCTAssertEqual(RecallTransportError.transport.contributionError, .unreachable)
        XCTAssertEqual(RecallTransportError.statusCode(403).contributionError, .rejected(statusCode: 403))
        XCTAssertEqual(RecallTransportError.serverError.contributionError, .serverRejected)
        XCTAssertEqual(RecallTransportError.unreadablePayload.contributionError, .unrecognizedResponse)
        XCTAssertEqual(RecallTransportError.badEndpoint.contributionError, .badEndpoint)
        XCTAssertEqual(RecallTransportError.malformedRequest.contributionError, .malformedRequest)
    }

    func testErrorMessagesCarryNoServerText() {
        let message = RecallContributionError.rejected(statusCode: 502).message
        XCTAssertTrue(message.contains("502"))
        XCTAssertFalse(message.contains("<"))
        XCTAssertFalse(message.contains("{"))
        for error in [
            RecallContributionError.invalidCategory,
            .textTooShort,
            .textTooLong,
            .badEndpoint,
            .malformedRequest,
            .unreachable,
            .rejected(statusCode: 500),
            .serverRejected,
            .unrecognizedResponse
        ] {
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    // MARK: - Search parsing

    func testSearchReadsTheFieldsTheCorpusSends() throws {
        let payload = """
        {"hits":[{"doc_id":"doc-9","score":0.87,"excerpt":"Recall lives behind Cloudflare Access.","source":"doc","app":"clutch","seat":"MM","heading":"Fleet Recall","title":"Recall Endpoint","path":"ios/App/Services/FleetRecallClient.swift"}]}
        """
        let hits = RecallSearchResponse.hits(from: payload, app: "clutch")
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hit.id, "doc-9")
        XCTAssertEqual(hit.score, 0.87)
        XCTAssertEqual(hit.text, "Recall lives behind Cloudflare Access.")
        XCTAssertEqual(hit.seat, "MM")
        XCTAssertEqual(hit.title, "Recall Endpoint")
    }

    func testSearchLeavesScoreUnsetWhenTheCorpusSendsNone() throws {
        let hits = RecallSearchResponse.hits(from: #"[{"text":"No score here."}]"#, app: "clutch")
        let hit = try XCTUnwrap(hits.first)
        XCTAssertNil(hit.score, "an absent score must stay absent rather than be invented")
    }

    func testSearchAcceptsResultAndMatchKeysAndTopLevelArrays() {
        XCTAssertEqual(RecallSearchResponse.hits(from: #"{"results":[{"text":"a"}]}"#, app: "c").count, 1)
        XCTAssertEqual(RecallSearchResponse.hits(from: #"{"matches":[{"text":"a"}]}"#, app: "c").count, 1)
        XCTAssertEqual(RecallSearchResponse.hits(from: #"[{"text":"a"}]"#, app: "c").count, 1)
    }

    func testUnusableSearchPayloadYieldsNoHitsRatherThanFakeOnes() {
        // A sign-in page or an error body must not become a result set.
        XCTAssertTrue(RecallSearchResponse.hits(from: "<html><body>Sign in</body></html>", app: "clutch").isEmpty)
        XCTAssertTrue(RecallSearchResponse.hits(from: #"{"error":"nope"}"#, app: "clutch").isEmpty)
        XCTAssertTrue(RecallSearchResponse.hits(from: "[]", app: "clutch").isEmpty)
        XCTAssertTrue(RecallSearchResponse.hits(from: "", app: "clutch").isEmpty)
    }

    // MARK: - Stats

    func testStatsReportThemselvesAsPlaceholdersUntilPopulated() {
        XCTAssertTrue(RecallStats().isPlaceholder, "the corpus endpoint serves no confirmed stats call")
        var stats = RecallStats()
        stats.totalChunks = 60_912
        XCTAssertFalse(stats.isPlaceholder)
    }

    // MARK: - Helpers

    private func validDraft() -> RecallContributionDraft {
        RecallContributionDraft(
            title: "Recall Endpoint Rules",
            text: String(repeating: "A lesson that comfortably clears the forty character minimum. ", count: 2),
            category: "lesson",
            app: "clutch",
            seat: "AG"
        )
    }
}