import Foundation
import Observation

/// An engine's native session ID is not unique across tools or paired hosts.
struct ProjectThreadID: Codable, Hashable, Sendable {
    let hostID: UUID
    let engineID: String
    let sessionID: String
}

/// Organizer metadata only. The host's credentials remain in HostStore.
struct ProjectThread: Codable, Hashable, Identifiable, Sendable {
    let id: ProjectThreadID
    let hostName: String
    let title: String
    let cwd: String?

    init(hostID: UUID, hostName: String, engineID: String, session: AcpSessionInfo) {
        id = ProjectThreadID(hostID: hostID, engineID: engineID, sessionID: session.sessionId)
        self.hostName = hostName
        title = session.displayTitle
        cwd = session.cwd
    }

    var session: AcpSessionInfo { session(usingPreviewCwd: nil) }

    func session(usingPreviewCwd previewCwd: String?) -> AcpSessionInfo {
        let confirmedCwd = previewCwd.flatMap { $0.isEmpty ? nil : $0 }
        return AcpSessionInfo(sessionId: id.sessionID, cwd: confirmedCwd ?? cwd, title: title)
    }

    /// A missing pairing never falls through to the current host.
    func pairedHost(in hosts: [ClutchHost]) -> ClutchHost? {
        hosts.first { $0.id == id.hostID }
    }
}

struct ThreadProject: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var threads: [ProjectThread] = []
}

/// The local device can organize references from several hosts without
/// choosing a host to own the project or changing any host-side project.
@MainActor
@Observable
final class ThreadProjectStore {
    static let shared = ThreadProjectStore(defaults: HostStore.resolveDefaults())
    static let storageKey = "codes.clutch.thread-projects.v1"

    private let defaults: UserDefaults
    private let encode: ([ThreadProject]) throws -> Data
    private(set) var projects: [ThreadProject] = []
    private(set) var storageError = false

    init(
        defaults: UserDefaults = .standard,
        encode: @escaping ([ThreadProject]) throws -> Data = { try JSONEncoder().encode($0) }
    ) {
        self.defaults = defaults
        self.encode = encode
        guard let stored = defaults.object(forKey: Self.storageKey) else { return }
        guard let data = stored as? Data,
              let decoded = try? JSONDecoder().decode([ThreadProject].self, from: data) else {
            storageError = true
            return
        }
        projects = decoded
    }

    @discardableResult
    func create(name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !storageError else { return nil }
        let project = ThreadProject(id: UUID(), name: name)
        return save(projects + [project]) ? project.id : nil
    }

    @discardableResult
    func add(_ thread: ProjectThread, to projectID: UUID) -> Bool {
        guard let i = projects.firstIndex(where: { $0.id == projectID }),
              !thread.id.engineID.isEmpty, !thread.id.sessionID.isEmpty else { return false }
        guard !projects[i].threads.contains(where: { $0.id == thread.id }) else { return true }
        var next = projects
        next[i].threads.append(thread)
        return save(next)
    }

    @discardableResult
    func remove(_ threadID: ProjectThreadID, from projectID: UUID) -> Bool {
        guard let i = projects.firstIndex(where: { $0.id == projectID }) else { return false }
        var next = projects
        next[i].threads.removeAll { $0.id == threadID }
        return save(next)
    }

    @discardableResult
    private func save(_ next: [ThreadProject]) -> Bool {
        guard !storageError else { return false }
        guard let data = try? encode(next) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        projects = next
        return true
    }
}
