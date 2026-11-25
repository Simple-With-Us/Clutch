import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center action:  one tap from the Control Center to the
/// approvals waiting for the owner.
///
/// It opens the app at the approvals list, and it does that with a link
/// rather than with a shortcut of its own, so the link the notification and
/// the island use is the same link:  one way into the app, one shape to
/// keep true.
@available(iOS 18.0, *)
struct ClutchApprovalsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ClutchApprovalsControl") {
            ControlWidgetButton(action: OpenURLIntent(ClutchApprovalsLink.url)) {
                Label("Clutch", systemImage: "hammer.fill")
            }
        }
        .displayName("Clutch Approvals")
        .description("Open Clutch to the approvals waiting for you.")
    }
}
