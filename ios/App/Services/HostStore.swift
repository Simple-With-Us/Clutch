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

    /// The preferences the app keeps its hosts in.
    ///
    /// A UI test names a suite of its own, so a test run never unpairs the
    /// hosts the owner has on this machine.  Everything else uses the app's
    /// own suite.
    static func resolveDefaults() -> UserDefaults {
        #if DEBUG
        if let suite = DebugLaunch.defaultsSuite, !suite.isEmpty {
            // A suite that cannot be created must not fall back to the
            // owner's own defaults:  the reset in the initializer would then
            // clear the hosts the owner has on this machine, which is the
            // harm the suite exists to prevent.  A suite name that cannot be
            // created is a defect in the run, and the process stops here
            // rather than touching state that belongs to somebody else.
            guard let isolated = UserDefaults(suiteName: suite) else {
                fatalError("the UI test defaults suite \(suite) could not be created")
            }
            return isolated
        }
        #endif
        return .standard
    }

    static let storageKey = "codes.clutch.hosts.v3"
    static let activeKey = "codes.clutch.activeHost.v3"

    /// The preferences that have already been cleared in this process.
    ///
    /// A UI test starts from first run, and the reset happens once for
    /// each set of preferences:  a second store over the same suite must
    /// not clear the hosts that were paired after the first one was
    /// built, and a store over a different suite must still get its own
    /// first run.
    private static var clearedPreferences: Set<String> = []

    /// What a set of preferences is called, for the reset that happens once.
    ///
    /// The key is the suite's name and not the identity of the object,
    /// because two calls to `UserDefaults(suiteName:)` make two objects
    /// over one suite, and both of them belong to the same first run.
    private static func resetKey(for defaults: UserDefaults) -> String {
        if defaults === UserDefaults.standard { return "standard" }
        if let suite = DebugLaunch.defaultsSuite, !suite.isEmpty { return suite }
        return "preferences-\(ObjectIdentifier(defaults).hashValue)"
    }

    public private(set) var hosts: [ClutchHost] = []
    public private(set) var activeHostID: UUID?

    @ObservationIgnored private let defaults: UserDefaults

    /// Creates a host store over the preferences it was given.
    ///
    /// A store that was not given preferences takes the same ones the shared
    /// store takes, so a view that builds its own store honours the suite a
    /// UI test asked for.  A store that was built over the owner's own
    /// defaults while a test asked for an isolated suite would reset and
    /// re-pair the owner's hosts, which is exactly what the suite is there
    /// to prevent.
    public init(defaults: UserDefaults? = nil) {
        let resolved = defaults ?? Self.resolveDefaults()
        self.defaults = resolved
        #if DEBUG
        // A UI test starts from first run.  The reset happens here rather
        // than in the app's initializer, so it always runs before the
        // hosts are loaded and no stale host can survive it.
        Self.resetForFirstRun(defaults: resolved)
        #endif
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
            if let launchToken = payload.launchToken { hosts[index].pendingLaunchToken = launchToken }
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
    /// Clears the hosts of a set of preferences once, when a run asked for
    /// a first-run start.
    ///
    /// The reset happens once for each set of preferences:  the Mac app
    /// builds more than one store, and a second store over the same suite
    /// would clear the hosts the first one paired, while a store over a
    /// different suite still has to get its own first run.
    ///
    /// It is a function of its own so the behaviour can be tested without
    /// a launch argument.
    static func resetForFirstRun(
        defaults: UserDefaults,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        guard arguments.contains("-ClutchResetHosts") else { return }
        guard clearedPreferences.insert(resetKey(for: defaults)).inserted else { return }
        resetPersistedHosts(defaults: defaults)
    }

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
        // A UI test pairs the app with its stub from a launch argument, and
        // a test must not adopt the machine's own launch URL or the
        // machine's own token, so both are left alone when the run named a
        // link of its own.
        if pairForUITest() {
            return
        }
        adoptLocalLaunchURL()
        backfillLocalChatToken()
        #endif
    }

    #if os(macOS)
    /// Pairs the app with the link a UI test named, and reports whether it
    /// did.
    @discardableResult
    private func pairForUITest() -> Bool {
        guard let raw = DebugLaunch.pairingLink,
              case .success(var payload) = PairingLink.parse(raw) else { return false }
        if payload.chatToken == nil { payload.chatToken = localChatToken() }
        _ = pair(payload)
        return true
    }
    #endif

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
        let path = (localClutchHome() as NSString).appendingPathComponent("web-launch-url")
        guard hosts.isEmpty else { return }
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
            guard hosts[index].isLocal else { continue }
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
                // A keychain that will not take the token does not get to
                // lose it: the archive keeps a copy.
                if !KeychainStore.write(chat, account: Self.chatAccount(for: stored[index].id)) {
                    stored[index].chatToken = chat
                }
            }
            if let launch, KeychainStore.read(Self.launchAccount(for: stored[index].id)) != launch {
                if !KeychainStore.write(launch, account: Self.launchAccount(for: stored[index].id)) {
                    stored[index].pendingLaunchToken = launch
                }
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
