import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// What a permission notification carries, so the owner can refuse the
/// request from the lock screen and the tap can open the exact card.
///
/// The payload holds identifiers only.  The lock screen shows the thread's
/// name and nothing else, so the tool name, the command, the path and the
/// diff never reach it, and they do not reach this payload either.
public struct PermissionNotificationPayload: Codable, Equatable, Sendable {
    /// The host that owns the thread.
    public var hostId: UUID
    /// The thread the request was raised in.
    public var sessionId: String
    /// The engine the thread runs on, when the notification names one.
    ///
    /// A host serves more than one engine and each numbers its own sessions,
    /// so the tap needs the engine to open the thread the request came from
    /// rather than whichever engine the sidebar happens to be showing.  It is
    /// optional because a notification queued before the field existed still
    /// opens, resolved the way a legacy link is.
    public var engine: String?
    /// The permission request the owner is answering.
    public var requestId: String
    /// The option that refuses the request, when the engine offered one.
    ///
    /// A missing option id cancels the request, which is what a deny amounts
    /// to when the engine offered no reject option of its own.
    public var denyOptionId: String?

    public init(
        hostId: UUID,
        sessionId: String,
        engine: String? = nil,
        requestId: String,
        denyOptionId: String? = nil
    ) {
        self.hostId = hostId
        self.sessionId = sessionId
        self.engine = engine
        self.requestId = requestId
        self.denyOptionId = denyOptionId
    }

    /// The payload for a request, when there is enough to route an answer.
    ///
    /// A request with no session id cannot be answered from a notification,
    /// because the answer has nowhere to go, so the payload is nothing and
    /// the notification is a plain one.
    public static func make(
        hostId: UUID?,
        sessionId: String?,
        engine: String? = nil,
        requestId: String,
        denyOptionId: String?
    ) -> PermissionNotificationPayload? {
        guard let hostId, let sessionId, !sessionId.isEmpty else { return nil }
        return PermissionNotificationPayload(
            hostId: hostId,
            sessionId: sessionId,
            engine: (engine?.isEmpty == false) ? engine : nil,
            requestId: requestId,
            denyOptionId: denyOptionId
        )
    }

    /// The payload as the notification's own dictionary.
    ///
    /// Five identifiers and nothing else:  a notification that carried the
    /// tool's name or its command would put the request on the lock screen.
    public var userInfo: [String: String] {
        [
            "hostId": hostId.uuidString,
            "sessionId": sessionId,
            "engine": engine ?? "",
            "requestId": requestId,
            "denyOptionId": denyOptionId ?? "",
        ]
    }

    /// The payload a notification carried, when it carried one.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let hostRaw = userInfo["hostId"] as? String,
              let hostId = UUID(uuidString: hostRaw),
              let sessionId = userInfo["sessionId"] as? String,
              let requestId = userInfo["requestId"] as? String else { return nil }
        let deny = userInfo["denyOptionId"] as? String
        let namedEngine = userInfo["engine"] as? String
        self.init(
            hostId: hostId,
            sessionId: sessionId,
            engine: (namedEngine?.isEmpty == false) ? namedEngine : nil,
            requestId: requestId,
            denyOptionId: (deny?.isEmpty == false) ? deny : nil
        )
    }
}

/// What the app does when the owner acts on a permission notification.
public enum PermissionNotificationHandler {
    /// Refuses the request without the owner unlocking the phone.
    ///
    /// The refusal goes to the sidecar the same way the card's deny does, so
    /// the engine is unblocked either way.
    public static func deny(_ payload: PermissionNotificationPayload) async {
        let host = await MainActor.run { HostStore.shared.hosts.first { $0.id == payload.hostId } }
        guard let host else { return }
        _ = await ChatSessionClient.answerPermission(
            host: host,
            sessionId: payload.sessionId,
            requestId: payload.requestId,
            optionId: payload.denyOptionId
        )
    }

    /// Opens the thread the request was raised in, on the engine it came
    /// from.
    ///
    /// The engine rides in the link, so a Muse approval opens Muse even while
    /// the sidebar is showing MiniMax Code.  A payload from before the engine
    /// rode in the notification builds the older link, which the app resolves
    /// from what it has seen.
    public static func open(_ payload: PermissionNotificationPayload) async {
        guard let url = ThreadLink.url(
            sessionId: payload.sessionId,
            hostId: payload.hostId,
            engine: payload.engine
        ) else { return }
        await MainActor.run { openURL(url) }
    }

    @MainActor
    private static func openURL(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}

/// What the app does when the owner taps a notification or an action on it.
///
/// The delegate has to be in place before a notification arrives, which can
/// be as early as the launch the notification itself caused, so the app
/// sets it when it starts.
public final class ClutchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = ClutchNotificationDelegate()

    /// The notification still shows while the app is in front.
    ///
    /// The owner has to see that an approval is waiting even when they are
    /// already looking at the app, because the card may be on another tab.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// The owner acted:  denied the request, or tapped through to it.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let payload = PermissionNotificationPayload(userInfo: userInfo) else { return }
        if response.actionIdentifier == TurnNotifier.denyAction {
            await PermissionNotificationHandler.deny(payload)
        } else {
            await PermissionNotificationHandler.open(payload)
        }
    }
}
