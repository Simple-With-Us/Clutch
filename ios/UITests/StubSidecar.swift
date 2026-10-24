import Foundation
import Network

/// A tiny HTTP server that answers the chat sidecar's routes, so a UI test
/// can drive the app's real thread surfaces without a Clutch installation.
///
/// It answers only what the native thread views ask for:
///
///   GET  /clutch/v1/health       → ok
///   GET  /clutch/v1/engines      → one engine with one model
///   GET  /clutch/v1/sessions     → one thread
///   POST /clutch/v1/sessions/load → that thread's history
///
/// The token is fixed and public: the stub is a test fixture on loopback,
/// and the app sends it as a Bearer credential.
final class StubSidecar {
    static let chatToken = "ui-test-token"

    private(set) var port: Int = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "clutch.stub.sidecar")
    private var keepAlive: [Any] = []

    enum StubError: Error {
        case couldNotStart
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let port = self?.listener?.port?.rawValue {
                    self?.port = Int(port)
                }
                ready.signal()
            }
            if case .failed = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut || port == 0 {
            throw StubError.couldNotStart
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Requests

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection) { [weak self] request in
            guard let self, let request else { return }
            // The stub answers on the test runner's stderr, so a CI log shows
            // whether the app ever reached it.
            FileHandle.standardError.write(Data("stub-sidecar: \(request.split(separator: "\n").first ?? "")\n".utf8))
            let body = self.body(for: request)
            self.respond(on: connection, status: body.status, json: body.json)
        }
    }

    /// Read until the request headers end, so a request split across TCP
    /// segments is still understood.
    private func receive(on connection: NWConnection, then handler: @escaping (String?) -> Void) {
        var buffer = ""
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data {
                    buffer += String(decoding: data, as: UTF8.self)
                    if buffer.contains("\r\n\r\n") {
                        handler(buffer)
                        return
                    }
                }
                if error != nil || isComplete {
                    handler(buffer.isEmpty ? nil : buffer)
                    return
                }
                readMore()
            }
        }
        readMore()
    }

    private struct StubBody {
        var status: Int
        var json: String
    }

    private func body(for request: String) -> StubBody {
        let firstLine = request.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"

        if path.hasPrefix("/clutch/v1/health") {
            return StubBody(status: 200, json: #"{"ok":true,"engines":["mcode"]}"#)
        }
        if path.hasPrefix("/clutch/v1/engines") {
            let engines = """
            {"engines":[{"id":"mcode","label":"MiniMax Code","available":true,
            "models":[{"id":"M3.1-Flash","label":"M3.1-Flash","value":"m:minimax:MiniMax-M3.1-Flash:v:"}],
            "effortLevels":["default","high"],"effortConfigId":"thinkingEffort","modelConfigId":"model"}]}
            """
            return StubBody(status: 200, json: engines)
        }
        if path.hasPrefix("/clutch/v1/sessions/load") {
            let history = """
            {"sessionId":"stub-chat","remoteSessionId":"stub-session","cwd":"/tmp",
            "history":[
            {"sessionId":"stub-session","kind":"user_message_chunk","text":"Fix the login redirect"},
            {"sessionId":"stub-session","kind":"agent_message_chunk","text":"The redirect now points at the signed-in home page."}
            ]}
            """
            return StubBody(status: 200, json: history)
        }
        if path.hasPrefix("/clutch/v1/sessions") {
            let sessions = """
            {"sessions":[{"sessionId":"stub-session","cwd":"/tmp","title":"Fix The Login Redirect",
            "updatedAt":"2026-10-24T12:00:00.000Z"}]}
            """
            return StubBody(status: 200, json: sessions)
        }
        if path.hasPrefix("/clutch/v1/chat") && method == "POST" {
            return StubBody(status: 200, json: "")
        }
        return StubBody(status: 404, json: #"{"error":"not found"}"#)
    }

    private func respond(on connection: NWConnection, status: Int, json: String) {
        let payload = Data(json.utf8)
        let header = """
        HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")
        Content-Type: application/json
        Content-Length: \(payload.count)
        Connection: close

        """
        var response = Data(header.utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
