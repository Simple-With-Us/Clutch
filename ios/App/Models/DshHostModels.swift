import Foundation

/// A JSON value, for the parts of the dsh host contract that carry arbitrary
/// endpoint arguments and results.
public enum DshJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DshJSONValue])
    case object([String: DshJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Double.self) {
            // The number comes first on purpose: a decoder that bridges
            // `NSNumber` reads the JSON number 1 as the boolean true, so a
            // boolean read first turns every 1 and 0 into a flag.
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DshJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: DshJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrecognized JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The JSON value an encodable value is, or `.null` when it cannot be encoded.
    ///
    /// The typed models of the host contract are ordinary Swift values, and
    /// the wire carries JSON, so this is the one place the two meet.
    public static func encoded<T: Encodable>(_ value: T) -> DshJSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(DshJSONValue.self, from: data) else {
            return .null
        }
        return decoded
    }
}

/// The dsh host wire contract, mirrored from `src/shared/dshHostContract.ts`.
///
/// The values here were read from the upstream source at the tag Clutch pins,
/// `dsh-v0.1.5-rc.3` (MIT), and are identical at upstream HEAD.  The
/// TypeScript module is the source of truth; this file is the Swift mirror,
/// and `tests/dsh-host-contract.test.ts` pins the same values on that side.
public enum DshHostContract {
    /// Route prefix owning every API request.
    public static let apiPath = "/api"

    /// Exact WebSocket route carrying every Remote stream.
    public static let muxPath = "/api/remote.mux"

    /// Gateway-internal logical stream carrying application-selected cordis events.
    public static let eventStreamEndpoint = "$events"

    /// Gateway-internal unary endpoint returning one client Remote Event outcome.
    public static let eventResultEndpoint = "$events/result"

    /// The event the host asks an approval under.
    public static let approvalEvent = "approval/request"

    /// The event the host asks a question under.
    public static let userQuestionsEvent = "user-questions/request"

    /// The endpoint that lists the host's sessions.
    public static let sessionListEndpoint = "session/list"

    /// The endpoint that opens a session.
    public static let sessionCreateEndpoint = "session/create"

    /// The endpoint that chooses a session's model.
    public static let sessionSelectModelEndpoint = "session/selectModel"

    /// The endpoint that sends a prompt to a session.
    public static let sessionPromptEndpoint = "session/prompt"

    /// The endpoint that carries a session's history and its live events.
    public static let sessionFollowEndpoint = "session/follow"

    /// The endpoint that pages a session's history.
    public static let sessionPageEndpoint = "session/page"

    /// The characters one segment of an endpoint name may contain.
    ///
    /// The host validates a call target before it dispatches: the endpoint is
    /// one or more segments, each matching this pattern, with no empty, `.` or
    /// `..` segment.  The TypeScript mirror is
    /// `DSH_HOST_ENDPOINT_SEGMENT_PATTERN` in `src/shared/dshHostContract.ts`,
    /// and the rule lives here so the two cannot drift.
    public static let endpointSegmentCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$.-"
    )

    /// Whether an endpoint name is one the host will accept.
    public static func isValidEndpoint(_ endpoint: String) -> Bool {
        if endpoint.isEmpty { return false }
        for part in endpoint.split(separator: "/", omittingEmptySubsequences: false) {
            let segment = String(part)
            if segment.isEmpty || segment == "." || segment == ".." { return false }
            let allowed = segment.unicodeScalars.allSatisfy({ endpointSegmentCharacters.contains($0) })
            guard allowed else { return false }
        }
        return true
    }

    /// The wire key one endpoint's business object rides under.
    ///
    /// The host's Typert descriptors put each endpoint's business object under
    /// one key, and the gateway refuses an argument set that does not match the
    /// descriptor exactly: a flat argument set is refused before the endpoint
    /// runs at all.  `session/list` is the one endpoint whose own argument is
    /// `_request`; every other session argument rides `request`.
    ///
    /// The keys are read from the installed dsh build's descriptors by
    /// `tests/dsh-host-pinned.test.ts`, so a dsh bump that renames one fails
    /// there rather than on a phone.
    public static func argumentKey(forEndpoint endpoint: String) -> String? {
        switch endpoint {
        case sessionListEndpoint:
            return "_request"
        case sessionCreateEndpoint, sessionSelectModelEndpoint, sessionPromptEndpoint,
             sessionFollowEndpoint, sessionPageEndpoint:
            return "request"
        default:
            return nil
        }
    }

    /// The argument set one endpoint expects.
    ///
    /// The business object goes under the key the endpoint's descriptor
    /// declares, so a caller hands over the arguments themselves and cannot
    /// get the envelope wrong.  An endpoint with no known key takes its
    /// arguments flat, which is what the gateway-internal endpoints take.
    public static func envelope(endpoint: String, args: [String: DshJSONValue]) -> [String: DshJSONValue] {
        guard let key = argumentKey(forEndpoint: endpoint) else { return args }
        return [key: .object(args)]
    }
}

/// The argument object a client request carries.
public struct DshHostPayload: Encodable, Equatable, Sendable {
    public let args: [String: DshJSONValue]

    public init(args: [String: DshJSONValue] = [:]) {
        self.args = args
    }
}

/// Client request envelope; endpoint payload validation belongs to its owner.
public struct DshHostClientRequest: Encodable, Equatable, Sendable {
    public let type: String
    public let rpcId: String
    public let method: String
    public let payload: DshHostPayload

    public init(rpcId: String, method: String, payload: DshHostPayload = DshHostPayload()) {
        self.type = "client-request"
        self.rpcId = rpcId
        self.method = method
        self.payload = payload
    }
}

/// The generic endpoint failure carried in a response envelope.
public struct DshHostRpcError: Decodable, Equatable, Sendable {
    public let code: String
    public let message: String
    /// What the failure says about itself.
    ///
    /// A host that sends no details, or sends `null`, gets an empty object:
    /// the details are not the failure, so a missing one must not fail the
    /// whole call.  The TypeScript side normalises the same way.
    public let details: [String: DshJSONValue]

    public init(code: String, message: String, details: [String: DshJSONValue] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, details
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? "unknown"
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        details = (try? container.decodeIfPresent([String: DshJSONValue].self, forKey: .details)) ?? [:]
    }
}

/// A response envelope's result: a value, or a typed failure.
public enum DshHostRpcResult: Decodable, Equatable, Sendable {
    case value(DshJSONValue)
    case failure(DshHostRpcError)

    private enum CodingKeys: String, CodingKey {
        case ok, value, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decode(Bool.self, forKey: .ok)
        if ok {
            let value = try container.decodeIfPresent(DshJSONValue.self, forKey: .value) ?? .null
            self = .value(value)
        } else {
            let error = try container.decode(DshHostRpcError.self, forKey: .error)
            self = .failure(error)
        }
    }
}

/// Server response envelope.
public struct DshHostServerResponse: Decodable, Equatable, Sendable {
    public let type: String
    public let rpcId: String
    public let result: DshHostRpcResult

    private enum CodingKeys: String, CodingKey {
        case type, rpcId, result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "server-response" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unexpected envelope type \(type)"
            )
        }
        let rpcId = try container.decode(String.self, forKey: .rpcId)
        let result = try container.decode(DshHostRpcResult.self, forKey: .result)
        self.type = type
        self.rpcId = rpcId
        self.result = result
    }
}

// MARK: - The mux

/// One frame on the host's mux.
///
/// The mux carries every logical stream over one socket, and every frame
/// names the stream it belongs to, so the client routes a frame to the inbox
/// of the stream that asked for it.
public struct DshHostMuxFrame: Decodable, Equatable, Sendable {
    /// The frame's kind: `item`, `error` or `end`.
    public let type: String
    /// The stream the frame belongs to.
    public let streamId: String?
    /// The frame's value, on an `item` frame.
    public let value: DshJSONValue?
    /// The failure the host reported, on an `error` frame.
    public let error: DshHostRpcError?

    public init(
        type: String,
        streamId: String? = nil,
        value: DshJSONValue? = nil,
        error: DshHostRpcError? = nil
    ) {
        self.type = type
        self.streamId = streamId
        self.value = value
        self.error = error
    }
}

/// The frame that opens one logical stream on the host's mux.
///
/// The host serves no stream at all until the client asks for one, so the
/// open frame names the endpoint the stream reads.
public struct DshHostMuxOpenFrame: Encodable, Equatable, Sendable {
    /// Always `open`.
    public let type: String
    /// The id the client and the host use for this stream.
    public let streamId: String
    /// The endpoint the stream reads.
    public let endpoint: String
    /// The arguments the endpoint takes.
    public let payload: DshHostPayload

    public init(streamId: String, endpoint: String, payload: DshHostPayload = DshHostPayload()) {
        self.type = "open"
        self.streamId = streamId
        self.endpoint = endpoint
        self.payload = payload
    }
}

/// The frame that tells the host a stream is no longer wanted.
public struct DshHostMuxCancelFrame: Encodable, Equatable, Sendable {
    /// Always `cancel`.
    public let type: String
    /// The id the client and the host use for this stream.
    public let streamId: String

    public init(streamId: String) {
        self.type = "cancel"
        self.streamId = streamId
    }
}

// MARK: - The event stream

/// The frame that opens the host's event stream.
///
/// The host mints one id per event stream and names it in the opening frame;
/// every answer the client sends afterwards carries that id.
public struct DshHostReadyFrame: Decodable, Equatable, Sendable {
    /// Always `ready`.
    public let type: String
    /// The id the host named this client.
    public let clientId: String
    /// What the host says about itself.
    public let host: DshHostReadyHost?

    public init(clientId: String, host: DshHostReadyHost? = nil) {
        self.type = "ready"
        self.clientId = clientId
        self.host = host
    }

    /// The ready frame a value carries, or nil when it carries another frame.
    public init?(value: DshJSONValue) {
        guard let data = try? JSONEncoder().encode(value),
              let frame = try? JSONDecoder().decode(DshHostReadyFrame.self, from: data),
              frame.type == "ready" else {
            return nil
        }
        self = frame
    }
}

/// What the host says about itself in its opening frame.
public struct DshHostReadyHost: Decodable, Equatable, Sendable {
    /// The home directory the host runs in.
    public let home: String?

    public init(home: String? = nil) {
        self.home = home
    }
}

/// A question the host asked through its event stream.
///
/// The host blocks on a waterfall until a client answers it, so the frame
/// carries the id the answer has to name.
public struct DshHostWaterfallFrame: Decodable, Equatable, Sendable {
    /// Always `waterfall`.
    public let type: String
    /// The event the host asked under, for example `approval/request`.
    public let event: String
    /// The id the answer has to carry.
    public let eventId: String
    /// The host's agent id, which is the session id.
    public let agentId: String?
    /// What the host asked.
    public let request: DshJSONValue?

    public init(
        event: String,
        eventId: String,
        agentId: String? = nil,
        request: DshJSONValue? = nil
    ) {
        self.type = "waterfall"
        self.event = event
        self.eventId = eventId
        self.agentId = agentId
        self.request = request
    }

    /// The waterfall frame a value carries, or nil when it carries another one.
    public init?(value: DshJSONValue) {
        guard let data = try? JSONEncoder().encode(value),
              let frame = try? JSONDecoder().decode(DshHostWaterfallFrame.self, from: data),
              frame.type == "waterfall" else {
            return nil
        }
        self = frame
    }
}

/// The answer a waterfall question takes.
///
/// The host waits for one answer, so the answer says what kind of answer it
/// is: `next` for a step of a question, `result` for the answer itself, and
/// `rejected` for a refusal.
public struct DshHostEventOutcome: Encodable, Equatable, Sendable {
    /// The kind of answer.
    public enum Kind: String, Encodable, Equatable, Sendable {
        case next
        case result
        case rejected
    }

    /// The kind of answer.
    public let kind: Kind
    /// The value a `next` or a `result` answer carries.
    public let value: DshJSONValue?
    /// The reason a `rejected` answer carries.
    public let reason: String?

    public init(kind: Kind, value: DshJSONValue? = nil, reason: String? = nil) {
        self.kind = kind
        self.value = value
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value, reason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(reason, forKey: .reason)
    }

    /// The answer as the host's argument object.
    public var json: DshJSONValue { .encoded(self) }
}

// MARK: - Sessions

/// One session as the host lists it.
///
/// The host keeps a session's title in its projections rather than on the
/// session itself, so a session that has never been titled simply has none.
public struct SessionSummary: Decodable, Equatable, Sendable {
    /// The session's id.
    public let sessionId: String
    /// When the session was last touched, in epoch milliseconds.
    public let updatedAt: Double?
    /// Whether a turn is running in the session.
    public let running: Bool?
    /// Whether the session is empty.
    public let blank: Bool?
    /// The session this one was forked from.
    public let parentSessionId: String?
    /// Where the session came from.
    public let origin: String?
    /// The folder the session works in.
    public let cwd: String?
    /// The session's projection hints.
    public let projections: SessionProjectionHints?

    public init(
        sessionId: String,
        updatedAt: Double? = nil,
        running: Bool? = nil,
        blank: Bool? = nil,
        parentSessionId: String? = nil,
        origin: String? = nil,
        cwd: String? = nil,
        projections: SessionProjectionHints? = nil
    ) {
        self.sessionId = sessionId
        self.updatedAt = updatedAt
        self.running = running
        self.blank = blank
        self.parentSessionId = parentSessionId
        self.origin = origin
        self.cwd = cwd
        self.projections = projections
    }

    /// The session's title, when it has one.
    public var title: String? { projections?.values?.title }
}

/// The projection hints a session carries.
public struct SessionProjectionHints: Decodable, Equatable, Sendable {
    /// The sequence the projections were read at.
    public let asOfSeq: Double?
    /// The projected values.
    public let values: SessionProjectionValues?

    public init(asOfSeq: Double? = nil, values: SessionProjectionValues? = nil) {
        self.asOfSeq = asOfSeq
        self.values = values
    }
}

/// The projected values a session carries.
public struct SessionProjectionValues: Decodable, Equatable, Sendable {
    /// The session's title, when it has one.
    public let title: String?
    /// The agent preset the session runs.
    public let agentPreset: String?

    public init(title: String? = nil, agentPreset: String? = nil) {
        self.title = title
        self.agentPreset = agentPreset
    }
}

/// The address one follow stream reads.
public struct SessionAddress: Codable, Equatable, Sendable {
    /// The kind of address, `session` for a plain session.
    public let kind: String
    /// The session the address names.
    public let sessionId: String
    /// The parent session, for a child session.
    public let parentSessionId: String?
    /// The child session, for a parent session.
    public let childSessionId: String?
    /// The mode the address asks for.
    public let mode: String?

    public init(
        kind: String = "session",
        sessionId: String,
        parentSessionId: String? = nil,
        childSessionId: String? = nil,
        mode: String? = nil
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.parentSessionId = parentSessionId
        self.childSessionId = childSessionId
        self.mode = mode
    }
}

/// What one follow stream asks the host for.
///
/// The host refuses a window of zero, so a caller that does not want the
/// thread's history leaves `maxMessages` out.
public struct SessionFollowRequest: Codable, Equatable, Sendable {
    /// The session to read.
    public let address: SessionAddress
    /// How many messages the opening window carries.
    public let maxMessages: Int?
    /// Whether the stream carries the assistant's own frames.
    public let assistantStream: Bool?

    public init(
        address: SessionAddress,
        maxMessages: Int? = nil,
        assistantStream: Bool? = nil
    ) {
        self.address = address
        self.maxMessages = maxMessages
        self.assistantStream = assistantStream
    }

    /// The request's own fields, as the endpoint's argument object.
    ///
    /// The endpoint's argument envelope is the client's business, so the
    /// fields are what goes under the envelope key.
    public var arguments: [String: DshJSONValue] {
        var out: [String: DshJSONValue] = ["address": .encoded(address)]
        if let maxMessages {
            out["maxMessages"] = .number(Double(maxMessages))
        }
        if let assistantStream {
            out["assistantStream"] = .bool(assistantStream)
        }
        return out
    }
}

/// One frame of a follow stream.
///
/// The host opens a follow stream with a snapshot of the thread's history and
/// then keeps the stream open for live events; an assistant stream rides the
/// same frames.
public struct SessionFollowFrame: Decodable, Equatable, Sendable {
    /// The frame's kind: `snapshot`, `event`, or an assistant-stream kind.
    public let type: String
    /// The snapshot's header.
    public let header: DshJSONValue?
    /// The snapshot's cursor.
    public let cursor: DshJSONValue?
    /// The snapshot's records.
    public let records: [SessionHistoryRecord]?
    /// Whether the host has more records behind the snapshot.
    public let hasMore: Bool?
    /// The snapshot's projection hints.
    public let projections: SessionProjectionHints?
    /// The event the frame carries, when the host wrapped one.
    public let event: SessionWireEvent?
    /// The event's sequence, when the host sent the event bare.
    public let seq: Double?
    /// The event's time, when the host sent the event bare.
    public let time: Double?
    /// The event's data, when the host sent the event bare.
    public let data: DshJSONValue?

    public init(
        type: String,
        header: DshJSONValue? = nil,
        cursor: DshJSONValue? = nil,
        records: [SessionHistoryRecord]? = nil,
        hasMore: Bool? = nil,
        projections: SessionProjectionHints? = nil,
        event: SessionWireEvent? = nil,
        seq: Double? = nil,
        time: Double? = nil,
        data: DshJSONValue? = nil
    ) {
        self.type = type
        self.header = header
        self.cursor = cursor
        self.records = records
        self.hasMore = hasMore
        self.projections = projections
        self.event = event
        self.seq = seq
        self.time = time
        self.data = data
    }

    /// Whether the frame is the opening snapshot.
    public var isSnapshot: Bool { type == "snapshot" }

    /// The session event the frame carries, wrapped by the host or bare.
    public var sessionEvent: SessionWireEvent? {
        if let event { return event }
        guard seq != nil || time != nil || data != nil else { return nil }
        return SessionWireEvent(type: type, seq: seq, time: time, data: data)
    }
}

/// One record of a session's committed history.
public struct SessionHistoryRecord: Decodable, Equatable, Sendable {
    /// The record's kind, `event` for a session event.
    public let type: String
    /// The event the record carries.
    public let event: SessionWireEvent?

    public init(type: String, event: SessionWireEvent? = nil) {
        self.type = type
        self.event = event
    }
}

/// One session event.
///
/// The event graph is the host's own record of what happened in a session,
/// and the clients render a few kinds of it out of the whole.
public struct SessionWireEvent: Decodable, Equatable, Sendable {
    /// The event's kind, for example `user/message`.
    public let type: String
    /// The event's sequence number in the session.
    public let seq: Double?
    /// When the event happened, in epoch milliseconds.
    public let time: Double?
    /// What the event carries.
    public let data: DshJSONValue?
    /// Whether a client may skip the event.
    public let ignorable: Bool?
    /// The surface operation the event belongs to.
    public let surfaceOp: DshJSONValue?
    /// The sequences of the events this one came from.
    public let sourceEventSeqs: DshJSONValue?

    public init(
        type: String,
        seq: Double? = nil,
        time: Double? = nil,
        data: DshJSONValue? = nil,
        ignorable: Bool? = nil,
        surfaceOp: DshJSONValue? = nil,
        sourceEventSeqs: DshJSONValue? = nil
    ) {
        self.type = type
        self.seq = seq
        self.time = time
        self.data = data
        self.ignorable = ignorable
        self.surfaceOp = surfaceOp
        self.sourceEventSeqs = sourceEventSeqs
    }
}
