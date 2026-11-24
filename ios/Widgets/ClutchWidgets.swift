import SwiftUI
import WidgetKit

/// The widget extension:  the Live Activity the engine's work shows in, the
/// Lock Screen count, and the Control Center action that brings the owner
/// back to the app.
///
/// The Control Center control needs iOS 18, so it is behind an availability
/// clause:  the extension still installs on an older phone, where it carries
/// the other two and no control.
@main
struct ClutchWidgets: WidgetBundle {
    var body: some Widget {
        ClutchLiveActivityWidget()
        ClutchApprovalCountWidget()
        if #available(iOS 18.0, *) {
            ClutchApprovalsControl()
        }
    }
}
