#if canImport(ActivityKit) && !os(macOS)
import ActivityKit
import Foundation

/// The Live Activity's contract — compiled into both the app and the widget
/// extension, so the two agree on what the island says.
///
/// The content is the same shape the lock screen already accepted:  thread
/// titles and a status, and nothing else.  A tool name, a command, a path
/// and a diff never reach this state, because a Live Activity is a surface
/// that shows without being opened and the owner's eyes are not on it.
public struct ClutchActivityAttributes: ActivityAttributes {
    /// What the activity is showing right now.
    public struct ContentState: Codable, Hashable {
        /// The approvals waiting for the owner.
        public var waitingCount: Int
        /// The turns currently running.
        public var runningCount: Int
        /// Up to three sessions, the ones the owner would look at first.
        public var sessions: [ClutchActivitySession]
        /// When the state was written.
        public var updatedAt: Date

        public init(waitingCount: Int, runningCount: Int, sessions: [ClutchActivitySession], updatedAt: Date = Date()) {
            self.waitingCount = waitingCount
            self.runningCount = runningCount
            self.sessions = sessions
            self.updatedAt = updatedAt
        }

        /// The state the app publishes for a set of waiting and running work.
        ///
        /// The counts are the totals, so a summary never lies about how much
        /// is waiting because only three sessions fit in the state.  The
        /// sessions are the ones that matter first — an approval before a
        /// run — and there are three of them, because the island shows three
        /// lines and a fourth would be a line nobody reads.
        public init(waiting: [ClutchActivitySession], running: [ClutchActivitySession], updatedAt: Date = Date()) {
            self.init(
                waitingCount: waiting.count,
                runningCount: running.count,
                sessions: Array((waiting + running).prefix(3)),
                updatedAt: updatedAt
            )
        }

        /// The state as the host's push carries it.
        ///
        /// The coding is the synthesized default, and that is the contract:
        /// ActivityKit decodes a pushed content-state with Apple's standard
        /// strategies, where a `Date` is seconds since 2001-01-01.  The host
        /// writes its timestamp on that scale, so the phone reads the moment
        /// the host meant.  A custom `CodingKey` layout here would be read
        /// by the system as the default one, which is why there is none.
    }

    public init() {}
}

/// One session in the Live Activity.
///
/// The identifier is an opaque session id and is never rendered:  it is
/// there so two entries for the same thread stay two entries, and the
/// island shows the title and the status and nothing else.
public struct ClutchActivitySession: Codable, Hashable, Identifiable {
    /// What the session is doing, as the island names it.
    public enum Status: String, Codable, Hashable {
        /// The engine is blocked on the owner.
        case waiting
        /// The engine is working.
        case running
    }

    public var id: String
    public var title: String
    public var status: Status

    public init(id: String, title: String, status: Status) {
        self.id = id
        self.title = title
        self.status = status
    }
}

/// The summary line the island and the lock screen lead with.
public enum ClutchActivitySummary {
    /// The one line that says what the device is waiting on.
    ///
    /// The counts are the totals the app knows about, not the number of
    /// lines that fit, so "2 waiting, 1 running" stays true when three
    /// sessions are shown and five are waiting.
    public static func text(waiting: Int, running: Int) -> String {
        switch (waiting, running) {
        case (0, 0):
            return "All Quiet"
        case (let w, 0):
            return "\(w) Waiting"
        case (0, let r):
            return "\(r) Running"
        case (let w, let r):
            return "\(w) Waiting, \(r) Running"
        }
    }
}
#endif
