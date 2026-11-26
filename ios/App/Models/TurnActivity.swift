import Foundation
import Observation

/// The identity of one thread:  the host it runs on, the engine that owns it,
/// and the id that engine gave it.
///
/// The engine is part of the key because every engine on a host numbers its
/// own sessions:  a Muse thread and a MiniMax Code thread can carry the same
/// raw id, and they are not the same thread.  Keying on the raw id alone let
/// one engine's activity stand in for the other's.
public struct TurnThreadKey: Hashable, Sendable {
    public var hostId: UUID
    public var engine: String
    public var sessionId: String

    public init(hostId: UUID, engine: String, sessionId: String) {
        self.hostId = hostId
        self.engine = engine
        self.sessionId = sessionId
    }
}

/// One approval the engine is waiting on, keyed by host, engine, session and
/// request.
///
/// The request is part of the key because a session can be waiting on more
/// than one request:  an acknowledgment names the request it answers, so the
/// activity state it clears has to be the state of that request and not of
/// every request the session happens to be holding.
public struct TurnActivityApproval: Identifiable, Equatable, Sendable {
    /// The host the approval came from.
    ///
    /// The activity store is shared by every host this device talks to, so
    /// an entry says which host it belongs to: the home list shows the
    /// activity of the host on screen and nobody else's.
    public var hostId: UUID
    /// The engine that raised the request.
    ///
    /// A host serves more than one engine and each numbers its own sessions,
    /// so the raw session id does not say which one is blocked.
    public var engine: String
    public var sessionId: String
    /// The permission request the engine is waiting on.
    public var requestId: String
    public var title: String
    /// The thread this approval belongs to.
    public var thread: TurnThreadKey {
        TurnThreadKey(hostId: hostId, engine: engine, sessionId: sessionId)
    }
    public var id: String { "\(hostId)|\(engine)|\(sessionId)|\(requestId)" }

    public init(hostId: UUID, engine: String, sessionId: String, requestId: String, title: String) {
        self.hostId = hostId
        self.engine = engine
        self.sessionId = sessionId
        self.requestId = requestId
        self.title = title
    }
}

/// One turn currently streaming, keyed by host, engine and session.
public struct TurnActivityRun: Identifiable, Equatable, Sendable {
    /// The host the run belongs to; see `TurnActivityApproval`.
    public var hostId: UUID
    /// The engine running the turn; see `TurnActivityApproval`.
    public var engine: String
    public var sessionId: String
    public var title: String
    /// The thread this run belongs to.
    public var thread: TurnThreadKey {
        TurnThreadKey(hostId: hostId, engine: engine, sessionId: sessionId)
    }
    public var id: String { "\(hostId)|\(engine)|\(sessionId)" }

    public init(hostId: UUID, engine: String, sessionId: String, title: String) {
        self.hostId = hostId
        self.engine = engine
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
/// Every entry carries the host and the engine it belongs to, so switching
/// hosts never shows the other host's approvals or runs as this one's, and
/// two engines that happen to number a session the same stay apart.
@MainActor
@Observable
public final class TurnActivity {
    public static let shared = TurnActivity()

    public private(set) var approvals: [TurnActivityApproval] = []
    public private(set) var runs: [TurnActivityRun] = []

    public init() {}

    /// Records (or refreshes) the approval one request is waiting on.
    public func approvalArrived(hostId: UUID, engine: String, sessionId: String, requestId: String, title: String) {
        upsert(
            &approvals,
            TurnActivityApproval(
                hostId: hostId,
                engine: engine,
                sessionId: sessionId,
                requestId: requestId,
                title: title
            )
        )
        // The title is the thread's name, so it belongs to the thread and not
        // to the one request that happened to arrive:  a thread that was
        // renamed while two requests were waiting would otherwise keep the
        // old name on the row the home list shows.
        for index in approvals.indices
        where approvals[index].hostId == hostId
            && approvals[index].engine == engine
            && approvals[index].sessionId == sessionId {
            approvals[index].title = title
        }
    }

    /// Clears the approval one acknowledgment names, and nothing else.
    ///
    /// A request that is not on the list is a no-op:  nothing changes and no
    /// other request's approval is cleared, so an acknowledgment for a card
    /// that has already gone cannot take another card's row with it.
    public func approvalAcknowledged(hostId: UUID, engine: String, sessionId: String, requestId: String) {
        approvals.removeAll {
            $0.hostId == hostId
                && $0.engine == engine
                && $0.sessionId == sessionId
                && $0.requestId == requestId
        }
    }

    /// Clears every approval the thread was waiting on, whatever ended it.
    public func approvalsCleared(hostId: UUID, engine: String, sessionId: String) {
        approvals.removeAll {
            $0.hostId == hostId && $0.engine == engine && $0.sessionId == sessionId
        }
    }

    /// The approvals the home list shows, one row per thread.
    ///
    /// A thread waiting on two requests is one row and not two:  the row
    /// opens the thread, and the card in it is the one the owner answers.
    /// Another host's approvals are not this host's business, a thread the
    /// list already shows is not shown twice, and a listed thread of one
    /// engine does not hide another engine's thread that happens to carry
    /// the same raw id.
    public static func approvalsForHomeList(
        _ approvals: [TurnActivityApproval],
        hostId: UUID,
        listed: Set<TurnThreadKey>
    ) -> [TurnActivityApproval] {
        var shown = Set<TurnThreadKey>()
        var rows: [TurnActivityApproval] = []
        for approval in approvals {
            guard approval.hostId == hostId else { continue }
            guard !listed.contains(approval.thread) else { continue }
            guard shown.insert(approval.thread).inserted else { continue }
            rows.append(approval)
        }
        return rows
    }

    /// The engines this device has seen activity for on one raw session id.
    ///
    /// A link written before the engine rode in it names no engine, so this
    /// is how a surface finds out which engine the thread belongs to:
    /// exactly one entry is an answer, and none or several leave nothing to
    /// resolve without guessing.
    public func enginesWithActivity(hostId: UUID, sessionId: String) -> [String] {
        var seen = Set<String>()
        var engines: [String] = []
        let waiting = approvals
            .filter { $0.hostId == hostId && $0.sessionId == sessionId }
            .map(\.engine)
        let running = runs
            .filter { $0.hostId == hostId && $0.sessionId == sessionId }
            .map(\.engine)
        for engine in waiting + running where seen.insert(engine).inserted {
            engines.append(engine)
        }
        return engines
    }

    /// Records (or refreshes) the turn one thread is streaming.
    public func runStarted(hostId: UUID, engine: String, sessionId: String, title: String) {
        upsert(
            &runs,
            TurnActivityRun(hostId: hostId, engine: engine, sessionId: sessionId, title: title)
        )
    }

    /// Clears the running marker for one thread, whatever ended it.
    ///
    /// The engine is part of the thread, so ending a Muse turn never clears
    /// a MiniMax Code turn that happens to carry the same raw session id.
    public func runEnded(hostId: UUID, engine: String, sessionId: String) {
        runs.removeAll {
            $0.hostId == hostId && $0.engine == engine && $0.sessionId == sessionId
        }
    }

    /// One entry per thread, newest activity last, so the home list keeps a
    /// stable order while a turn re-reports itself on every event.
    private func upsert<T: Identifiable & Equatable>(_ list: inout [T], _ entry: T) {
        if let index = list.firstIndex(where: { $0.id == entry.id }) {
            list[index] = entry
        } else {
            list.append(entry)
        }
    }
}
