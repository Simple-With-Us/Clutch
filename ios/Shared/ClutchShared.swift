import Foundation

/// The things the app and its widget extension have to agree on.
///
/// The app writes what the engine is doing into the shared container and the
/// extension reads it back:  an extension cannot see the app's own
/// preferences, so the count on the Lock Screen can only come from somewhere
/// both halves can reach.
public enum ClutchShared {
    /// The App Group the app and the extension share.
    ///
    /// The group is named after the app's own registered identifier, so it
    /// sits in the same namespace the bundle ids already do and asks for
    /// no domain of its own.
    public static let appGroupId = "group.codes.clutch.ios"

    /// The kind the Lock Screen accessory widget is registered under.
    ///
    /// The app names the kind when it asks the system to reload the
    /// timelines, so the string lives in one place both halves read.
    public static let approvalCountWidgetKind = "ClutchApprovalCount"

    /// The preferences suite for the group, when there is one.
    ///
    /// A build whose group is not registered gets no suite at all, and a
    /// surface that reads it then shows nothing rather than failing:  a
    /// missing group is a missing convenience, not a broken app.
    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }
}

/// What the extension reads out of the shared container.
///
/// The snapshot is counts and a timestamp and nothing else:  no thread
/// title, no tool name, no command and no path.  The Lock Screen shows a
/// number, and the number is all this carries.
public struct ClutchApprovalSnapshot: Codable, Equatable, Sendable {
    /// The approvals waiting for the owner.
    public var waitingCount: Int
    /// The turns currently running.
    public var runningCount: Int
    /// When the count was written.
    public var updatedAt: Date

    public init(waitingCount: Int, runningCount: Int, updatedAt: Date = Date()) {
        self.waitingCount = waitingCount
        self.runningCount = runningCount
        self.updatedAt = updatedAt
    }

    /// The snapshot for a device with nothing waiting and nothing running.
    public static let empty = ClutchApprovalSnapshot(waitingCount: 0, runningCount: 0, updatedAt: .distantPast)
}

/// Reads and writes the snapshot in the shared container.
public enum ClutchSharedStore {
    /// The key the snapshot is stored under.
    public static let snapshotKey = "codes.clutch.approvals.snapshot"

    /// Writes the snapshot for the extension to read.
    ///
    /// The write is skipped when there is no shared container, so a build
    /// without the group registered keeps working with the surfaces it has.
    public static func write(_ snapshot: ClutchApprovalSnapshot, to defaults: UserDefaults? = ClutchShared.sharedDefaults) {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    /// The snapshot the extension reads.
    ///
    /// A missing or unreadable snapshot reads as nothing waiting, so a
    /// container that was never written to shows a quiet device rather than
    /// an error.
    public static func read(from defaults: UserDefaults? = ClutchShared.sharedDefaults) -> ClutchApprovalSnapshot {
        guard let defaults, let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(ClutchApprovalSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }
}

/// The link that opens the approvals list.
///
/// The shape is `clutch://approvals`.  The pairing link owns the `pair` host
/// and the thread link owns the `thread` host of the same scheme, so this
/// one owns `approvals` and the three never collide.
public enum ClutchApprovalsLink {
    /// The link itself.
    public static let url = URL(string: "clutch://approvals")!

    /// Whether a link asks for the approvals list.
    ///
    /// A link the app cannot read is left alone rather than guessed at.
    public static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "clutch" else { return false }
        return url.host?.lowercased() == "approvals"
    }
}
