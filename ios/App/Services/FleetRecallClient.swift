import Foundation
import SwiftUI
import Observation

@Observable
public final class FleetRecallClient {
    public static let shared = FleetRecallClient()

    /// The fleet MCP endpoint.  It sits behind Cloudflare Access, and this client
    ///  sends no service-token headers, so an unauthenticated call is expected to
    ///  come back as a redirect or a sign-in page.  That surfaces as a readable
    ///  error rather than as silent fake data; wiring credentials in is a separate
    ///  change, and guessing a header here would only hide the gap.
    public var endpoint: String = "https://agents.jays.services/mcp"
    public var query: String = ""
    public var searchResults: [RecallHit] = []
    public var isSearching: Bool = false
    public var isContributing: Bool = false
    public var stats: RecallStats = RecallStats()

    /// Non-nil only after a search that could not be completed.  Never populated
    ///  from a fallback list.
    public var searchErrorMessage: String?
    /// True once a search has finished with either results or an error, so the
    ///  view can tell "no matches" apart from "not searched yet".
    public private(set) var hasSearched: Bool = false

    public var contributionSuccessTitle: String?
    public var contributionSuccessMessage: String?

    private let endpointKey = "codes.clutch.fleet_rag_endpoint"

    public init() {
        if let saved = UserDefaults.standard.string(forKey: endpointKey) {
            self.endpoint = saved
        }
    }

    public func saveEndpoint(_ ep: String) {
        self.endpoint = ep
        UserDefaults.standard.set(ep, forKey: endpointKey)
    }

    // MARK: - Search

    /// Runs `recall_search` against the live corpus.  On failure the previous
    ///  results are left untouched and `searchErrorMessage` is set: the corpus
    ///  either answers or the UI says it could not.
    public func search(query: String, app: String = "clutch") async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await MainActor.run {
            self.isSearching = true
            self.searchErrorMessage = nil
            self.hasSearched = false
        }

        let arguments: [String: Any] = ["query": trimmed, "limit": 5, "app": app]
        let outcome = await callTool(name: "recall_search", arguments: arguments)

        await MainActor.run {
            self.isSearching = false
            self.hasSearched = true
            switch outcome {
            case .success(let payload):
                let hits = RecallSearchResponse.hits(from: payload, app: app)
                self.searchResults = hits
                if hits.isEmpty {
                    self.searchErrorMessage = SearchFailure.unreadable.message
                }
            case .failure(let error):
                self.searchErrorMessage = error.message
            }
        }
    }

    public func clearContributionResult() {
        contributionSuccessTitle = nil
        contributionSuccessMessage = nil
    }

    // MARK: - Contribute

    /// Validates the draft, then calls `recall_contribute` for real.
    ///
    /// Returns the corpus's answer on success, including `.duplicate`, which is a
    ///  success state rather than an error.
    @discardableResult
    public func contribute(_ draft: RecallContributionDraft) async -> Result<RecallContributionOutcome, RecallContributionError> {
        await MainActor.run {
            self.isContributing = true
            self.clearContributionResult()
        }

        if let invalid = draft.validate() {
            await MainActor.run { self.isContributing = false }
            return .failure(invalid)
        }

        let result: Result<RecallContributionOutcome, RecallContributionError>
        switch await callTool(name: "recall_contribute", arguments: draft.arguments) {
        case .success(let payload):
            result = Self.outcome(fromToolPayload: payload)
        case .failure(let error):
            result = .failure(error.contributionError)
        }

        await MainActor.run {
            self.isContributing = false
            if case .success(let outcome) = result {
                self.contributionSuccessTitle = outcome.confirmationTitle
                self.contributionSuccessMessage = outcome.confirmationMessage
            }
        }
        return result
    }

    private static func outcome(fromToolPayload payload: String) -> Result<RecallContributionOutcome, RecallContributionError> {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outcome = RecallContributionResponse.outcome(from: object)
        else { return .failure(.unrecognizedResponse) }
        return .success(outcome)
    }

    // MARK: - Transport

    /// One JSON-RPC `tools/call` round trip, in the shape this client has always
    ///  used: a `tools/call` body, a bounded timeout, and a `result` whose first
    ///  content block carries the tool's JSON payload.
    private func callTool(name: String, arguments: [String: Any]) async -> Result<String, RecallTransportError> {
        guard let url = URL(string: endpoint), url.scheme != nil else {
            return .failure(.badEndpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8.0

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.malformedRequest)
        }

        do {
            let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else { return .failure(.statusCode(statusCode)) }

            guard let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return .failure(.unreadablePayload)
            }
            // The server's own error text is never propagated into the UI; only
            // the fact that it refused is reported.
            if root["error"] != nil { return .failure(.serverError) }

            guard let result = root["result"] as? [String: Any],
                  let content = result["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String
            else { return .failure(.unreadablePayload) }

            return .success(text)
        } catch {
            return .failure(.transport)
        }
    }
}

/// Transport-level outcomes, kept separate from a contribution's outcome so a
///  failure reads the same for search and contribute.
enum RecallTransportError: Error, Equatable {
    case badEndpoint
    case malformedRequest
    case transport
    case statusCode(Int)
    case serverError
    case unreadablePayload

    var message: String {
        switch self {
        case .badEndpoint: return "The saved fleet recall endpoint isn't a valid URL."
        case .malformedRequest: return "Clutch couldn't build the request for the fleet recall corpus."
        case .transport:
            return Copy.gap(
                "Couldn't reach the fleet recall corpus.",
                "Check the connection and try again."
            )
        case .statusCode(let code): return "The fleet recall corpus rejected the request (HTTP \(code))."
        case .serverError: return "The fleet recall corpus refused the request."
        case .unreadablePayload: return SearchFailure.unreadable.message
        }
    }

    var contributionError: RecallContributionError {
        switch self {
        case .badEndpoint: return .badEndpoint
        case .malformedRequest: return .malformedRequest
        case .transport: return .unreachable
        case .statusCode(let code): return .rejected(statusCode: code)
        case .serverError: return .serverRejected
        case .unreadablePayload: return .unrecognizedResponse
        }
    }
}

/// Search-only failure copy.  Search has no client-side validation to report, so
///  it needs its own short vocabulary.
enum SearchFailure {
    /// The call completed but the payload wasn't a result set — typically a sign-in
    ///  page or an HTML error body arriving where JSON was expected.
    static let unreadable = RecallContributionError.unrecognizedResponse
}