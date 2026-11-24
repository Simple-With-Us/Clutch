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
    private func currentSnapshot() -> ClutchApprovalSnapshot {
        let hostId = HostStore.shared.activeHostID
        let approvals = TurnActivity.shared.approvals.filter { hostId == nil || $0.hostId == hostId }
        let runs = TurnActivity.shared.runs.filter { hostId == nil || $0.hostId == hostId }
        return ClutchApprovalSnapshot(waitingCount: approvals.count, runningCount: runs.count)
    }

    /// The state the Live Activity shows.
    ///
    /// The titles are the thread names, and nothing else about the request
    /// is read:  the tool name and the evidence stay behind the tap.
    private func currentState() -> ClutchActivityAttributes.ContentState {
        let hostId = HostStore.shared.activeHostID
        let waiting = TurnActivity.shared.approvals
            .filter { hostId == nil || $0.hostId == hostId }
            .map { ClutchActivitySession(id: $0.sessionId, title: $0.title, status: .waiting) }
        let running = TurnActivity.shared.runs
            .filter { hostId == nil || $0.hostId == hostId }
            .map { ClutchActivitySession(id: $0.sessionId, title: $0.title, status: .running) }
        return ClutchActivityAttributes.ContentState(waiting: waiting, running: running)
    }

    /// Writes the count for the Lock Screen accessory and asks it to redraw.
    private func write(_ snapshot: ClutchApprovalSnapshot) {
        let previous = ClutchSharedStore.read()
        ClutchSharedStore.write(snapshot)
        guard previous != snapshot else { return }
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
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        if let activity {
            Task { await activity.update(content) }
        } else {
            Task {
                do {
                    activity = try Activity.request(attributes: ClutchActivityAttributes(),
                                                    content: content,
                                                    pushType: nil)
                } catch {
                    // A live activity that cannot start is a missing
                    // convenience, not a failure worth interrupting the
                    // owner over:  the notification and the list still say
                    // what is waiting.
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
#endif
