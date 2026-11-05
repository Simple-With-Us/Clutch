import Foundation
import Observation

/// One logical stream the client opened on the host's mux.
///
/// The host tags every frame with the stream it belongs to, so the client
/// keeps one inbox per stream: a reader finds only the frames of its own
/// stream, and one stream ending never disturbs another.
@Observable
public final class DshHostStream {
    /// The id the client and the host use for this stream.
    public let id: String
    /// The endpoint the stream reads.
    public let endpoint: String
    /// The frames the host has sent and the reader has not taken yet.
    public private(set) var items: [DshJSONValue] = []
    /// Whether the host has ended the stream.
    public private(set) var isEnded = false
    /// The failure the host reported on the stream, if any.
    public private(set) var failure: DshHostRpcError?

    public init(id: String, endpoint: String) {
        self.id = id
        self.endpoint = endpoint
    }

    /// The frames the host has sent and the reader has not taken yet.
    ///
    /// The inbox is emptied, so a reader that takes its frames sees each of
    /// them once.
    public func take() -> [DshJSONValue] {
        let out = items
        items.removeAll()
        return out
    }

    /// The session frames the host has sent and the reader has not taken yet.
    ///
    /// A follow stream opens with a snapshot of the thread's history and then
    /// carries the thread's live events, so the frames are decoded as the
    /// host's own frame model.
    public func takeFollowFrames() -> [SessionFollowFrame] {
        take().compactMap { value in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode(SessionFollowFrame.self, from: data)
        }
    }

    func append(_ value: DshJSONValue) {
        items.append(value)
    }

    func finish() {
        isEnded = true
    }

    func fail(_ error: DshHostRpcError) {
        failure = error
        isEnded = true
    }
}

/// A native client of the dsh host that Clutch already runs.
///
/// `scripts/start-web.sh` execs `clutch.sh web`, so a dsh host — a cordis
/// application — is already listening on the web port.  This client is a
/// second client of that host, not a new process and not a WebView.
///
/// Two transports, and the difference matters:
///
///   * A unary call is a `POST` to `/api/<endpoint>`.  The body is the
///     client-request envelope, and the answer is the server-response
///     envelope.
///   * The WebSocket mux at `/api/remote.mux` carries streams.  In practice
///     that is the cordis event stream: the host pushes frames the client
///     reads as they arrive.
///
/// The contract is mirrored from `src/shared/dshHostContract.ts`, which is
/// the source of truth and is pinned against the installed dsh build by
/// `tests/dsh-host-pinned.test.ts`.
///
/// This client is shared by the iOS and macOS targets, so a native app on
/// either platform reaches the host the same way.
@Observable
public final class DshHostClient {
    /// Where the client is in its connect lifecycle.
    public enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public static let shared = DshHostClient()

    public private(set) var state: State = .disconnected
    /// The host this client is pointed at, once one is set.
    public private(set) var host: ClutchHost?
    /// Server pushes read off the mux, newest last.
    public private(set) var events: [DshJSONValue] = []
    /// The streams this client opened on the mux, by stream id.
    public private(set) var streams: [String: DshHostStream] = [:]
    /// The id the host named this client, once the event stream is ready.
    public private(set) var clientId: String?
    /// Something the owner should know, such as a host that answers slowly.
    public private(set) var warning: String?
    /// The last thing that went wrong.
    public private(set) var lastError: String?

    private var session: URLSession?
    private var cookieStorage: HTTPCookieStorage?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var rpcCounter: Int = 0
    private var streamCounter: Int = 0
    private var socketFailure: Error?

    /// How long the client waits for the host to name it.
    private static let readinessTimeout: TimeInterval = 15

    /// How long the client waits before it says the host is slow.
    private static let slowWarningAfter: TimeInterval = 3

    /// The delay before the first retry; it doubles up to the ceiling.
    private static let retryBase: TimeInterval = 0.5
    private static let retryCeiling: TimeInterval = 10

    public init() {}

    // MARK: - Addresses

    /// The WebSocket URL of the host's mux.
    ///
    /// `http` becomes `ws` and `https` becomes `wss`.  The `Host` header is
    /// left to URLSession, which sets it from the URL: the host's trust fence
    /// binds every request to a trusted authority — loopback, the listener's
    /// bind IP literal, or an operator-declared host — and
    /// `scripts/start-web.sh` already declares the addresses this app
    /// connects over.
    public static func muxURL(for origin: URL) -> URL? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        components.path = DshHostContract.muxPath
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The URL a unary call posts to: `/api/<endpoint>`.
    public static func endpointURL(for origin: URL, endpoint: String) -> URL? {
        guard DshHostContract.isValidEndpoint(endpoint) else { return nil }
        var text = origin.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + DshHostContract.apiPath + "/" + endpoint)
    }

    // MARK: - Connection

    /// Connect to a host and open the mux.
    ///
    /// When the host still has a pending launch token, it is exchanged first:
    /// the host answers that one request with the signed cookie every later
    /// call carries.  Without it the host answers 401.
    ///
    /// The client is connected only once the host has named it.  The host
    /// opens the event stream with a frame that carries the id every answer
    /// has to carry, and a socket that has merely resumed is not a host that
    /// is serving this client.
    ///
    /// A socket that fails is not the end of the attempt: the client waits a
    /// little longer and tries again, up to the point where the host has had
    /// its chance to become ready.
    public func connect(to host: ClutchHost) async {
        await disconnect()

        state = .connecting
        self.host = host
        clientId = nil
        warning = nil
        lastError = nil

        let made = Self.makeSession()
        let session = made.session
        self.session = session
        self.cookieStorage = made.cookies

        do {
            try await exchangeLaunchToken(host, session: session)
        } catch {
            state = .failed(Self.describe(error))
            return
        }

        guard let url = Self.muxURL(for: host.origin) else {
            state = .failed(Self.describe(DshHostClientError.badOrigin))
            return
        }

        let started = Date()
        let deadline = started.addingTimeInterval(Self.readinessTimeout)
        var attempt = 0
        var failure: Error = DshHostClientError.notReady
        while Date() < deadline {
            do {
                try await openMux(url: url)
                try await waitForReady(until: deadline, since: started)
                state = .connected
                return
            } catch {
                failure = error
                closeMux()
                if Task.isCancelled { break }
                state = .connecting
                let delay = Self.retryDelay(attempt: attempt)
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        let reason = Self.describe(failure)
        lastError = reason
        state = .failed(reason)
    }

    /// Close the mux and drop the host.
    public func disconnect() async {
        closeMux()
        session?.invalidateAndCancel()
        session = nil
        cookieStorage = nil
        host = nil
        events = []
        clientId = nil
        warning = nil
        lastError = nil
        if case .failed = state {} else {
            state = .disconnected
        }
    }

    // MARK: - Requests

    /// Call one endpoint on the host and return its value.
    ///
    /// `method` is the endpoint name — upstream joins a namespace to its
    /// method with a slash, for example `session/list`, `commands/list` or
    /// `workspaceFiles/list`.
    /// A typed failure comes back as `DshHostClientError.remote`, so the
    /// caller can tell "the host refused" from "the host could not be reached".
    ///
    /// The arguments are the endpoint's own arguments.  The host's descriptors
    /// put an endpoint's business object under one wire key and the gateway
    /// refuses an argument set that does not match, so the client puts them
    /// under that key itself and a caller cannot get the envelope wrong.
    @discardableResult
    public func call(
        method: String,
        args: [String: DshJSONValue] = [:]
    ) async throws -> DshJSONValue {
        guard let host, let session else { throw DshHostClientError.notConnected }
        guard let url = Self.endpointURL(for: host.origin, endpoint: method) else {
            throw DshHostClientError.invalidEndpoint(method)
        }

        rpcCounter += 1
        let request = DshHostClientRequest(
            rpcId: "clutch-\(rpcCounter)",
            method: method,
            payload: DshHostPayload(args: DshHostContract.envelope(endpoint: method, args: args))
        )

        let encoder = JSONEncoder()
        let body: Data
        do {
            body = try encoder.encode(request)
        } catch {
            throw DshHostClientError.encodingFailed(String(describing: error))
        }

        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = body
        http.timeoutInterval = 30

        let (data, response) = try await session.data(for: http)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DshHostClientError.http(status)
        }
        guard let envelope = try? JSONDecoder().decode(DshHostServerResponse.self, from: data) else {
            throw DshHostClientError.malformedResponse
        }
        switch envelope.result {
        case .value(let value):
            return value
        case .failure(let error):
            throw DshHostClientError.remote(code: error.code, message: error.message)
        }
    }

    // MARK: - Streams

    /// Open one stream on the host and return it.
    ///
    /// The host serves no stream at all until the client sends the open
    /// frame, so a stream has to be opened before any frame of it arrives.
    /// Every open frame carries a fresh stream id, and the host tags each
    /// frame it sends with the id of the stream it belongs to.
    ///
    /// The arguments are the endpoint's own arguments: the client puts them
    /// under the key the endpoint's descriptor declares.
    @discardableResult
    public func openStream(
        endpoint: String,
        args: [String: DshJSONValue] = [:]
    ) throws -> DshHostStream {
        guard socket != nil else { throw DshHostClientError.notConnected }
        streamCounter += 1
        let id = "clutch-stream-\(streamCounter)"
        let stream = DshHostStream(id: id, endpoint: endpoint)
        streams[id] = stream
        send(DshHostMuxOpenFrame(
            streamId: id,
            endpoint: endpoint,
            payload: DshHostPayload(args: DshHostContract.envelope(endpoint: endpoint, args: args))
        ))
        return stream
    }

    /// Open the stream that follows one session.
    ///
    /// The host opens the stream with a snapshot of the thread's history and
    /// then keeps it open for live events.  The host refuses a window of
    /// zero, so a caller that does not want the history leaves
    /// `maxMessages` out.
    @discardableResult
    public func follow(
        sessionId: String,
        maxMessages: Int? = nil,
        assistantStream: Bool? = nil
    ) throws -> DshHostStream {
        let request = SessionFollowRequest(
            address: SessionAddress(sessionId: sessionId),
            maxMessages: maxMessages,
            assistantStream: assistantStream
        )
        return try openStream(
            endpoint: DshHostContract.sessionFollowEndpoint,
            args: request.arguments
        )
    }

    /// Tell the host one stream is no longer wanted.
    ///
    /// The cancel frame is what tells the host the stream is no longer read,
    /// so a finished turn does not keep the host holding the session open.
    public func closeStream(_ stream: DshHostStream) {
        send(DshHostMuxCancelFrame(streamId: stream.id))
        streams[stream.id]?.finish()
    }

    // MARK: - The mux

    /// Open the socket and ask the host for its event stream.
    private func openMux(url: URL) async throws {
        guard let session else { throw DshHostClientError.notConnected }
        socketFailure = nil
        let socket = session.webSocketTask(with: url)
        socket.resume()
        self.socket = socket
        startReceiveLoop()
        // The event stream is the one that says the client is ready, and the
        // host serves no stream until the client asks for one.
        _ = try openStream(endpoint: DshHostContract.eventStreamEndpoint)
    }

    /// Wait for the host to name this client.
    private func waitForReady(until deadline: Date, since started: Date) async throws {
        while true {
            // The frame that names the client wins over the deadline: a host
            // that answered a moment late is a host that answered.
            if clientId != nil { return }
            if Date() >= deadline { throw DshHostClientError.notReady }
            if let failure = socketFailure { throw failure }
            if warning == nil, Date().timeIntervalSince(started) > Self.slowWarningAfter {
                warning = "The host is slow to answer."
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Close the mux and drop the streams it carried.
    private func closeMux() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        socketFailure = nil
        streams = [:]
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let socket = self.socket else { return }
                do {
                    let message = try await socket.receive()
                    await self.handle(message)
                } catch {
                    // A socket the client closed on purpose is not a failure.
                    guard self.socket === socket else { return }
                    self.socketFailure = error
                    self.state = .failed(Self.describe(error))
                    return
                }
            }
        }
    }

    /// Read one frame off the socket.
    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            guard let value = String(data: data, encoding: .utf8) else { return }
            text = value
        @unknown default:
            return
        }

        guard let frame = try? JSONDecoder().decode(DshHostMuxFrame.self, from: Data(text.utf8)) else {
            return
        }
        await route(frame)
    }

    /// Route one frame to the stream it belongs to.
    private func route(_ frame: DshHostMuxFrame) async {
        switch frame.type {
        case "item":
            guard let streamId = frame.streamId, let value = frame.value else { return }
            await deliver(value, to: streamId)
        case "error":
            guard let streamId = frame.streamId else { return }
            let error = frame.error ?? DshHostRpcError(code: "unknown", message: "The host reported a failure.")
            streams[streamId]?.fail(error)
        case "end":
            guard let streamId = frame.streamId else { return }
            streams[streamId]?.finish()
        default:
            break
        }
    }

    /// Hand one value to the stream that asked for it.
    private func deliver(_ value: DshJSONValue, to streamId: String) async {
        record(value)

        // The event stream opens with the frame that names this client, and
        // the client is not connected until the host has said so.
        if let ready = DshHostReadyFrame(value: value) {
            clientId = ready.clientId
            state = .connected
            return
        }

        // A waterfall blocks the host until a client answers it.
        if let waterfall = DshHostWaterfallFrame(value: value) {
            await answer(waterfall)
            return
        }

        streams[streamId]?.append(value)
    }

    /// Answer one question the host asked.
    ///
    /// The host waits for an answer, so a client that cannot answer one has
    /// to say so: the answer is a refusal, which ends the host's waiting
    /// instead of leaving it blocked on a question nobody will answer.
    private func answer(_ waterfall: DshHostWaterfallFrame) async {
        let asked = waterfall.event == DshHostContract.approvalEvent
            || waterfall.event == DshHostContract.userQuestionsEvent
        guard asked else { return }
        // A waterfall before the ready frame has no id to answer with.
        guard let generation = clientId else { return }
        let outcome = DshHostEventOutcome(
            kind: .rejected,
            reason: "This app cannot answer a host question yet."
        )
        do {
            _ = try await call(method: DshHostContract.eventResultEndpoint, args: [
                "clientId": .string(generation),
                "eventId": .string(waterfall.eventId),
                "outcome": outcome.json,
            ])
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Record one value the host pushed.
    private func record(_ value: DshJSONValue) {
        events.append(value)
        if events.count > 200 {
            events.removeFirst(events.count - 200)
        }
    }

    /// Write one frame to the mux.
    private func send(_ frame: DshHostMuxOpenFrame) {
        send(json: frame)
    }

    /// Write one frame to the mux.
    private func send(_ frame: DshHostMuxCancelFrame) {
        send(json: frame)
    }

    /// Write one frame to the mux.
    private func send<T: Encodable>(json frame: T) {
        guard let data = try? JSONEncoder().encode(frame),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        guard let socket else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            self?.lastError = Self.describe(error)
        }
    }

    // MARK: - The launch exchange

    /// A session with a cookie storage of its own.
    ///
    /// The process-wide cookie storage would let a second host, or a test,
    /// hand this client a cookie it never asked for, so the client keeps its
    /// own jar and throws it away with the session.
    private static func makeSession() -> (session: URLSession, cookies: HTTPCookieStorage) {
        let cookies = HTTPCookieStorage()
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = cookies
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        return (URLSession(configuration: configuration), cookies)
    }

    /// Exchange the launch token for the host's signed cookie.
    ///
    /// The host mints its cookie on the exchange and every later call
    /// carries it, so a host that minted none is a host this client cannot
    /// talk to.
    private func exchangeLaunchToken(_ host: ClutchHost, session: URLSession) async throws {
        guard let token = host.pendingLaunchToken, !token.isEmpty else { return }
        var request = URLRequest(url: host.launchURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<400).contains(status) else {
            throw DshHostClientError.launchExchangeFailed(status)
        }
        guard hasCookie(for: host) else {
            throw DshHostClientError.noLaunchCookie
        }
    }

    /// Whether the host minted a cookie this client would send.
    private func hasCookie(for host: ClutchHost) -> Bool {
        guard let cookies = cookieStorage else { return false }
        return !cookies.cookies(for: host.rootURL).isEmpty
    }

    // MARK: - Recovery

    /// The delay before the next try, with the jitter the host's own client uses.
    ///
    /// The delay is half the ceiling plus a random part of the other half, so
    /// two clients that lost the host at the same moment do not come back at
    /// the same moment.
    private static func retryDelay(attempt: Int) -> TimeInterval {
        let cap = min(retryCeiling, retryBase * pow(2, Double(attempt)))
        let half = cap / 2
        return half + Double.random(in: 0...half)
    }

    private static func describe(_ error: Error) -> String {
        if let clientError = error as? DshHostClientError {
            return clientError.errorDescription ?? "The host client failed."
        }
        return error.localizedDescription
    }
}

/// A failure of the native dsh host client.
public enum DshHostClientError: Error, LocalizedError {
    case badOrigin
    case notConnected
    case invalidEndpoint(String)
    case launchExchangeFailed(Int)
    case noLaunchCookie
    case notReady
    case encodingFailed(String)
    case http(Int)
    case malformedResponse
    case remote(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .badOrigin:
            return "This host has no usable address."
        case .notConnected:
            return "Not connected to the host."
        case .invalidEndpoint(let endpoint):
            return "The host would not accept the call \(endpoint)."
        case .launchExchangeFailed(let status):
            return "The host refused the launch token (\(status))."
        case .noLaunchCookie:
            return "The host did not mint a session cookie, so this app cannot talk to it."
        case .notReady:
            return "The host did not say it was ready in time."
        case .encodingFailed(let detail):
            return "The request could not be encoded: \(detail)"
        case .http(let status):
            return "The host answered \(status)."
        case .malformedResponse:
            return "The host sent an answer this app could not read."
        case .remote(let code, let message):
            return message.isEmpty ? "The host refused the call (\(code))." : message
        }
    }
}
