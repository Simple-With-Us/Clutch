import Foundation

/// The engines a Clutch host can run, and what each one offers right now.
///
/// The sidecar publishes this at `GET /clutch/v1/engines` (see
/// `src/web/engine-catalog.ts`).  The apps read it instead of shipping a
/// hardcoded model list, so a new provider model shows up in the picker
/// without an app release — the same trick the web canvas uses.
public struct EngineCatalog: Decodable, Equatable, Sendable {
    public var engines: [EngineDescriptor]

    public init(engines: [EngineDescriptor]) {
        self.engines = engines
    }

    /// The engines this host can actually run.
    public var availableEngines: [EngineDescriptor] {
        engines.filter(\.available)
    }

    public func descriptor(_ id: String) -> EngineDescriptor? {
        engines.first { $0.id == id }
    }

    public func model(engineId: String, modelId: String) -> EngineModel? {
        descriptor(engineId)?.models.first { $0.id == modelId }
    }

    /// The engine to start on: the first available one, in the server's order.
    public var defaultEngineId: String? {
        availableEngines.first?.id
    }
}

/// One engine, with the choices it advertises.
public struct EngineDescriptor: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// False when the engine's launcher or host binary is missing there.
    public var available: Bool
    /// True when this engine's threads can be listed and resumed.
    ///
    /// The sidecar publishes the capability, so the app never hardcodes which
    /// engines those are: the code engines keep their own session log and the
    /// dsh-hosted engines keep theirs in the dsh host, and the sidecar reads
    /// and resumes both through the same endpoint.  A sidecar that does not
    /// say is taken at its word, because every Clutch engine can do this.
    public var supportsThreads: Bool
    public var models: [EngineModel]
    /// Reasoning-effort levels, ascending.
    public var effortLevels: [String]
    /// The ACP config id that carries the effort choice.
    public var effortConfigId: String
    /// The ACP config id that carries the model choice.
    public var modelConfigId: String
    /// A short note for the user (why a catalog is thin, for example).
    public var note: String?

    public init(
        id: String,
        label: String,
        available: Bool,
        supportsThreads: Bool = true,
        models: [EngineModel],
        effortLevels: [String],
        effortConfigId: String,
        modelConfigId: String,
        note: String? = nil
    ) {
        self.id = id
        self.label = label
        self.available = available
        self.supportsThreads = supportsThreads
        self.models = id == "muse" ? MuseModelCatalogPolicy.normalizedModels(models) : models
        self.effortLevels = EngineEffortCatalogPolicy.levels(engineID: id, advertised: effortLevels)
        self.effortConfigId = effortConfigId
        self.modelConfigId = modelConfigId
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case available
        case supportsThreads
        case models
        case effortLevels
        case effortConfigId
        case modelConfigId
        case note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        available = try container.decode(Bool.self, forKey: .available)
        // An older sidecar does not publish the capability.  Every engine
        // Clutch can run lists its threads, so absent means yes.
        supportsThreads = try container.decodeIfPresent(Bool.self, forKey: .supportsThreads) ?? true
        let decodedModels = try container.decode([EngineModel].self, forKey: .models)
        models = id == "muse" ? MuseModelCatalogPolicy.normalizedModels(decodedModels) : decodedModels
        let decodedEffortLevels = try container.decode([String].self, forKey: .effortLevels)
        effortLevels = EngineEffortCatalogPolicy.levels(engineID: id, advertised: decodedEffortLevels)
        effortConfigId = try container.decode(String.self, forKey: .effortConfigId)
        modelConfigId = try container.decode(String.self, forKey: .modelConfigId)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

/// Owner-facing names for the engines.
///
/// The catalog is the source of truth for these names, so this is only the
/// fallback the views show before it lands.  It lives here so no view has to
/// spell out which engine is which.
public enum EngineLabels {
    /// The name for an engine id, or the id itself when it is not one Clutch knows.
    public static func label(for id: String) -> String {
        switch id {
        case "deepseek": return "DeepSeek"
        case "minimax": return "MiniMax"
        case "mcode": return "MiniMax Code"
        case "muse": return "Muse Code"
        case "zcode": return "Z Code"
        default: return id
        }
    }
}

/// The engines Clutch can run, by the id the sidecar knows them by.
///
/// The catalog says which of them a host runs, but the ids themselves are
/// fixed: the sidecar refuses a chat request that names an engine it does
/// not know, so a client only ever sends one of these.
public enum EngineIds {
    /// Every engine id, in the order the picker shows them.
    public static let all = ["deepseek", "minimax", "mcode", "muse", "zcode"]

    /// True when the id names an engine Clutch can run.
    public static func isKnown(_ id: String) -> Bool {
        all.contains(id)
    }
}

/// One model an engine offers.
public struct EngineModel: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// The exact wire value the engine wants for this model.
    public var value: String
    /// A second spelling of the same model the engine may accept.
    ///
    /// Muse Code writes a model two ways: the bare id and a
    /// provider-qualified tuple, and which one the adapter takes depends on
    /// its backend and on the account's catalog.  The sidecar tries this
    /// form when the first one is refused.
    public var altValue: String?
    public var contextWindow: Int?
    public var images: Bool?

    public init(
        id: String,
        label: String,
        value: String,
        altValue: String? = nil,
        contextWindow: Int? = nil,
        images: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.altValue = altValue
        self.contextWindow = contextWindow
        self.images = images
    }

    /// The fields the sidecar publishes, named as it names them.
    ///
    /// Without these the decoder drops every field it does not know by
    /// name, so a field the server adds later never reaches the app.
    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case value
        case altValue
        case contextWindow
        case images
    }

    /// What a picker row shows.
    public var displayLabel: String {
        label.isEmpty ? id : label
    }

    /// The context window in a short human form, when the engine publishes one.
    public var contextSummary: String? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        if contextWindow >= 1_000_000 {
            return String(format: "%.1fM", Double(contextWindow) / 1_000_000)
        }
        if contextWindow >= 1_000 {
            return "\(contextWindow / 1_000)k"
        }
        return "\(contextWindow)"
    }
}

/// Native Muse choices stay aligned with the contributor models published by updated hosts.
private enum MuseModelCatalogPolicy {
    static let effortLevels = ["minimal", "low", "medium", "high", "xhigh"]

    private static let models = [
        EngineModel(id: "muse-spark-1.3-contributor", label: "Muse Spark 1.3 Contributor", value: "muse-spark-1.3-contributor"),
        EngineModel(id: "muse-wonder-1.0-contributor", label: "Muse Wonder 1.0 Contributor", value: "muse-wonder-1.0-contributor"),
        EngineModel(id: "muse-wonder-full-1.0-contributor", label: "Muse Wonder Full 1.0 Contributor", value: "muse-wonder-full-1.0-contributor"),
    ]

    static let modelIDs = Set(models.map(\.id))

    /// Fill missing choices and retain only exact matches' descriptive metadata.
    /// Wire values are always the approved bare model IDs.
    static func normalizedModels(_ advertised: [EngineModel]) -> [EngineModel] {
        models.map { supported in
            let metadata = advertised.first { $0.id == supported.id }
            return EngineModel(
                id: supported.id,
                label: supported.label,
                value: supported.id,
                // The provider-qualified form of the same model is part of
                // what the host published, so it is kept: the sidecar tries
                // it when the bare id is refused.
                altValue: metadata?.altValue,
                contextWindow: metadata?.contextWindow,
                images: metadata?.images
            )
        }
    }
}

/// Native effort menus use one canonical order, ending at `xhigh` for Muse contributors and adding `max` for other models while omitting `none` and `ultra`.
private enum EngineEffortCatalogPolicy {
    private static let contributorLevels = ["minimal", "low", "medium", "high", "xhigh"]
    private static let standardLevels = contributorLevels + ["max"]

    static func levels(engineID: String, advertised: [String]) -> [String] {
        guard !advertised.isEmpty else { return [] }
        return engineID == "muse" ? contributorLevels : standardLevels
    }
}

/// Per-turn Muse behavior selected in the native app.
public struct MuseLaunchOptions: Codable, Equatable, Sendable {
    public var yolo: Bool
    public var contributorMode: Bool

    public static let defaults = MuseLaunchOptions(yolo: true, contributorMode: true)

    public init(yolo: Bool, contributorMode: Bool) {
        self.yolo = yolo
        self.contributorMode = contributorMode
    }
}

/// Per-host Muse defaults stored on this device, separate from host-managed settings.
public enum MuseLaunchPreferences {
    public static let storageKey = "museLaunchPreferences"

    private struct Store: Codable {
        var hosts: [String: MuseLaunchOptions] = [:]
    }

    public static func options(hostKey: String, preferencesJSON: String?) -> MuseLaunchOptions {
        guard let preferencesJSON,
              let data = preferencesJSON.data(using: .utf8),
              let store = try? JSONDecoder().decode(Store.self, from: data) else {
            return .defaults
        }
        return store.hosts[hostKey] ?? .defaults
    }

    public static func options(for host: ClutchHost, defaults: UserDefaults = .standard) -> MuseLaunchOptions {
        options(hostKey: host.id.uuidString, preferencesJSON: defaults.string(forKey: storageKey))
    }

    public static func setting(
        _ options: MuseLaunchOptions,
        hostKey: String,
        preferencesJSON: String?
    ) -> String {
        var store: Store
        if let preferencesJSON,
           let data = preferencesJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            store = decoded
        } else {
            store = Store()
        }
        store.hosts[hostKey] = options
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(store), let json = String(data: data, encoding: .utf8) else {
            return preferencesJSON ?? "{}"
        }
        return json
    }
}

/// Pure visibility policy for model pickers
/// Preferences are JSON for per-host persistence in native settings; filtering never modifies engine availability
public enum ModelVisibilityPreferences {
    public static let storageKey = "modelVisibilityPreferences"

    private struct Store: Codable {
        var hosts: [String: [String: [String]]] = [:]
    }

    /// Stored selection for this host and engine: `nil` means unset; an empty set explicitly shows no models
    public static func selectedModelIDs(
        engineID: String,
        hostKey: String,
        preferencesJSON: String?
    ) -> Set<String>? {
        guard let store = decode(preferencesJSON),
              let ids = store.hosts[hostKey]?[engineID] else { return nil }
        return Set(ids)
    }

    /// Picker choices in catalog order, without changing catalog availability
    public static func visibleModels(
        all: [EngineModel],
        engineID: String,
        hostKey: String,
        preferencesJSON: String?
    ) -> [EngineModel] {
        let candidates = engineID == "muse" ? MuseModelCatalogPolicy.normalizedModels(all) : all
        let stored = selectedModelIDs(engineID: engineID, hostKey: hostKey, preferencesJSON: preferencesJSON)
        let selected: Set<String>
        if engineID == "muse", let stored, !stored.isEmpty {
            let exactSelection = stored.intersection(MuseModelCatalogPolicy.modelIDs)
            // Ignore legacy base/qualified selections so older saved filters
            // do not strand the picker with no supported model choices.
            selected = exactSelection.isEmpty ? defaultModelIDs(all: candidates, engineID: engineID) : exactSelection
        } else {
            selected = stored ?? defaultModelIDs(all: candidates, engineID: engineID)
        }
        return candidates.filter { selected.contains($0.id) }
    }

    /// Change one model's visibility and return JSON while retaining unavailable stored IDs
    public static func settingVisible(
        _ visible: Bool,
        modelID: String,
        all: [EngineModel],
        engineID: String,
        hostKey: String,
        preferencesJSON: String?
    ) -> String {
        var store = decode(preferencesJSON) ?? Store()
        var selected: Set<String>
        if let stored = store.hosts[hostKey]?[engineID] {
            selected = Set(stored)
        } else {
            selected = defaultModelIDs(all: all, engineID: engineID)
        }
        if visible {
            selected.insert(modelID)
        } else {
            selected.remove(modelID)
        }
        store.hosts[hostKey, default: [:]][engineID] = selected.sorted()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(store), let json = String(data: data, encoding: .utf8) else {
            return preferencesJSON ?? "{}"
        }
        return json
    }

    /// Remove only this host and engine's override so future catalog entries follow its default visibility rule
    public static func restoringDefaultsJSON(
        engineID: String,
        hostKey: String,
        preferencesJSON: String?
    ) -> String? {
        guard let preferencesJSON, var store = decode(preferencesJSON) else { return nil }
        guard store.hosts[hostKey]?[engineID] != nil else { return preferencesJSON }
        store.hosts[hostKey]?[engineID] = nil
        if store.hosts[hostKey]?.isEmpty == true {
            store.hosts[hostKey] = nil
        }
        guard !store.hosts.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(store) else { return preferencesJSON }
        return String(data: data, encoding: .utf8)
    }

    private static func defaultModelIDs(all: [EngineModel], engineID: String) -> Set<String> {
        guard engineID == "muse" else { return Set(all.map(\.id)) }
        return MuseModelCatalogPolicy.modelIDs
    }

    private static func decode(_ json: String?) -> Store? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Store.self, from: data)
    }
}
