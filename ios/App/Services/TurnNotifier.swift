import Foundation
import UserNotifications

/// Local notification when a coding turn finishes, so a long MiniMax Code
/// turn started from the phone or Mac can be left running in the background.
/// Authorization is requested lazily on the first completion; a denial just
/// means silence, never an error in the chat surface.
public enum TurnNotifier {
    public static func turnFinished(threadTitle: String, failed: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post(center: center, threadTitle: threadTitle, failed: failed) }
                }
            case .authorized, .provisional:
                post(center: center, threadTitle: threadTitle, failed: failed)
            default:
                break
            }
        }
    }

    private static func post(center: UNUserNotificationCenter, threadTitle: String, failed: Bool) {
        let content = UNMutableNotificationContent()
        content.title = failed ? "Turn Failed" : "Turn Finished"
        content.body = threadTitle.isEmpty ? "MiniMax Code" : threadTitle
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
