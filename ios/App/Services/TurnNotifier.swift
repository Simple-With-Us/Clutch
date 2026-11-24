import Foundation
import UserNotifications

/// Local notification when a coding turn finishes, so a long MiniMax Code
/// turn started from the phone or Mac can be left running in the background.
/// Authorization is requested lazily on the first completion; a denial just
/// means silence, never an error in the chat surface.
public enum TurnNotifier {
    /// The category a permission notification carries its actions in.
    public static let permissionCategory = "clutch.permission"
    /// The action that refuses the request from the lock screen.
    public static let denyAction = "clutch.permission.deny"

    public static func turnFinished(threadTitle: String, failed: Bool = false) {
        deliver(content: plainContent(title: failed ? "Turn Failed" : "Turn Finished",
                                      body: threadTitle.isEmpty ? "MiniMax Code" : threadTitle))
    }

    /// The engine is blocked on a permission request until it is answered, so
    /// the request is worth waking the owner for the moment it arrives — the
    /// turn-end notification alone would never fire for a stalled approval.
    ///
    /// The request text can carry tool commands and paths, so it stays behind
    /// the tap:  the lock screen gets the thread's name only.  The
    /// notification carries no tool name, no command, no path and no diff,
    /// and neither does its payload.
    ///
    /// It offers two things:  Deny, which refuses the request without the
    /// owner unlocking the phone, and the tap, which opens the app to the
    /// card.  It does not offer Allow, because an allow nobody can read is
    /// an allow nobody informed.
    public static func permissionRequest(threadTitle: String, payload: PermissionNotificationPayload? = nil) {
        deliver(content: permissionContent(threadTitle: threadTitle, payload: payload))
    }

    /// The notification a permission request produces.
    ///
    /// The content is built here rather than inside the post so the tests
    /// can read what the owner would see on the lock screen.
    static func permissionContent(
        threadTitle: String,
        payload: PermissionNotificationPayload?
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Approval Needed"
        content.body = threadTitle.isEmpty ? "The engine needs an approval." : threadTitle
        content.sound = .default
        guard let payload else { return content }
        content.categoryIdentifier = permissionCategory
        content.interruptionLevel = .timeSensitive
        content.userInfo = payload.userInfo
        return content
    }

    /// The content a turn-end notification carries.
    private static func plainContent(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return content
    }

    /// The actions a permission notification carries.
    ///
    /// The category holds one action:  Deny.  There is no Allow action,
    /// because the lock screen cannot show the command, the path or the diff
    /// that an informed allow needs.
    static func registerPermissionCategory(center: UNUserNotificationCenter) {
        center.setNotificationCategories([permissionCategoryDefinition()])
    }

    /// The category a permission notification carries.
    ///
    /// It holds one action:  Deny.  There is no Allow action, because the
    /// lock screen cannot show the command, the path or the diff that an
    /// informed allow needs.
    static func permissionCategoryDefinition() -> UNNotificationCategory {
        let deny = UNNotificationAction(identifier: denyAction, title: "Deny", options: [.destructive])
        return UNNotificationCategory(
            identifier: permissionCategory,
            actions: [deny],
            intentIdentifiers: [],
            options: []
        )
    }

    private static func deliver(content: UNMutableNotificationContent) {
        let center = UNUserNotificationCenter.current()
        if content.categoryIdentifier == permissionCategory {
            // The category has to exist before the notification arrives, or
            // the actions are dropped and the owner sees a plain banner.
            registerPermissionCategory(center: center)
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post(center: center, content: content) }
                }
            case .authorized, .provisional:
                post(center: center, content: content)
            default:
                break
            }
        }
    }

    private static func post(center: UNUserNotificationCenter, content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
