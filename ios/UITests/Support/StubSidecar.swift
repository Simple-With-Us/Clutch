import Darwin
import Foundation

/// A tiny HTTP server that answers the chat sidecar's routes, so a UI test
/// can drive the app's real thread surfaces without a Clutch installation.
///
/// It answers only what the native thread views ask for:
///
///   GET  /clutch/v1/health       → ok
///   GET  /clutch/v1/engines      → one engine with one model
///   GET  /clutch/v1/sessions     → one thread
///   POST /clutch/v1/sessions/load → that thread's history
///   GET  /clutch/v1/sessions/preview → that thread's history, as a preview
///   GET  /clutch/v1/session-meta → no projects, no per-session metadata
///
/// The token is fixed and public: the stub is a test fixture on loopback,
/// and the app sends it as a Bearer credential.
///
/// The server is a POSIX socket rather than a `Network.framework` listener.
/// Network.framework refuses to bind on the macOS host with "Invalid
/// argument", while a plain socket binds fine, and the iOS Simulator
/// accepts both.  One implementation that works on both platforms beats
/// two that do not.
final class StubSidecar {
    static let chatToken = "ui-test-token"

    private(set) var port: Int = 0
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?

    enum StubError: Error {
        case couldNotStart
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StubError.couldNotStart }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        // Port zero asks the kernel for a free port, so a second run never
        // collides with the first.
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                bind(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw StubError.couldNotStart
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                getsockname(fd, sockPointer, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw StubError.couldNotStart
        }

        listenFD = fd
        port = Int(UInt16(bigEndian: assigned.sin_port))

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "clutch.stub.sidecar.accept"
        thread.start()
        acceptThread = thread
    }

    func stop() {
        if listenFD >= 0 {
            // Closing the listening socket breaks the blocking accept, so the
            // thread ends on its own.
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        acceptThread = nil
    }

    // MARK: - Accept loop

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            handle(client)
            close(client)
        }
    }

    // MARK: - Requests

    private func handle(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let headerTerminator = Data("\r\n\r\n".utf8)

        while true {
            let capacity = chunk.count
            let read_ = chunk.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, capacity)
            }
            if read_ <= 0 { break }
            buffer.append(contentsOf: chunk[0..<read_])

            guard let range = buffer.range(of: headerTerminator) else { continue }
            let header = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
            let body = buffer[range.upperBound...]
            if body.count >= contentLength(in: header) { break }
        }

        guard !buffer.isEmpty else { return }

        // The stub answers on the test runner's stderr, so a CI log shows
        // whether the app ever reached it.
        let firstLine = buffer.split(separator: 0x0A).first.map { String(decoding: $0, as: UTF8.self) } ?? ""
        FileHandle.standardError.write(Data("stub-sidecar: \(firstLine)\n".utf8))

        let answer = body(for: String(decoding: buffer, as: UTF8.self))
        respond(on: fd, status: answer.status, json: answer.json)
    }

    /// The body length the request announces, so the whole request is read
    /// before it is answered.
    ///
    /// Answering before the body is drained can make the client reset the
    /// connection instead of reading the response.
    private func contentLength(in header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
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
            {"engines":[{"id":"mcode","label":"Stub Engine","available":true,
            "models":[{"id":"M3.1-Flash","label":"M3.1-Flash","value":"m:minimax:MiniMax-M3.1-Flash:v:"}],
            "effortLevels":["default","high"],"effortConfigId":"thinkingEffort","modelConfigId":"model"}]}
            """
            return StubBody(status: 200, json: engines)
        }
        if path.hasPrefix("/clutch/v1/session-meta") {
            // The sidecar keeps the project's own metadata for a session.
            // An empty one is a valid answer, and answering it keeps the
            // client from showing a metadata error over a working thread.
            return StubBody(status: 200, json: #"{"projects":[],"sessions":{}}"#)
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
        if path.hasPrefix("/clutch/v1/sessions/preview") {
            // The Mac app previews a thread before it resumes it, and the
            // preview is a different route from the full load.
            let preview = """
            {"remoteSessionId":"stub-session","cwd":"/tmp","title":"Fix The Login Redirect",
            "history":[
            {"sessionId":"stub-session","kind":"user_message_chunk","text":"Fix the login redirect"},
            {"sessionId":"stub-session","kind":"agent_message_chunk","text":"The redirect now points at the signed-in home page."}
            ],
            "running":false,"truncated":false}
            """
            return StubBody(status: 200, json: preview)
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

    private func respond(on fd: Int32, status: Int, json: String) {
        let payload = Data(json.utf8)
        // The header block ends with a blank line: CRLF CRLF.  A Swift
        // multi-line string ends with a single newline, which leaves the
        // body glued to the headers and the client reads the whole thing as
        // one malformed header.
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        var response = Data(header.utf8)
        response.append(payload)
        _ = response.withUnsafeBytes { raw in
            send(fd, raw.baseAddress, response.count, 0)
        }
    }
}
