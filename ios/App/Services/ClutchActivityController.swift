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
    /// The task that watches the activity's push tokens.
    private var pushTokenTask: Task<Void, Never>?
    /// The session this app run calls itself.
    ///
    /// The host keeps the registration under it, so a later launch can tell
    /// its own registration from one an earlier launch left behind.
    private let sessionId = UUID().uuidString

    /// The keychain account one activity's push token sits under.
    ///
    /// ActivityKit hands out a token per activity, so the entry is keyed by
    /// the activity id and taken away when that activity ends:  a stale
    /// token re-registered under a new activity id would fail every push.
    static func pushTokenAccount(for activityId: String) -> String {
        "activity.pushToken.\(activityId)"
    }

    /// Which APNs the pushes belong to.
    ///
    /// A debug build talks to Apple's sandbox and a shipped build to the
    /// real one, and a token for one is refused by the other.
    static var pushEnvironment: String {
        #if DEBUG
        return "Sandbox"
        #else
        return "Production"
        #endif
    }

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
                watchPushToken(activity)
                // The host keeps a registration until the phone takes it
                // away, so this activity's last token is offered again on
                // every launch.
                if let token = KeychainStore.read(Self.pushTokenAccount(for: activity.id)) {
                    register(token, for: activity.id)
                }
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
            unregister(activityId: activity.id)
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
                    let activity = try self.requestActivity(content: content, pushToken: true)
                    self.activity = activity
                    self.publishedState = state
                    self.watch(activity)
                    self.watchPushToken(activity)
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
                    if state == .ended || state == .dismissed {
                        self.unregister(activityId: activity.id)
                    }
                    return
                default:
                    continue
                }
            }
        }
    }

    /// Starts the activity, with a push token when the build can have one.
    ///
    /// A build without the push capability cannot ask for a token, and the
    /// activity is worth having without one:  it is asked for again without
    /// it, and the island still works.
    private func requestActivity(
        content: ActivityContent<ClutchActivityAttributes.ContentState>,
        pushToken: Bool
    ) throws -> Activity<ClutchActivityAttributes> {
        let type: PushType? = pushToken ? .token : nil
        do {
            return try Activity.request(attributes: ClutchActivityAttributes(),
                                        content: content,
                                        pushType: type)
        } catch {
            guard pushToken else { throw error }
            return try Activity.request(attributes: ClutchActivityAttributes(),
                                        content: content,
                                        pushType: nil)
        }
    }

    /// Watches the push token the system gives this activity.
    ///
    /// The token is what the host pushes to, so it is registered as soon as
    /// it arrives and again on every launch:  the host keeps the
    /// registration until the phone takes it away.
    private func watchPushToken(_ activity: Activity<ClutchActivityAttributes>) {
        pushTokenTask?.cancel()
        pushTokenTask = Task { @MainActor in
            for await tokenData in activity.pushTokenUpdates {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                self.register(token, for: activity.id)
            }
        }
    }

    /// Tells every paired host about this activity's push token.
    ///
    /// The phone can be paired with more than one host, and each host runs
    /// its own sidecar, so each one is told:  the host that has the work is
    /// the host that pushes it.
    private func register(_ token: String, for activityId: String) {
        _ = KeychainStore.write(token, account: Self.pushTokenAccount(for: activityId))
        let deviceUid = CometChatManager.shared.deviceUid()
        for host in HostStore.shared.hosts {
            Task { @MainActor in
                await ClutchActivityPushRegistration.register(
                    host: host,
                    deviceUid: deviceUid,
                    activityId: activityId,
                    pushToken: token,
                    environment: Self.pushEnvironment,
                    sessionId: self.sessionId
                )
            }
        }
    }

    /// Takes the registration away from every paired host.
    ///
    /// The host keeps a registration until the phone says otherwise, and a
    /// registration for an activity that is gone is a push nobody wants.
    /// The stored token goes with it:  an activity that ended has no token
    /// worth re-offering on the next launch.
    private func unregister(activityId: String) {
        KeychainStore.delete(Self.pushTokenAccount(for: activityId))
        let deviceUid = CometChatManager.shared.deviceUid()
        for host in HostStore.shared.hosts {
            Task { @MainActor in
                await ClutchActivityPushRegistration.unregister(
                    host: host,
                    deviceUid: deviceUid,
                    activityId: activityId,
                    sessionId: self.sessionId
                )
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

/// Registers one Live Activity's push token with a paired host.
///
/// The registration is behind the same credential as the rest of the
/// sidecar's API:  the chat token the pairing brought.  A host that is not
/// there is not an error:  the registration is offered again on the next
/// launch.
enum ClutchActivityPushRegistration {
    /// The route the registrations live on.
    static let path = "/clutch/v1/activity-tokens"

    /// Tells a host about the activity's push token.
    static func register(
        host: ClutchHost,
        deviceUid: String,
        activityId: String,
        pushToken: String,
        environment: String,
        sessionId: String
    ) async {
        await send(
            host: host,
            method: "PUT",
            body: [
                "deviceUid": deviceUid,
                "activityId": activityId,
                "pushToken": pushToken,
                "environment": environment,
                "sessionId": sessionId,
                // The Live Activity carries no stored attributes, so there is
                // nothing to send but the empty set of them.
                "attributes": [String: Any](),
            ]
        )
    }

    /// Takes the registration away again.
    static func unregister(
        host: ClutchHost,
        deviceUid: String,
        activityId: String,
        sessionId: String
    ) async {
        await send(
            host: host,
            method: "DELETE",
            body: [
                "deviceUid": deviceUid,
                "activityId": activityId,
                "sessionId": sessionId,
            ]
        )
    }

    /// One request to one host.
    private static func send(host: ClutchHost, method: String, body: [String: Any]) async {
        guard let token = host.chatToken, !token.isEmpty else { return }
        var components = URLComponents()
        components.scheme = host.origin.scheme
        components.host = host.origin.host
        components.port = host.chatPort
        components.path = path
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: request)
    }
}
#endif
