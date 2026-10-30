import Foundation

/// Only login instructions cross this API; Muse retains the account credential.
struct EngineAuthenticationAttempt: Decodable, Equatable {
    var attemptId: String
    var state: String
    var url: String?
    var message: String?
    var error: String?

    var verificationURL: URL? {
        guard let url, let parsed = URL(string: url),
              parsed.scheme?.lowercased() == "https",
              let host = parsed.host, !host.isEmpty,
              parsed.user == nil, parsed.password == nil else { return nil }
        return parsed
    }

    static func isRequired(_ message: String?) -> Bool {
        guard let message else { return false }
        return ["log in to muse", "sign in to muse", "not logged in", "muse login", "credentials"]
            .contains { message.range(of: $0, options: .caseInsensitive) != nil }
    }
}

struct EngineAuthenticationClient {
    let host: ClutchHost

    func start() async throws -> EngineAuthenticationAttempt {
        try await request(path: "/start", method: "POST", body: ["engine": "muse"])
    }

    func status(_ id: String) async throws -> EngineAuthenticationAttempt {
        try await request(path: "/\(id)", method: "GET")
    }

    func answer(_ id: String, action: String) async throws {
        _ = try await data(path: "/\(id)/answer", method: "POST", body: ["action": action])
    }

    func cancel(_ id: String) async {
        _ = try? await data(path: "/\(id)", method: "DELETE")
    }

    private func request(path: String, method: String, body: [String: String]? = nil) async throws -> EngineAuthenticationAttempt {
        let payload = try await data(path: path, method: method, body: body)
        return try JSONDecoder().decode(EngineAuthenticationAttempt.self, from: payload)
    }

    private func data(path: String, method: String, body: [String: String]? = nil) async throws -> Data {
        guard let token = host.chatToken, !token.isEmpty else { throw ChatClientError.missingToken }
        var components = URLComponents()
        components.scheme = host.origin.scheme
        components.host = host.origin.host
        components.port = host.chatPort
        components.path = "/clutch/v1/auth" + path
        guard let url = components.url else { throw ChatClientError.badHost }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if path == "/start", (response as? HTTPURLResponse)?.statusCode == 404 {
            throw EngineAuthenticationError.hostNeedsUpdate
        }
        if (response as? HTTPURLResponse)?.statusCode == 409 {
            throw EngineAuthenticationError.inProgress
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ChatClientError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }
}

private enum EngineAuthenticationError: LocalizedError {
    case inProgress
    case hostNeedsUpdate

    var errorDescription: String? {
        switch self {
        case .inProgress:
            return "Another Muse sign-in is already running.\u{00A0} Finish it in the other window, then try again."
        case .hostNeedsUpdate:
            return "This host needs a Clutch update before browser sign-in is available."
        }
    }
}
