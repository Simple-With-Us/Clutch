import Foundation

/// Per-host preference for asking Muse to compact a thread before a prompt.
public struct MuseContextPolicy: Codable, Equatable, Sendable {
    public static let defaultPolicy = MuseContextPolicy(autoCompact: false, thresholdPercent: 85)

    public var autoCompact: Bool
    public var thresholdPercent: Int

    public init(autoCompact: Bool = false, thresholdPercent: Int = 85) {
        self.autoCompact = autoCompact
        self.thresholdPercent = Self.clampedThreshold(thresholdPercent)
    }

    public static func clampedThreshold(_ value: Int) -> Int {
        min(95, max(50, value))
    }

    private enum CodingKeys: String, CodingKey {
        case autoCompact
        case thresholdPercent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoCompact = try container.decodeIfPresent(Bool.self, forKey: .autoCompact) ?? Self.defaultPolicy.autoCompact
        thresholdPercent = Self.clampedThreshold(
            try container.decodeIfPresent(Int.self, forKey: .thresholdPercent) ?? Self.defaultPolicy.thresholdPercent
        )
    }
}

/// Context facts advertised by a Muse thread and carried by its stream.
public struct MuseContextControls: Codable, Equatable, Sendable {
    public var supportsCompaction: Bool
    public var contextUsedTokens: Int?
    public var contextWindow: Int?

    public init(supportsCompaction: Bool, contextUsedTokens: Int? = nil, contextWindow: Int? = nil) {
        self.supportsCompaction = supportsCompaction
        self.contextUsedTokens = contextUsedTokens
        self.contextWindow = contextWindow
    }

    public var occupancyPercent: Double? {
        guard let contextUsedTokens, contextUsedTokens >= 0,
              let contextWindow, contextWindow > 0 else { return nil }
        return Double(contextUsedTokens) / Double(contextWindow) * 100
    }
}

/// JSON-backed user preferences, scoped to a connected host.
public enum MuseContextPreferences {
    public static let storageKey = "museContextPreferences"

    private struct Store: Codable {
        var hosts: [String: MuseContextPolicy] = [:]
    }

    public static func policy(hostKey: String, preferencesJSON: String?) -> MuseContextPolicy {
        guard let preferencesJSON,
              let data = preferencesJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Store.self, from: data) else {
            return .defaultPolicy
        }
        return decoded.hosts[hostKey] ?? .defaultPolicy
    }

    public static func policy(for host: ClutchHost, defaults: UserDefaults = .standard) -> MuseContextPolicy {
        policy(
            hostKey: host.id.uuidString,
            preferencesJSON: defaults.string(forKey: storageKey)
        )
    }

    public static func setting(
        _ policy: MuseContextPolicy,
        hostKey: String,
        preferencesJSON: String?
    ) -> String {
        var store = decode(preferencesJSON)
        store.hosts[hostKey] = MuseContextPolicy(
            autoCompact: policy.autoCompact,
            thresholdPercent: policy.thresholdPercent
        )
        guard let data = try? JSONEncoder().encode(store),
              let encoded = String(data: data, encoding: .utf8) else { return preferencesJSON ?? "" }
        return encoded
    }

    private static func decode(_ json: String?) -> Store {
        guard let json, let data = json.data(using: .utf8),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return Store() }
        return store
    }
}
