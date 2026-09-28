import Foundation

public enum ModelVendor: String, Codable, CaseIterable, Identifiable {
    case miniMax = "MiniMax"
    case deepSeek = "DeepSeek"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .miniMax: return "sparkles"
        case .deepSeek: return "brain.head.profile"
        }
    }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case off = "Off"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    
    public var id: String { rawValue }
}

public struct ModelItem: Identifiable, Codable, Hashable {
    public var id: String
    public var vendor: ModelVendor
    public var displayName: String
    public var badge: String?
    public var badgeDescription: String?
    public var supportsReasoning: Bool
    public var contextWindow: Int
    public var inputRatePerM: Double
    public var outputRatePerM: Double
    public var summary: String
    
    public init(
        id: String,
        vendor: ModelVendor,
        displayName: String,
        badge: String? = nil,
        badgeDescription: String? = nil,
        supportsReasoning: Bool = false,
        contextWindow: Int = 128_000,
        inputRatePerM: Double = 0.30,
        outputRatePerM: Double = 1.20,
        summary: String = ""
    ) {
        self.id = id
        self.vendor = vendor
        self.displayName = displayName
        self.badge = badge
        self.badgeDescription = badgeDescription
        self.supportsReasoning = supportsReasoning
        self.contextWindow = contextWindow
        self.inputRatePerM = inputRatePerM
        self.outputRatePerM = outputRatePerM
        self.summary = summary
    }
    
    public static let supportedModels: [ModelItem] = [
        ModelItem(
            id: "MiniMax-M3",
            vendor: .miniMax,
            displayName: "MiniMax-M3",
            supportsReasoning: true,
            contextWindow: 204_800,
            inputRatePerM: 0.30,
            outputRatePerM: 1.20,
            summary: "Balanced general-purpose and coding model with deep reasoning support."
        ),
        ModelItem(
            id: "MiniMax-M3.1-Flash-Preview",
            vendor: .miniMax,
            displayName: "MiniMax-M3.1-Flash-Preview",
            badge: "Preview",
            badgeDescription: "Frontier multimodal coding model with a 1M context window. Token Plan / MiniMax Code only.",
            supportsReasoning: false,
            contextWindow: 1_000_000,
            inputRatePerM: 0.20,
            outputRatePerM: 0.80,
            summary: "Frontier multimodal coding model with massive 1M context."
        ),
        ModelItem(
            id: "MiniMax-M2.7-highspeed",
            vendor: .miniMax,
            displayName: "MiniMax-M2.7-highspeed",
            badge: "2x Cost",
            badgeDescription: "Same 204,800 context as M2.7 at $0.60 / M input and $2.40 / M output — exactly twice MiniMax M3.",
            supportsReasoning: false,
            contextWindow: 204_800,
            inputRatePerM: 0.60,
            outputRatePerM: 2.40,
            summary: "Ultra-low latency execution tier for real-time workflows."
        ),
        ModelItem(
            id: "DeepSeek-V4.1-Pro",
            vendor: .deepSeek,
            displayName: "DeepSeek-V4.1-Pro",
            supportsReasoning: true,
            contextWindow: 128_000,
            inputRatePerM: 0.27,
            outputRatePerM: 1.10,
            summary: "Advanced reasoning-capable frontier model with step-by-step verification."
        ),
        ModelItem(
            id: "DeepSeek-V4.1-Flash",
            vendor: .deepSeek,
            displayName: "DeepSeek-V4.1-Flash",
            badge: "Multimodal",
            badgeDescription: "Accepts image and video input at the same token rate as text — each image capped at 1,024 tokens.",
            supportsReasoning: false,
            contextWindow: 128_000,
            inputRatePerM: 0.14,
            outputRatePerM: 0.28,
            summary: "High-throughput multimodal model supporting text, image, and video input."
        )
    ]
    
    public static var defaultModel: ModelItem {
        supportedModels[0]
    }
}
