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

    /// The fixture thread the Mac UI fixture drives.
    ///
    /// It is named rather than generated so the same synthetic sequence can
    /// be replayed on any machine and compared with any other capture:  the
    /// name in the thread list is the identity of the fixture.
    static let fixtureSessionId = "c-137-mac-fixture"
    static let fixtureSessionTitle = "C-137 Mac Fixture Turn"

    /// The text the fixture turn streams while it runs.
    static let fixtureRunningText = "Fixture running. "
    /// The text the fixture turn ends with.
    static let fixtureFinalText = "Fixture finished."

    private(set) var port: Int = 0
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    /// True when the stub serves the synthetic fixture turn.
    private let fixture: Bool
    /// The fixture turn holds its stream open at the permission request
    /// until the test releases it, so the card stays on screen long enough
    /// to be looked at.
    private let turnGate = DispatchSemaphore(value: 0)

    enum StubError: Error {
        case couldNotStart
    }

    init(fixture: Bool = false) {
        self.fixture = fixture
    }

    /// Lets the fixture turn finish.
    ///
    /// The turn holds its stream open at the permission request so the card
    /// is on screen while the test looks at it.  This releases it, and the
    /// turn writes the rest of the transcript and ends.
    func releaseTurn() {
        turnGate.signal()
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
            // Every connection gets a thread of its own.  The fixture turn
            // holds its stream open for as long as the test needs it, and a
            // serial loop would block every other request the app makes
            // while that stream is open.
            let thread = Thread { [weak self] in
                self?.handle(client)
                close(client)
            }
            thread.name = "clutch.stub.sidecar.client"
            thread.start()
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

        let request = String(decoding: buffer, as: UTF8.self)
        switch reply(for: request) {
        case .body(let status, let json):
            respond(on: fd, status: status, json: json)
        case .eventStream:
            streamFixtureTurn(on: fd)
        }
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

    /// What the stub answers a request with.
    private enum StubReply {
        case body(status: Int, json: String)
        /// The synthetic turn, written as a server-sent event stream.
        case eventStream
    }

    private func reply(for request: String) -> StubReply {
        let firstLine = request.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"

        if fixture && method == "POST" && path.hasPrefix("/clutch/v1/chat") {
            return .eventStream
        }
        let answer = body(for: method, path: path)
        return .body(status: answer.status, json: answer.json)
    }

    private func body(for method: String, path: String) -> StubBody {

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
            if fixture { return StubBody(status: 200, json: fixtureHistory) }
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
            if fixture {
                return StubBody(
                    status: 200,
                    json: "{\"remoteSessionId\":\"\(Self.fixtureSessionId)\",\"cwd\":\"/tmp\","
                        + "\"title\":\"\(Self.fixtureSessionTitle)\",\"history\":["
                        + fixtureHistoryEntries + "],\"running\":false,\"truncated\":false}"
                )
            }
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
            if fixture {
                let sessions = "{\"sessions\":[{\"sessionId\":\"\(Self.fixtureSessionId)\",\"cwd\":\"/tmp\","
                    + "\"title\":\"\(Self.fixtureSessionTitle)\",\"updatedAt\":\"2026-11-22T18:00:00.000Z\"}]}"
                return StubBody(status: 200, json: sessions)
            }
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

    // MARK: - The synthetic fixture turn

    /// The history the fixture thread replays when it is resumed.
    ///
    /// It is deliberately different from the text the turn streams, so the
    /// final transcript can only be the transcript of the turn:  a replay
    /// that happened to carry the same words would pass an assertion that
    /// meant nothing.
    private var fixtureHistoryEntries: String {
        "{\"sessionId\":\"\(Self.fixtureSessionId)\",\"kind\":\"user_message_chunk\","
            + "\"text\":\"Fixture: fix the login redirect\"},"
            + "{\"sessionId\":\"\(Self.fixtureSessionId)\",\"kind\":\"agent_message_chunk\","
            + "\"text\":\"Fixture: reading the redirect handler\"}"
    }

    private var fixtureHistory: String {
        "{\"sessionId\":\"stub-chat\",\"remoteSessionId\":\"\(Self.fixtureSessionId)\",\"cwd\":\"/tmp\","
            + "\"history\":[" + fixtureHistoryEntries + "]}"
    }

    /// Writes the synthetic turn as a server-sent event stream.
    ///
    /// The stream is held open at the permission request, because the card
    /// only exists while the turn is waiting for its answer:  a stream that
    /// closed at that point would take the card with it, and the fixture
    /// would have nothing to capture.  The test releases the turn when it
    /// has looked at the card.
    private func streamFixtureTurn(on fd: Int32) {
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        write(header, to: fd)

        write(event: "start", data: #"{"sessionId":"stub-chat","engine":"mcode"}"#, to: fd)
        write(event: "message", data: #"{"text":"Fixture running. "}"#, to: fd)
        write(
            event: "tool",
            data: #"{"id":"fixture-tool-1","name":"read_file","status":"running","input":"src/routes/login.ts"}"#,
            to: fd
        )
        write(
            event: "permission",
            data: #"{"requestId":"fixture-request-1","title":"Run the login test suite","toolName":"shell","options":[{"optionId":"fixture-allow-once","kind":"allow_once","name":"Allow once"},{"optionId":"fixture-reject-once","kind":"reject_once","name":"Reject"}]}"#,
            to: fd
        )

        // The turn waits here for the test to say it has seen the card.
        _ = turnGate.wait(timeout: .now() + 180)

        write(
            event: "tool",
            data: #"{"id":"fixture-tool-1","name":"read_file","status":"completed"}"#,
            to: fd
        )
        write(event: "message", data: #"{"text":"Fixture finished."}"#, to: fd)
        write(
            event: "done",
            data: #"{"stopReason":"endTurn","sessionId":"stub-chat","remoteSessionId":"c-137-mac-fixture"}"#,
            to: fd
        )
    }

    private func write(event: String, data: String, to fd: Int32) {
        write("event: \(event)\ndata: \(data)\n\n", to: fd)
    }

    private func write(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { raw in
            send(fd, raw.baseAddress, bytes.count, 0)
        }
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
