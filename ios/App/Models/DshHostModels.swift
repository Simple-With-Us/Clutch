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
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
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
    public let details: [String: DshJSONValue]?

    public init(code: String, message: String, details: [String: DshJSONValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
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
