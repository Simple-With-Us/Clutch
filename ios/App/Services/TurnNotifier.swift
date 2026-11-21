import Foundation
import UserNotifications

/// Local notification when a coding turn finishes, so a long MiniMax Code
/// turn started from the phone or Mac can be left running in the background.
/// Authorization is requested lazily on the first completion; a denial just
/// means silence, never an error in the chat surface.
public enum TurnNotifier {
    public static func turnFinished(threadTitle: String, failed: Bool = false) {
        deliver(title: failed ? "Turn Failed" : "Turn Finished", body: threadTitle.isEmpty ? "MiniMax Code" : threadTitle)
    }

    /// The engine is blocked on a permission request until it is answered, so
    /// the request is worth waking the owner for the moment it arrives — the
    /// turn-end notification alone would never fire for a stalled approval.
    public static func permissionRequest(threadTitle: String, request: String) {
        let summary = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = summary.isEmpty
            ? (threadTitle.isEmpty ? "The engine needs an approval." : threadTitle)
            : (threadTitle.isEmpty ? summary : Copy.gap(threadTitle, summary))
        deliver(title: "Approval Needed", body: body)
    }

    private static func deliver(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post(center: center, title: title, body: body) }
                }
            case .authorized, .provisional:
                post(center: center, title: title, body: body)
            default:
                break
            }
        }
    }

    private static func post(center: UNUserNotificationCenter, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
