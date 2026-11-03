import Foundation
import Observation

/// Identifies an independent Mac workspace window and its optional starting thread.
public struct MacThreadWindowRequest: Codable, Hashable, Sendable {
    public var windowID: UUID
    public var hostID: UUID
    public var engineID: String
    public var sessionID: String?
    public var cwd: String?
    public var title: String?

    public init(windowID: UUID = UUID(), hostID: UUID, engineID: String, sessionID: String? = nil, cwd: String? = nil, title: String? = nil) {
        self.windowID = windowID
        self.hostID = hostID
        self.engineID = engineID
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
    }
}

public enum MacThreadFolderScope {
    public static let pageSize = 100
    public static let maximumThreads = 1000

    public static func folderOptions(from folders: Set<String>) -> [String] {
        var options = Set<String>()
        for path in folders {
            var current = URL(fileURLWithPath: path).standardizedFileURL.path
            while !current.isEmpty && current != "/" {
                options.insert(current)
                let parent = (current as NSString).deletingLastPathComponent
                guard parent != current else { break }
                current = parent
            }
        }
        return options.sorted()
    }

    public static func nextLimit(after current: Int) -> Int? {
        guard current < maximumThreads else { return nil }
        return min(maximumThreads, max(pageSize, current) + pageSize)
    }
}

/// Process-local guard against resuming one remote session in two windows.
@MainActor
@Observable
public final class MacRunningSessionRegistry {
    public static let shared = MacRunningSessionRegistry()

    private var ownersBySession: [String: UUID] = [:]

    public init() {}

    public func isRunning(hostID: UUID, engineID: String, sessionID: String) -> Bool {
        ownersBySession[key(hostID: hostID, engineID: engineID, sessionID: sessionID)] != nil
    }

    public func claim(hostID: UUID, engineID: String, sessionID: String, owner: UUID) -> Bool {
        let key = key(hostID: hostID, engineID: engineID, sessionID: sessionID)
        guard ownersBySession[key] == nil || ownersBySession[key] == owner else { return false }
        ownersBySession[key] = owner
        return true
    }

    public func release(owner: UUID) {
        ownersBySession = ownersBySession.filter { $0.value != owner }
    }

    private func key(hostID: UUID, engineID: String, sessionID: String) -> String {
        "\(hostID.uuidString)|\(engineID)|\(sessionID)"
    }
}
