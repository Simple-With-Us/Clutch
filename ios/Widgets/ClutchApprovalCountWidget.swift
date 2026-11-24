import SwiftUI
import WidgetKit

/// One reading of the shared count.
struct ClutchApprovalCountEntry: TimelineEntry {
    let date: Date
    let snapshot: ClutchApprovalSnapshot
}

/// Reads the count the app wrote.
///
/// The timeline is a backstop, not the mechanism:  the app asks the system
/// to reload the timelines whenever the count moves, and the fifteen-minute
/// refresh is what keeps the count honest when the app has not run.
struct ClutchApprovalCountProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClutchApprovalCountEntry {
        ClutchApprovalCountEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClutchApprovalCountEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClutchApprovalCountEntry>) -> Void) {
        let entry = current()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }

    private func current() -> ClutchApprovalCountEntry {
        ClutchApprovalCountEntry(date: Date(), snapshot: ClutchSharedStore.read())
    }
}

/// The Lock Screen accessory:  a count of what is waiting.
///
/// It carries the number and nothing else.  The thread names stay in the
/// app, and the tool that wants the approval is not named here either:  a
/// lock screen is read by whoever walks past.
struct ClutchApprovalCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ClutchShared.approvalCountWidgetKind,
                            provider: ClutchApprovalCountProvider()) { entry in
            ClutchApprovalCountView(entry: entry)
        }
        .configurationDisplayName("Clutch Approvals")
        .description("How many approvals are waiting for you.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// The count, drawn for whichever accessory family is on screen.
struct ClutchApprovalCountView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ClutchApprovalCountEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("\(entry.snapshot.waitingCount) Waiting")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Clutch")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(entry.snapshot.waitingCount) Waiting")
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                if entry.snapshot.runningCount > 0 {
                    Text("\(entry.snapshot.runningCount) Running")
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                Text("\(entry.snapshot.waitingCount)")
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
            }
        }
    }
}
