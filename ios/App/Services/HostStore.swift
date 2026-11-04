import Foundation
import Observation
import WebKit

/// The paired clutch web hosts and which one is showing.
///
/// The hosts are persisted in `UserDefaults`; the tokens are not.  A token can
/// drive a coding session, and the preferences file is plain text that rides
/// the device backup, so the tokens live in the keychain (`KeychainStore`)
/// and only the host records sit in the preferences.
///
/// The launch token is kept for the life of the pairing, not dropped: the dsh
/// host client exchanges it for a signed cookie on every connect, and that
/// cookie does not survive an app restart.
@MainActor
@Observable
public final class HostStore {
    public static let shared = HostStore()

    static let storageKey = "codes.clutch.hosts.v3"
    static let activeKey = "codes.clutch.activeHost.v3"

    public private(set) var hosts: [ClutchHost] = []
    public private(set) var activeHostID: UUID?

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public var activeHost: ClutchHost? {
        guard let id = activeHostID else { return hosts.first }
        return hosts.first(where: { $0.id == id }) ?? hosts.first
    }

    // MARK: - Mutations

    /// Adds a host from a pairing link, or refreshes the token of an already
    /// paired host on the same origin, and makes it the active host.
    @discardableResult
    public func pair(_ payload: PairingPayload) -> ClutchHost {
        if let index = hosts.firstIndex(where: { $0.isSameOrigin(payload.origin) }) {
            if let token = payload.launchToken { hosts[index].pendingLaunchToken = token }
            if let chat = payload.chatToken { hosts[index].chatToken = chat }
            if let port = payload.chatPort { hosts[index].chatPort = port }
            if let kind = payload.kind { hosts[index].kind = kind }
            activeHostID = hosts[index].id
            save()
            return hosts[index]
        }
        let host = ClutchHost(pairing: payload)
        hosts.append(host)
        activeHostID = host.id
        save()
        return host
    }

    public func activate(_ host: ClutchHost) {
        guard hosts.contains(where: { $0.id == host.id }) else { return }
        activeHostID = host.id
        save()
    }

    public func rename(_ host: ClutchHost, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index].name = trimmed
        save()
    }

    /// Forgets a host and signs this device out of it (drops its cookies).
    public func remove(_ host: ClutchHost) {
        hosts.removeAll(where: { $0.id == host.id })
        if activeHostID == host.id { activeHostID = hosts.first?.id }
        // The credentials go with the host: a forgotten host must not leave a
        // token behind in the keychain.
        KeychainStore.delete(Self.chatAccount(for: host.id))
        KeychainStore.delete(Self.launchAccount(for: host.id))
        save()
        Self.clearWebsiteData(for: host)
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
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ClutchHost].self, from: data) {
            for host in decoded {
                KeychainStore.delete(chatAccount(for: host.id))
                KeychainStore.delete(launchAccount(for: host.id))
            }
        }
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: activeKey)
    }
    #endif

    private func load() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ClutchHost].self, from: data) {
            hosts = decoded
        }
        if let raw = defaults.string(forKey: Self.activeKey), let id = UUID(uuidString: raw),
           hosts.contains(where: { $0.id == id }) {
            activeHostID = id
        } else {
            activeHostID = hosts.first?.id
        }
        attachCredentials()
        #if os(macOS)
        adoptLocalLaunchURL()
        backfillLocalChatToken()
        #endif
    }

    #if os(macOS)
    private func localClutchHome() -> String {
        if let override = ProcessInfo.processInfo.environment["CLUTCH_HOME"], !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clutch").path
    }

    /// The sidecar's chat-bridge Bearer token (`$CLUTCH_HOME/chat-token`,
    /// owner-only). The Dock shell already read this file for its remote
    /// mode, so this is established behavior, not a new privilege.
    private func localChatToken() -> String? {
        let path = (localClutchHome() as NSString).appendingPathComponent("chat-token")
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// On the Mac the server runs on this machine: adopt its launch-URL file
    /// (`~/.clutch/web-launch-url`, rewritten on every web start) as the
    /// initial pairing, so first run connects with no paste step — the same
    /// zero-config behavior the Dock shell had. Only fills an empty store;
    /// never touches an existing pairing.
    private func adoptLocalLaunchURL() {
        guard hosts.isEmpty else { return }
        let path = (localClutchHome() as NSString).appendingPathComponent("web-launch-url")
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              case .success(var payload) = PairingLink.parse(raw) else { return }
        if payload.chatToken == nil { payload.chatToken = localChatToken() }
        _ = pair(payload)
    }

    /// Installs paired before the token file was read: attach it to loopback
    /// hosts that still lack one. Never touches remote (Tailscale) hosts.
    private func backfillLocalChatToken() {
        guard let token = localChatToken() else { return }
        var changed = false
        for index in hosts.indices where hosts[index].chatToken?.isEmpty ?? true {
            let host = (hosts[index].origin.host ?? "").lowercased()
            guard host == "127.0.0.1" || host == "localhost" else { continue }
            hosts[index].chatToken = token
            changed = true
        }
        if changed { save() }
    }
    #endif

    private func save() {
        // The archive carries the hosts without their tokens, and the tokens
        // go to the keychain instead.
        var stored = hosts
        for index in stored.indices {
            let chat = stored[index].chatToken
            let launch = stored[index].pendingLaunchToken
            stored[index].chatToken = nil
            stored[index].pendingLaunchToken = nil
            if let chat, KeychainStore.read(Self.chatAccount(for: stored[index].id)) != chat {
                KeychainStore.write(chat, account: Self.chatAccount(for: stored[index].id))
            }
            if let launch, KeychainStore.read(Self.launchAccount(for: stored[index].id)) != launch {
                KeychainStore.write(launch, account: Self.launchAccount(for: stored[index].id))
            }
        }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.storageKey)
        }
        defaults.set(activeHostID?.uuidString, forKey: Self.activeKey)
    }

    /// Puts the credentials back on the hosts.
    ///
    /// An archive written before the tokens moved to the keychain still
    /// carries them, and they move across on the first load; a host that has
    /// no token in the archive takes the one the keychain holds.
    private func attachCredentials() {
        var moved = false
        for index in hosts.indices {
            if let chat = hosts[index].chatToken {
                KeychainStore.write(chat, account: Self.chatAccount(for: hosts[index].id))
                moved = true
            } else if let chat = KeychainStore.read(Self.chatAccount(for: hosts[index].id)) {
                hosts[index].chatToken = chat
            }
            if let launch = hosts[index].pendingLaunchToken {
                KeychainStore.write(launch, account: Self.launchAccount(for: hosts[index].id))
                moved = true
            } else if let launch = KeychainStore.read(Self.launchAccount(for: hosts[index].id)) {
                hosts[index].pendingLaunchToken = launch
            }
        }
        // The archive is rewritten without the tokens it carried.
        if moved { save() }
    }

    /// The keychain account a host's chat token sits under.
    static func chatAccount(for id: UUID) -> String { "host.\(id.uuidString).chat" }

    /// The keychain account a host's launch token sits under.
    static func launchAccount(for id: UUID) -> String { "host.\(id.uuidString).launch" }

    private static func clearWebsiteData(for host: ClutchHost) {
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
