#if canImport(ActivityKit) && !os(macOS)
import ActivityKit
import Foundation
import Observation
import WidgetKit

/// Publishes what the engines are doing to the surfaces that show it
/// without being opened:  the Live Activity on the lock screen and in the
/// island, and the count on the Lock Screen accessory.
///
/// The controller watches the same activity store the home list reads, so
/// the two never disagree:  the list says two threads want an approval and
/// the island says the same two.
///
/// What it publishes is counts and thread titles.  A tool name, a command,
/// a path and a diff never reach it, because these are surfaces that show
/// without being opened and the owner's eyes are not on them.
///
/// The Live Activity is updated from the app while the app is running.
/// A phone that has put the app in the background stops updating it, and
/// that is what the host push relay is for:  it is the last piece of the
/// programme, not the first, and the activity is worth having without it.
@MainActor
public final class ClutchActivityController {
    public static let shared = ClutchActivityController()

    /// The activity this device is showing, when there is one.
    private var activity: Activity<ClutchActivityAttributes>?
    /// The state the activity is carrying, so an unchanged state is not
    /// published again.
    private var publishedState: ClutchActivityAttributes.ContentState?
    /// Whether a request is already in flight.
    ///
    /// The request is asynchronous, and two refreshes that arrive together
    /// would otherwise both find no activity and ask for two.
    private var isRequesting = false
    /// Whether the watch is already running.
    private var isWatching = false

    public init() {}

    /// Starts publishing.
    ///
    /// An activity from an earlier run is adopted rather than duplicated:
    /// the system keeps a live activity across app launches, and a second
    /// one would put two islands on the same lock screen.
    public func start() {
        guard !isWatching else { return }
        isWatching = true
        if activity == nil {
            activity = Activity<ClutchActivityAttributes>.activities.first
            if let activity {
                publishedState = activity.content.state
                watch(activity)
            }
        }
        watch()
        refresh()
    }

    /// Publishes what the engines are doing right now.
    ///
    /// The call is cheap and does nothing when the state has not changed:
    /// the activity is updated with the state it already carries, and the
    /// widget is only asked to reload when the counts moved.
    public func refresh() {
        let snapshot = currentSnapshot()
        let state = currentState()
        write(snapshot)
        publish(state)
    }

    /// The counts the Lock Screen accessory shows.
    ///
    /// The count belongs to the host the app is looking at:  the activity
    /// store holds every host this device talks to, and another host's
    /// approval is not this host's business.  With no host picked there is
    /// nothing to scope to, so every host's work is counted.
    ///
    /// A thread that is waiting on the owner is not also running:  the
    /// engine is blocked, and counting it twice would say there is more
    /// work than there is.
    private func currentSnapshot() -> ClutchApprovalSnapshot {
        let (waiting, running) = currentWork()
        return ClutchApprovalSnapshot(waitingCount: waiting.count, runningCount: running.count)
    }

    /// The state the Live Activity shows.
    ///
    /// The titles are the thread names, and nothing else about the request
    /// is read:  the tool name and the evidence stay behind the tap.
    private func currentState() -> ClutchActivityAttributes.ContentState {
        let (waiting, running) = currentWork()
        return ClutchActivityAttributes.ContentState(
            waiting: waiting.map { ClutchActivitySession(id: $0.sessionId, title: $0.title, status: .waiting) },
            running: running.map { ClutchActivitySession(id: $0.sessionId, title: $0.title, status: .running) }
        )
    }

    /// The waiting and the running work, with the overlap taken out.
    ///
    /// A thread that is waiting on the owner is still in the store's runs,
    /// because the turn has not ended:  it is blocked, not working.  It is
    /// counted once, as waiting, or the island would say a thread is both.
    private func currentWork() -> ([TurnActivityApproval], [TurnActivityRun]) {
        let hostId = HostStore.shared.activeHostID
        let approvals = TurnActivity.shared.approvals.filter { hostId == nil || $0.hostId == hostId }
        let runs = TurnActivity.shared.runs.filter { hostId == nil || $0.hostId == hostId }
        return ClutchActivityWork.split(approvals: approvals, runs: runs)
    }

    /// Writes the count for the Lock Screen accessory and asks it to redraw.
    ///
    /// The reload is asked for when the counts moved, not when the
    /// timestamp moved:  a timestamp that changes on every write would
    /// ask the widget system to redraw for a count that did not change.
    private func write(_ snapshot: ClutchApprovalSnapshot) {
        let previous = ClutchSharedStore.read()
        ClutchSharedStore.write(snapshot)
        guard previous.waitingCount != snapshot.waitingCount ||
                previous.runningCount != snapshot.runningCount else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: ClutchShared.approvalCountWidgetKind)
    }

    /// Starts, updates or ends the Live Activity.
    ///
    /// Nothing waiting and nothing running ends the activity:  an island
    /// that says "All Quiet" forever is a permanent lie about a device that
    /// is simply idle.
    private func publish(_ state: ClutchActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(900))
        if state.waitingCount == 0 && state.runningCount == 0 {
            guard let activity else { return }
            self.activity = nil
            publishedState = nil
            Task { @MainActor in
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        if let activity {
            // An unchanged state is not published again:  every update is
            // an inter-process call and a re-render, and a turn that
            // re-reports itself would pay for both on every event.
            guard !sameState(publishedState, state) else { return }
            publishedState = state
            Task { @MainActor in
                await activity.update(content)
            }
        } else if !isRequesting {
            isRequesting = true
            Task { @MainActor in
                do {
                    let activity = try Activity.request(attributes: ClutchActivityAttributes(),
                                                        content: content,
                                                        pushType: nil)
                    self.activity = activity
                    self.publishedState = state
                    self.watch(activity)
                } catch {
                    // A live activity that cannot start is a missing
                    // convenience, not a failure worth interrupting the
                    // owner over:  the notification and the list still say
                    // what is waiting.
                }
                self.isRequesting = false
            }
        }
    }

    /// Whether two states say the same thing.
    ///
    /// The timestamp is not part of the comparison:  it records when the
    /// state was written, not what it says.
    private func sameState(_ lhs: ClutchActivityAttributes.ContentState?,
                           _ rhs: ClutchActivityAttributes.ContentState) -> Bool {
        guard let lhs else { return false }
        return lhs.waitingCount == rhs.waitingCount
            && lhs.runningCount == rhs.runningCount
            && lhs.sessions == rhs.sessions
    }

    /// Watches one activity, so a dismissed one is replaced rather than
    /// updated into nothing.
    ///
    /// The owner can swipe an activity away, and the system can end one
    /// when its time is up.  Either way the activity is gone, and the
    /// controller has to stop believing it is still there:  an update to a
    /// finished activity does nothing, and the island would never come
    /// back.
    private func watch(_ activity: Activity<ClutchActivityAttributes>) {
        Task { @MainActor in
            for await state in activity.activityStateUpdates {
                switch state {
                case .dismissed, .ended, .stale:
                    if self.activity?.id == activity.id {
                        self.activity = nil
                        self.publishedState = nil
                    }
                    return
                default:
                    continue
                }
            }
        }
    }

    /// Watches the activity store and the picked host.
    ///
    /// The watch is re-armed after every change, because the tracking is
    /// one-shot by design:  it reports the first change and then stops
    /// listening.
    private func watch() {
        withObservationTracking {
            _ = TurnActivity.shared.approvals
            _ = TurnActivity.shared.runs
            _ = HostStore.shared.activeHostID
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.watch()
            }
        }
    }
}

/// The waiting and the running work, with the overlap taken out.
///
/// A thread that is waiting on the owner is still in the store's runs,
/// because the turn has not ended:  it is blocked, not working.  It is
/// counted once, as waiting, or the island would say a thread is both
/// waiting and running, and would show it twice.
enum ClutchActivityWork {
    /// Splits the store's entries into what is waiting and what is running.
    ///
    /// The overlap is keyed by the entry's own id, which carries the host
    /// as well as the session:  two hosts can hold a session with the same
    /// id, and one host's waiting thread is not the other host's running
    /// thread.
    static func split(approvals: [TurnActivityApproval],
                      runs: [TurnActivityRun]) -> (waiting: [TurnActivityApproval], running: [TurnActivityRun]) {
        let waitingIds = Set(approvals.map(\.id))
        return (approvals, runs.filter { !waitingIds.contains($0.id) })
    }
}
#endif
