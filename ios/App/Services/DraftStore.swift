import Foundation

/// Unsent composer text, kept per host and thread.
///
/// A composed prompt used to live only in the thread view's state, so a
/// relaunch, a process death, or recreating the view silently lost it.
/// The store keeps the newest drafts in one file under Application
/// Support, written with data protection and excluded from backup: a
/// draft can hold whatever the owner pasted, and none of it belongs in a
/// backed-up preferences plist.  Drafts older than a month are forgotten,
/// so the file cannot become an archive of everything ever typed.
/// Attachments do not ride along, so a restored draft is the text alone,
/// which is the part that took the typing.
enum DraftStore {
    /// How many threads keep a draft at once; the oldest go first.
    static let maxDrafts = 100
    /// How long an untouched draft is kept before it is forgotten.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private struct StoredDraft: Codable {
        var text: String
        var updatedAt: Date
    }

    /// The in-memory table, so a save never re-reads the file it is about
    /// to rewrite.  Saves arrive from a debounced background task while
    /// reads happen on the main actor, so one lock covers both.
    private static let lock = NSLock()
    private static var cachedTable: [String: StoredDraft]?
    private static var cachedFile: URL?
    /// The newest save generation seen per thread.  A debounced write that
    /// lands after a newer edit (or a flush) carries an older generation
    /// and is refused under the same lock that writes, so stale words can
    /// never overwrite newer ones.
    private static var generations: [String: Int] = [:]

    /// The table key for one thread on one host.
    static func key(hostId: UUID, sessionId: String) -> String {
        "\(hostId.uuidString)#\(sessionId)"
    }

    /// The draft left in one thread, or empty when there is none — or
    /// when what is left has aged out, so expiry holds on read as well as
    /// on the saves that prune the file.
    static func draft(hostId: UUID, sessionId: String, in directory: URL? = nil, now: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = table(in: directory)[key(hostId: hostId, sessionId: sessionId)],
              now.timeIntervalSince(entry.updatedAt) <= maxAge else { return "" }
        return entry.text
    }

    /// Keeps a thread's draft.  Empty text forgets it, so sending, which
    /// clears the composer, clears the store through the same write.  The
    /// whole text is kept: a cap here would silently lose the tail of a
    /// long paste, and the count and age bounds already limit the file.
    static func save(
        _ text: String,
        hostId: UUID,
        sessionId: String,
        in directory: URL? = nil,
        generation: Int? = nil,
        now: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        let entryKey = key(hostId: hostId, sessionId: sessionId)
        if let generation {
            if generation < (generations[entryKey] ?? 0) { return }
            generations[entryKey] = generation
        }
        var table = table(in: directory)
        let loadedCount = table.count
        table = table.filter { now.timeIntervalSince($0.value.updatedAt) <= maxAge }
        let prunedExpired = table.count != loadedCount
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard table.removeValue(forKey: entryKey) != nil else {
                cachedTable = table
                // Expiry pruned on this pass still has to reach the file,
                // or the forgotten drafts return on the next cold load.
                if prunedExpired { persist(table, in: directory) }
                return
            }
        } else if table[entryKey]?.text == text {
            // Reaffirming the same words still counts as use: without the
            // recency bump a live thread sorts oldest and evicts first.
            table[entryKey]?.updatedAt = now
        } else {
            table[entryKey] = StoredDraft(text: text, updatedAt: now)
        }
        if table.count > maxDrafts {
            let oldest = table.sorted { $0.value.updatedAt < $1.value.updatedAt }
            for entry in oldest.prefix(table.count - maxDrafts) {
                table.removeValue(forKey: entry.key)
            }
        }
        cachedTable = table
        persist(table, in: directory)
    }

    /// The file the table lives in, inside the given directory or the
    /// app's own Application Support folder.
    static func fileURL(in directory: URL? = nil) -> URL {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clutch", isDirectory: true)
        return base.appendingPathComponent("Drafts.json")
    }

    private static func table(in directory: URL?) -> [String: StoredDraft] {
        let file = fileURL(in: directory)
        if cachedFile == file, let cachedTable { return cachedTable }
        let loaded: [String: StoredDraft]
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String: StoredDraft].self, from: data) {
            loaded = decoded
        } else {
            loaded = [:]
        }
        cachedFile = file
        cachedTable = loaded
        return loaded
    }

    private static func persist(_ table: [String: StoredDraft], in directory: URL?) {
        let file = fileURL(in: directory)
        guard let data = try? JSONEncoder().encode(table) else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var stored = file
            try? stored.setResourceValues(values)
        } catch {
            // A draft that cannot be kept is a convenience lost, not a
            // failure to surface over the thread itself.
        }
    }
}
