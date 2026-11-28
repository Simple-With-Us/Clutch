import Foundation

/// Working folders a user has started threads in, per host, so the next
/// thread is one tap instead of a browse.
///
/// A phone-created thread without a folder lands in the sidecar's `$HOME`
/// default, and the ACP bridge then refuses to resume that thread anywhere
/// else — so the folder a thread works in is the single most important
/// choice the New Thread sheet makes, and the recents list is what makes
/// the right choice the cheap one.
public enum RecentFolderStore {
    static let storageKey = "codes.clutch.recentFolders.v1"
    static let maximum = 5

    /// The folders this host has recently started threads in, newest first.
    public static func recent(forHost hostId: UUID, defaults: UserDefaults = .standard) -> [String] {
        all(defaults: defaults)[hostId.uuidString] ?? []
    }

    /// Records a folder at the front of its host's list, deduped and capped.
    public static func add(_ folder: String, forHost hostId: UUID, defaults: UserDefaults = .standard) {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var table = all(defaults: defaults)
        var list = table[hostId.uuidString] ?? []
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        if list.count > maximum { list = Array(list.prefix(maximum)) }
        table[hostId.uuidString] = list
        if let data = try? JSONEncoder().encode(table) {
            defaults.set(data, forKey: storageKey)
        }
    }

    /// Fills an empty recents list from folders the caller already knows,
    /// such as the working folders of the host's threads.
    ///
    /// Folders the owner picked stay first: seeds only append what is not
    /// already listed, so a fresh install offers its threads' folders while
    /// an established list is left alone.
    public static func seed(_ folders: [String], forHost hostId: UUID, defaults: UserDefaults = .standard) {
        var table = all(defaults: defaults)
        var list = table[hostId.uuidString] ?? []
        var changed = false
        for folder in folders {
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !list.contains(trimmed) else { continue }
            list.append(trimmed)
            changed = true
        }
        guard changed else { return }
        if list.count > maximum { list = Array(list.prefix(maximum)) }
        table[hostId.uuidString] = list
        if let data = try? JSONEncoder().encode(table) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func all(defaults: UserDefaults) -> [String: [String]] {
        guard let data = defaults.data(forKey: storageKey),
              let table = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return table
    }
}
