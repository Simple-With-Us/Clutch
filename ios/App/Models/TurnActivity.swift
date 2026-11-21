import Foundation
import Observation

/// One approval the engine is waiting on, keyed by session.
public struct TurnActivityApproval: Identifiable, Equatable, Sendable {
    public var sessionId: String
    public var title: String
    public var id: String { sessionId }

    public init(sessionId: String, title: String) {
        self.sessionId = sessionId
        self.title = title
    }
}

/// One turn currently streaming, keyed by session.
public struct TurnActivityRun: Identifiable, Equatable, Sendable {
    public var sessionId: String
    public var title: String
    public var id: String { sessionId }

    public init(sessionId: String, title: String) {
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
@MainActor
@Observable
public final class TurnActivity {
    public static let shared = TurnActivity()

    public private(set) var approvals: [TurnActivityApproval] = []
    public private(set) var runs: [TurnActivityRun] = []

    public init() {}

    /// Records (or refreshes) the approval one session is waiting on.
    public func approvalArrived(sessionId: String, title: String) {
        upsert(&approvals, TurnActivityApproval(sessionId: sessionId, title: title))
    }

    /// Clears the approval for one session, whatever answered it.
    public func approvalResolved(sessionId: String) {
        approvals.removeAll { $0.sessionId == sessionId }
    }

    /// Records (or refreshes) the turn one session is streaming.
    public func runStarted(sessionId: String, title: String) {
        upsert(&runs, TurnActivityRun(sessionId: sessionId, title: title))
    }

    /// Clears the running marker for one session, whatever ended it.
    public func runEnded(sessionId: String) {
        runs.removeAll { $0.sessionId == sessionId }
    }

    /// One entry per session, newest activity last, so the home list keeps a
    /// stable order while a turn re-reports itself on every event.
    private func upsert<T: Identifiable & Equatable>(_ list: inout [T], _ entry: T) {
        if let index = list.firstIndex(where: { $0.id == entry.id }) {
            list[index] = entry
        } else {
            list.append(entry)
        }
    }
}
