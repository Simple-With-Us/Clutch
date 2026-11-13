import Foundation

/// Threads the owner pinned, kept on-device per host.  Pinning is a local
/// reading aid only — MiniMax Code has no pin concept of its own, so nothing
/// here ever reaches the sidecar, and an unpinned thread is untouched.
public enum ThreadPinStore {
    private static func key(forHost hostID: UUID) -> String {
        "codes.clutch.pinned-threads.\(hostID.uuidString)"
    }

    public static func pinnedIDs(forHost hostID: UUID, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key(forHost: hostID)) ?? [])
    }

    public static func isPinned(_ sessionId: String, forHost hostID: UUID, defaults: UserDefaults = .standard) -> Bool {
        pinnedIDs(forHost: hostID, defaults: defaults).contains(sessionId)
    }

    @discardableResult
    public static func toggle(_ sessionId: String, forHost hostID: UUID, defaults: UserDefaults = .standard) -> Bool {
        var ids = pinnedIDs(forHost: hostID, defaults: defaults)
        let nowPinned: Bool
        if ids.contains(sessionId) {
            ids.remove(sessionId)
            nowPinned = false
        } else {
            ids.insert(sessionId)
            nowPinned = true
        }
        defaults.set(Array(ids), forKey: key(forHost: hostID))
        return nowPinned
    }
}
