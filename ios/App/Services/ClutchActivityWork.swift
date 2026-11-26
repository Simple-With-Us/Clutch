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
    /// The overlap is keyed by the thread, which is the host, the engine the
    /// thread runs on and the session:  two hosts can hold a session with the
    /// same id, and one host's engines number their own sessions, so a Muse
    /// thread with an id and a MiniMax Code thread with the same id are two
    /// threads and not one.  The request is not part of the key, because the
    /// request is not part of the thread.
    static func split(approvals: [TurnActivityApproval],
                      runs: [TurnActivityRun]) -> (waiting: [TurnActivityApproval], running: [TurnActivityRun]) {
        var waiting: [TurnActivityApproval] = []
        var waitingThreads = Set<TurnThreadKey>()
        for approval in approvals {
            guard waitingThreads.insert(approval.thread).inserted else { continue }
            waiting.append(approval)
        }
        let running = runs.filter { !waitingThreads.contains($0.thread) }
        return (waiting, running)
    }
}
