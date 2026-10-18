import Foundation

/// Decoded shapes for the sidecar's Infisical settings API — `GET`/`PUT
/// /clutch/v1/infisical` (see `src/web/infisical-route.ts`).
///
/// Two invariants drive everything in this file:
///
///   1. A secret's VALUE never crosses the wire.  For every `secret` kind the
///      server sends `value: ""` and only `isSet` is meaningful, so no decoded
///      property here may be rendered as a stored secret value.
///   2. A `PUT` answers with the `GET` body plus `identitySaved` and
///      `settingSaved`, so one type covers both.  A save therefore refreshes
///      the panel from the server's own post-save state instead of leaving the
///      UI describing what was true before the write.
///
/// Unknown enum cases decode to a fallback rather than failing the whole
/// payload, so a server that grows a new `kind` or `source` still loads.
public struct InfisicalIdentity: Decodable, Equatable {
    public var projectId: String
    public var clientId: String
    /// Whether a client secret is stored on the Mac.  Never the secret itself.
    public var hasClientSecret: Bool
    /// Trailing characters of the client id, for display when the id itself is
    /// not shown.
    public var clientIdHint: String
    /// True when the identity is coming from the process environment rather
    /// than the identity file, which means an edit here will not win.
    public var fromEnv: Bool
}

/// Whether a managed key holds a secret (never displayed), or a plain value
/// (displayed and editable).
public enum InfisicalSettingKind: String, Decodable, Equatable {
    case secret
    case config
    case knob
    /// A kind this build doesn't know.  Treated like a secret so a value the
    /// server redacted is never shown by accident.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InfisicalSettingKind(rawValue: raw) ?? .unknown
    }

    /// True only for kinds whose stored value the server sends in the clear.
    public var showsStoredValue: Bool {
        self == .config || self == .knob
    }

    public var label: String {
        switch self {
        case .secret: return "Secret"
        case .config: return "Setting"
        case .knob: return "Knob"
        case .unknown: return "Unknown"
        }
    }

    public var symbol: String {
        switch self {
        case .secret: return "lock.fill"
        case .config: return "gearshape"
        case .knob: return "dial.medium"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Where the managed settings themselves are read from.
public enum InfisicalSettingsSource: Decodable, Equatable {
    case infisical
    /// Seeded from the environment, which is what the Clutch install ships.
    case envSeed
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "infisical": self = .infisical
        case "env-seed": self = .envSeed
        default: self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .infisical: return "Infisical"
        case .envSeed: return "Environment Seed"
        case .unknown: return "Unknown"
        }
    }
}

/// One managed key in the inventory.
public struct InfisicalManagedKey: Decodable, Identifiable, Equatable {
    public var key: String
    public var kind: InfisicalSettingKind
    public var description: String
    public var isSet: Bool
    /// The current value — always `""` for `kind == .secret`.
    public var value: String

    public var id: String { key }

    /// The value this build may display: empty for anything not explicitly
    /// cleared by the server to be non-secret.
    public var displayValue: String {
        kind.showsStoredValue ? value : ""
    }
}

/// A `GET` or `PUT` response body.
public struct InfisicalSettingsSnapshot: Decodable, Equatable {
    public var identity: InfisicalIdentity
    public var source: InfisicalSettingsSource
    /// Only sent by `GET`.
    public var identityPath: String?
    /// True after a `PUT` that changed the stored identity: the running
    /// process still holds the previous credentials until Clutch restarts.
    public var restartRequired: Bool
    public var keys: [InfisicalManagedKey]
    /// `PUT` only.
    public var identitySaved: Bool?
    /// `PUT` only: the key that was written, or `""`.
    public var settingSaved: String?

    public var nonSecretKeys: [InfisicalManagedKey] {
        keys.filter { $0.kind.showsStoredValue }
    }
}

/// Failures the panel can report.  The server's own `error` text is carried
/// through verbatim wherever it sent one, so the operator reads the reason the
/// Mac gave rather than a client-side paraphrase.
public enum InfisicalSettingsError: Error, LocalizedError {
    case badHost
    case missingToken
    case unauthorized
    case untrustedHost
    /// 503: Infisical is not configured on the Mac, or the write-through failed.
    case notConfigured(key: String, reason: String)
    /// 400: the Mac refused the request — an unknown key, or an incomplete
    /// machine identity.
    case rejected(reason: String)
    /// 409: the request combined an identity change with a setting write.
    case restartRequired(reason: String)
    case transport(String)
    case unreadablePayload

    public var errorDescription: String? {
        switch self {
        case .badHost:
            return "This host has no usable chat address."
        case .missingToken:
            return "Pair again to manage Infisical settings from this device."
        case .unauthorized:
            return Copy.gap(
                "This Mac rejected the chat token.",
                "Pair again, then come back to Infisical settings."
            )
        case .untrustedHost:
            return "This Mac would not accept the request from a trusted host."
        case .notConfigured(let key, let reason):
            return key.isEmpty
                ? Copy.gap("The setting could not be written to Infisical.", reason)
                : Copy.gap("\(key) could not be written to Infisical.", reason)
        case .rejected(let reason):
            return reason
        case .restartRequired(let reason):
            return Copy.gap(reason, "Restart Clutch on the Mac, then try again.")
        case .transport(let detail):
            return Copy.gap("Couldn't reach the Mac's chat sidecar.", detail)
        case .unreadablePayload:
            return "The Mac's chat sidecar answered with a response the app couldn't read."
        }
    }
}