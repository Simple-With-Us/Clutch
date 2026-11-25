import Foundation

/// The waiting and the running work, with the overlap taken out.
///
/// A thread that is waiting on the owner is still in the store's runs,
/// because the turn has not ended:  it is blocked, not working.  It is
/// counted once, as waiting, or the island would say a thread is both
/// waiting and running, and would show it twice.
///
/// This lives outside the Live Activity's own file because the Mac shows
/// the same split in its approvals list, and the Mac has no Live Activity.
enum ClutchActivityWork {
    /// Splits the store's entries into what is waiting and what is running.
    ///
    /// A thread waiting on two requests is one thread and one row, the way
    /// the home list shows it:  the row opens the thread, and the card in
    /// it is the one the owner answers.
    ///
    /// The overlap is keyed by the thread, which is the host and the
    /// session:  two hosts can hold a session with the same id, and one
    /// host's waiting thread is not the other host's running thread.  The
    /// request is not part of the key, because the request is not part of
    /// the thread.
    static func split(approvals: [TurnActivityApproval],
                      runs: [TurnActivityRun]) -> (waiting: [TurnActivityApproval], running: [TurnActivityRun]) {
        var waiting: [TurnActivityApproval] = []
        var waitingThreads = Set<String>()
        for approval in approvals {
            guard waitingThreads.insert(threadKey(hostId: approval.hostId, sessionId: approval.sessionId)).inserted else {
                continue
            }
            waiting.append(approval)
        }
        let running = runs.filter {
            !waitingThreads.contains(threadKey(hostId: $0.hostId, sessionId: $0.sessionId))
        }
        return (waiting, running)
    }

    /// The key a thread is known by:  the host and the session.
    ///
    /// It is not the entry's own id, because an approval's id carries the
    /// request as well:  a session can wait on more than one request, and
    /// the request is not part of the thread.
    private static func threadKey(hostId: UUID, sessionId: String) -> String {
        "\(hostId)|\(sessionId)"
    }
}
