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
        self.models = models
        self.effortLevels = effortLevels
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
        models = try container.decode([EngineModel].self, forKey: .models)
        effortLevels = try container.decode([String].self, forKey: .effortLevels)
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
        default: return id
        }
    }
}

/// One model an engine offers.
public struct EngineModel: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// The exact wire value the engine wants for this model.
    public var value: String
    public var contextWindow: Int?
    public var images: Bool?

    public init(id: String, label: String, value: String, contextWindow: Int? = nil, images: Bool? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.contextWindow = contextWindow
        self.images = images
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
