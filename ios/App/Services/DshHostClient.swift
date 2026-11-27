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
    /// How many frames were dropped because no reader took them in time.
    public private(set) var droppedCount = 0

    /// How many unread frames one stream holds before the oldest go.
    ///
    /// A follow stream opens with a burst of history, so the cap is generous;
    /// a reader that has gone away still cannot grow this inbox without bound.
    static let maxInboxItems = 4096

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
        // Eviction drops to half the cap in one shift, not one frame per
        // shift: a stream held over the cap by an absent reader would
        // otherwise pay an O(n) memmove for every frame that arrives.
        if items.count > Self.maxInboxItems {
            let overflow = items.count - Self.maxInboxItems / 2
            items.removeFirst(overflow)
            droppedCount += overflow
        }
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
    /// Whether the owner still wants this connection.  A drop only earns a
    /// reconnect while this holds; `disconnect` clears it.
    private var wantsConnection = false
    /// Whether a connection attempt is running.  A socket that dies inside
    /// an attempt belongs to that attempt's own retry loop, never to the
    /// reconnect supervisor as well.
    private var isEstablishing = false
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// Whether a ping is still waiting for its pong.
    private var pingOutstanding = false

    /// How long the client waits for the host to name it.
    private static let readinessTimeout: TimeInterval = 15

    /// How long the client waits before it says the host is slow.
    private static let slowWarningAfter: TimeInterval = 3

    /// The delay before the first retry; it doubles up to the ceiling.
    private static let retryBase: TimeInterval = 0.5
    private static let retryCeiling: TimeInterval = 10

    /// How often a connected mux proves the socket is still alive.  A ping
    /// with no pong by the next tick is a half-open socket: the path died
    /// without telling either end, and only the ping ever finds out.
    private static let pingInterval: TimeInterval = 20

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
        wantsConnection = true
        await stopReconnect()
        await establish(to: host)
    }

    /// Stop any supervised reconnect and wait for it to actually stop.
    ///
    /// Cancel alone is cooperative: a reconnect already inside establish
    /// keeps mutating the session, socket, and state a new attempt is
    /// about to rebuild, so the old task is joined before anything else
    /// touches the connection.
    private func stopReconnect() async {
        guard let running = reconnectTask else { return }
        reconnectTask = nil
        running.cancel()
        await running.value
    }

    /// One full connection attempt: fresh session, token exchange, mux.
    ///
    /// The first connect and every supervised reconnect run exactly this,
    /// so a host that comes back is met the same way it was met at first.
    private func establish(to host: ClutchHost) async {
        isEstablishing = true
        defer { isEstablishing = false }
        teardown()

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
                // The ready frame wins over the deadline in waitForReady,
                // so a socket that died a moment after naming the client
                // must still count as a failed attempt here.
                if let failure = socketFailure { throw failure }
                state = .connected
                isEstablishing = false
                // A socket that died between the check above and this
                // publish must still count as a failed attempt: without
                // this the client sits connected on a dead socket with
                // no supervisor scheduled, because the death handler ran
                // while the state was still connecting.  Reconnect
                // scheduling is idempotent, so a death that lands after
                // this point is supervised exactly once either way.
                if socketFailure != nil {
                    state = .connecting
                    warning = "The connection dropped. Trying again."
                    scheduleReconnect()
                    return
                }
                ClutchLog.stream.info("mux connected")
                startPing()
                return
            } catch {
                failure = error
                closeMux()
                if Task.isCancelled { break }
                state = .connecting
                let delay = Self.retryDelay(attempt: attempt)
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // The sleep above swallows cancellation, so a stop asked
                // during the backoff would otherwise retry until the
                // deadline instead of letting the joiner go.
                if Task.isCancelled { break }
            }
        }

        let reason = Self.describe(failure)
        lastError = reason
        state = .failed(reason)
        ClutchLog.stream.error("mux connect failed")
    }

    /// Close the mux and drop the host.
    public func disconnect() async {
        wantsConnection = false
        await stopReconnect()
        teardown()
    }

    /// Everything one connection owned, dropped without touching whether
    /// the owner still wants one.
    private func teardown() {
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

    /// Prove the socket is alive on an interval while connected.
    ///
    /// A ping that errors, or whose pong never arrives by the next tick,
    /// cancels the socket: the receive loop then reports the loss through
    /// the one path that already ends streams and schedules reconnects.
    private func startPing() {
        pingTask?.cancel()
        pingOutstanding = false
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
                guard !Task.isCancelled, let self, let socket = self.socket else { return }
                if self.pingOutstanding {
                    socket.cancel(with: .abnormalClosure, reason: nil)
                    return
                }
                self.pingOutstanding = true
                socket.sendPing { [weak self] error in
                    self?.pingOutstanding = false
                    if error != nil {
                        socket.cancel(with: .abnormalClosure, reason: nil)
                    }
                }
            }
        }
    }

    /// Reconnect after a drop, for as long as the owner still wants the
    /// connection.  Each cycle is a full attempt with its own readiness
    /// window, spaced by the same jittered backoff the first connect uses.
    private func scheduleReconnect() {
        guard wantsConnection, reconnectTask == nil, let host else { return }
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = Self.retryDelay(attempt: attempt)
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.wantsConnection else { return }
                await self.establish(to: host)
                if self.state == .connected {
                    self.reconnectTask = nil
                    return
                }
            }
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
        // The reader keeps its own reference and sees the end on it; the
        // client drops its copy, so a closed stream cannot leak for the
        // life of the connection or take late frames nobody reads.
        if let held = streams.removeValue(forKey: stream.id) {
            held.finish()
        } else {
            stream.finish()
        }
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
    ///
    /// Every stream is ended first: a reader holding one must see the end
    /// instead of waiting forever on a stream the client already dropped.
    private func closeMux() {
        pingTask?.cancel()
        pingTask = nil
        pingOutstanding = false
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        socketFailure = nil
        for stream in streams.values { stream.finish() }
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
                    // Nothing more can arrive on this socket, so every open
                    // stream ends with the loss on it instead of hanging.
                    let lost = DshHostRpcError(
                        code: "connection-lost",
                        message: "The connection to the host was lost."
                    )
                    for stream in self.streams.values { stream.fail(lost) }
                    self.streams = [:]
                    self.pingTask?.cancel()
                    self.pingTask = nil
                    self.pingOutstanding = false
                    // A connection that was live and is still wanted earns
                    // a supervised reconnect; the state says connecting
                    // while that runs instead of stranding the surface on
                    // a failure nobody is retrying.  A socket that died
                    // during the first attempt is the attempt loop's own
                    // business, reported through waitForReady.
                    if self.state == .connected, self.wantsConnection, !self.isEstablishing {
                        self.state = .connecting
                        self.warning = "The connection dropped. Trying again."
                        ClutchLog.stream.notice("mux dropped; reconnect scheduled")
                        self.scheduleReconnect()
                    } else if self.state == .connected, !self.isEstablishing {
                        self.state = .failed(Self.describe(error))
                    }
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
            streams.removeValue(forKey: streamId)?.fail(error)
        case "end":
            guard let streamId = frame.streamId else { return }
            streams.removeValue(forKey: streamId)?.finish()
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
    ///
    /// The cookie storage answers with an optional list, because a host that
    /// minted none has no list to answer with at all.
    private func hasCookie(for host: ClutchHost) -> Bool {
        guard let cookies = cookieStorage else { return false }
        return !(cookies.cookies(for: host.rootURL) ?? []).isEmpty
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
