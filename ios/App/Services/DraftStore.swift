import Foundation

/// Unsent composer text, kept per host and thread.
///
/// A composed prompt used to live only in the thread view's state, so a
/// relaunch, a process death, or recreating the view silently lost it.
/// The store keeps the newest drafts in the preferences file: they are the
/// owner's own words on their own device, never a credential, so the
/// keychain would be the wrong home for them.  Attachments do not ride
/// along — image data has no business in preferences — so a restored draft
/// is the text by itself, which is the part that took the typing.
enum DraftStore {
    /// The key every draft sits under, as one encoded table.
    static let storageKey = "codes.clutch.drafts.v1"
    /// How much of one draft is kept.  A prompt longer than this is a file
    /// paste, and the preferences file is not where files live.
    static let maxDraftLength = 20_000
    /// How many threads keep a draft at once; the oldest go first.
    static let maxDrafts = 100

    private struct StoredDraft: Codable {
        var text: String
        var updatedAt: Date
    }

    /// The table key for one thread on one host.
    static func key(hostId: UUID, sessionId: String) -> String {
        "\(hostId.uuidString)#\(sessionId)"
    }

    /// The draft left in one thread, or empty when there is none.
    static func draft(hostId: UUID, sessionId: String, in defaults: UserDefaults = .standard) -> String {
        load(in: defaults)[key(hostId: hostId, sessionId: sessionId)]?.text ?? ""
    }

    /// Keeps a thread's draft.  Empty text forgets it, so sending, which
    /// clears the composer, clears the store through the same write.
    static func save(_ text: String, hostId: UUID, sessionId: String, in defaults: UserDefaults = .standard) {
        let entryKey = key(hostId: hostId, sessionId: sessionId)
        var table = load(in: defaults)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard table.removeValue(forKey: entryKey) != nil else { return }
        } else {
            let kept = String(text.prefix(maxDraftLength))
            if table[entryKey]?.text == kept { return }
            table[entryKey] = StoredDraft(text: kept, updatedAt: Date())
            if table.count > maxDrafts {
                let oldest = table.sorted { $0.value.updatedAt < $1.value.updatedAt }
                for entry in oldest.prefix(table.count - maxDrafts) {
                    table.removeValue(forKey: entry.key)
                }
            }
        }
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(in defaults: UserDefaults) -> [String: StoredDraft] {
        guard let data = defaults.data(forKey: storageKey),
              let table = try? JSONDecoder().decode([String: StoredDraft].self, from: data) else {
            return [:]
        }
        return table
    }
}
