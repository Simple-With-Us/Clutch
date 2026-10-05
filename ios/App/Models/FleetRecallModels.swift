import Foundation

public struct RecallHit: Identifiable, Codable, Hashable {
    public var id: String
    public var score: Double
    public var text: String
    public var source: String
    public var app: String
    public var seat: String
    public var heading: String
    public var title: String
    public var path: String
    public var createdAt: Date?

    public init(
        id: String = UUID().uuidString,
        score: Double = 0.95,
        text: String,
        source: String = "doc",
        app: String = "fleet",
        seat: String = "FLEET",
        heading: String = "",
        title: String = "",
        path: String = "",
        createdAt: Date? = nil
    ) {
        self.id = id
        self.score = score
        self.text = text
        self.source = source
        self.app = app
        self.seat = seat
        self.heading = heading
        self.title = title
        self.path = path
        self.createdAt = createdAt
    }
}

public struct RecallStats: Codable {
    public var collectionsCount: Int
    public var totalChunks: Int
    public var vectorDimensions: Int
    public var endpoint: String
    public var queryCount24h: Int

    public init(
        collectionsCount: Int = 14,
        totalChunks: Int = 28_450,
        vectorDimensions: Int = 1536,
        endpoint: String = "https://agents.jays.services/mcp",
        queryCount24h: Int = 1_240
    ) {
        self.collectionsCount = collectionsCount
        self.totalChunks = totalChunks
        self.vectorDimensions = vectorDimensions
        self.endpoint = endpoint
        self.queryCount24h = queryCount24h
    }
}

public struct LessonContribution: Codable {
    public var title: String
    public var content: String
    public var category: String
    public var appSlug: String
    public var authorSeat: String

    public init(
        title: String,
        content: String,
        category: String = "lesson",
        appSlug: String = "clutch",
        authorSeat: String = "AG"
    ) {
        self.title = title
        self.content = content
        self.category = category
        self.appSlug = appSlug
        self.authorSeat = authorSeat
    }
}
