import Foundation
import Observation

/// One approval the engine is waiting on, keyed by host and session.
public struct TurnActivityApproval: Identifiable, Equatable, Sendable {
    /// The host the approval came from.
    ///
    /// The activity store is shared by every host this device talks to, so
    /// an entry says which host it belongs to: the home list shows the
    /// activity of the host on screen and nobody else's.
    public var hostId: UUID
    public var sessionId: String
    public var title: String
    public var id: String { "\(hostId)|\(sessionId)" }

    public init(hostId: UUID, sessionId: String, title: String) {
        self.hostId = hostId
        self.sessionId = sessionId
        self.title = title
    }
}

/// One turn currently streaming, keyed by host and session.
public struct TurnActivityRun: Identifiable, Equatable, Sendable {
    /// The host the run belongs to; see `TurnActivityApproval`.
    public var hostId: UUID
    public var sessionId: String
    public var title: String
    public var id: String { "\(hostId)|\(sessionId)" }

    public init(hostId: UUID, sessionId: String, title: String) {
        self.hostId = hostId
        self.sessionId = sessionId
        self.title = title
    }
}

/// What this device has seen the engines doing, so the home list can put
/// "needs you" and "running" work above the ordinary thread sections.
///
/// It only knows about turns this app has streamed.  A turn started on the
/// Mac shows up here when its thread is opened on this device, and the
/// TurnNotifier notification covers what arrives while the app is away —
/// between the two, an approval can no longer stall a turn invisibly.
///
/// Every entry carries the host it belongs to, so switching hosts never
/// shows the other host's approvals or runs as this one's.
@MainActor
@Observable
public final class TurnActivity {
    public static let shared = TurnActivity()

    public private(set) var approvals: [TurnActivityApproval] = []
    public private(set) var runs: [TurnActivityRun] = []

    public init() {}

    /// Records (or refreshes) the approval one session is waiting on.
    public func approvalArrived(hostId: UUID, sessionId: String, title: String) {
        upsert(&approvals, TurnActivityApproval(hostId: hostId, sessionId: sessionId, title: title))
    }

    /// Clears the approval for one session, whatever answered it.
    public func approvalResolved(hostId: UUID, sessionId: String) {
        approvals.removeAll { $0.hostId == hostId && $0.sessionId == sessionId }
    }

    /// Records (or refreshes) the turn one session is streaming.
    public func runStarted(hostId: UUID, sessionId: String, title: String) {
        upsert(&runs, TurnActivityRun(hostId: hostId, sessionId: sessionId, title: title))
    }

    /// Clears the running marker for one session, whatever ended it.
    public func runEnded(hostId: UUID, sessionId: String) {
        runs.removeAll { $0.hostId == hostId && $0.sessionId == sessionId }
    }

    /// One entry per host and session, newest activity last, so the home
    /// list keeps a stable order while a turn re-reports itself on every
    /// event.
    private func upsert<T: Identifiable & Equatable>(_ list: inout [T], _ entry: T) {
        if let index = list.firstIndex(where: { $0.id == entry.id }) {
            list[index] = entry
        } else {
            list.append(entry)
        }
    }
}
