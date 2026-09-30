import Foundation
import Observation
import WebKit

/// The paired harness web hosts and which one is showing.  Persisted in
/// `UserDefaults`; launch tokens are dropped as soon as harness web has
/// exchanged them for its cookie (see `consumeLaunchToken`).
@MainActor
@Observable
public final class HostStore {
    public static let shared = HostStore()

    static let storageKey = "com.simplewithus.harness.hosts.v3"
    static let activeKey = "com.simplewithus.harness.activeHost.v3"

    public private(set) var hosts: [HarnessHost] = []
    public private(set) var activeHostID: UUID?
    /// Bumped whenever the web view must reload (new pairing or Reload).
    public private(set) var loadGeneration = 0

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public var activeHost: HarnessHost? {
        guard let id = activeHostID else { return hosts.first }
        return hosts.first(where: { $0.id == id }) ?? hosts.first
    }

    // MARK: - Mutations

    /// Adds a host from a pairing link, or refreshes the token of an already
    /// paired host on the same origin, and makes it the active host.
    @discardableResult
    public func pair(_ payload: PairingPayload) -> HarnessHost {
        if let index = hosts.firstIndex(where: { $0.isSameOrigin(payload.origin) }) {
            if let token = payload.launchToken { hosts[index].pendingLaunchToken = token }
            activeHostID = hosts[index].id
            loadGeneration += 1
            save()
            return hosts[index]
        }
        let host = HarnessHost(pairing: payload)
        hosts.append(host)
        activeHostID = host.id
        loadGeneration += 1
        save()
        return host
    }

    public func activate(_ host: HarnessHost) {
        guard hosts.contains(where: { $0.id == host.id }) else { return }
        activeHostID = host.id
        save()
    }

    public func requestReload() {
        loadGeneration += 1
    }

    public func rename(_ host: HarnessHost, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index].name = trimmed
        save()
    }

    /// Forgets a host and signs this device out of it (drops its cookies).
    public func remove(_ host: HarnessHost) {
        hosts.removeAll(where: { $0.id == host.id })
        if activeHostID == host.id { activeHostID = hosts.first?.id }
        save()
        Self.clearWebsiteData(for: host)
    }

    /// Called once harness web has served `/` after a token load: the cookie
    /// now authenticates, so the one-time token is no longer stored.
    public func consumeLaunchToken(for hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }),
              hosts[index].pendingLaunchToken != nil else { return }
        hosts[index].pendingLaunchToken = nil
        save()
    }

    public func setStatus(_ status: HostStatus, for hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[index].status = status
        hosts[index].lastChecked = Date()
        save()
    }

    public func refreshStatuses() async {
        for host in hosts {
            let status = await HostProbe.probe(host)
            setStatus(status, for: host.id)
        }
    }

    // MARK: - Persistence

    #if DEBUG
    /// UI tests start from first run.  Must run before `shared` is created.
    static func resetPersistedHosts(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: activeKey)
    }
    #endif

    private func load() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([HarnessHost].self, from: data) {
            hosts = decoded
        }
        if let raw = defaults.string(forKey: Self.activeKey), let id = UUID(uuidString: raw),
           hosts.contains(where: { $0.id == id }) {
            activeHostID = id
        } else {
            activeHostID = hosts.first?.id
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            defaults.set(data, forKey: Self.storageKey)
        }
        defaults.set(activeHostID?.uuidString, forKey: Self.activeKey)
    }

    private static func clearWebsiteData(for host: HarnessHost) {
        guard let hostname = host.origin.host?.lowercased() else { return }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter { $0.displayName.lowercased() == hostname || hostname.hasSuffix(".\($0.displayName.lowercased())") }
            guard !matching.isEmpty else { return }
            store.removeData(ofTypes: types, for: matching) {}
        }
    }
}
