import Foundation
import Observation

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

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var rpcCounter: Int = 0

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
        let segments = endpoint.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return nil }
        for segment in segments {
            if segment.isEmpty || segment == "." || segment == ".." { return nil }
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$.-")
            guard segment.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        }
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
    public func connect(to host: ClutchHost) async {
        await disconnect()

        state = .connecting
        self.host = host

        let session = URLSession(configuration: .default)
        do {
            if let token = host.pendingLaunchToken, !token.isEmpty {
                var request = URLRequest(url: host.launchURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 20
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<400).contains(status) else {
                    throw DshHostClientError.launchExchangeFailed(status)
                }
            }

            guard let url = Self.muxURL(for: host.origin) else {
                throw DshHostClientError.badOrigin
            }
            let socket = session.webSocketTask(with: url)
            socket.resume()

            self.session = session
            self.socket = socket
            startReceiveLoop()
            state = .connected
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// Close the mux and drop the host.
    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        host = nil
        events = []
        if case .failed = state {} else {
            state = .disconnected
        }
    }

    // MARK: - Requests

    /// Call one endpoint on the host and return its value.
    ///
    /// `method` is the endpoint name — upstream namespaces them by domain,
    /// for example `remote.session`, `remote.commands` or `remote.terminal`.
    /// A typed failure comes back as `DshHostClientError.remote`, so the
    /// caller can tell "the host refused" from "the host could not be reached".
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
            payload: DshHostPayload(args: args)
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

    // MARK: - Event stream

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let socket = self.socket else { return }
                do {
                    let message = try await socket.receive()
                    self.handle(message)
                } catch {
                    self.state = .failed(Self.describe(error))
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
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

        // A push frame is not a response envelope.  Keep the raw value: the
        // event stream carries host notifications, and a native client decides
        // for itself what to render.
        guard let value = try? JSONDecoder().decode(DshJSONValue.self, from: Data(text.utf8)) else {
            return
        }
        events.append(value)
        if events.count > 200 {
            events.removeFirst(events.count - 200)
        }
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
