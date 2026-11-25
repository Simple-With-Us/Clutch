import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity:  what the engines are doing, on the lock screen and in
/// the island.
///
/// It shows the thread names and a status and nothing else — no tool name,
/// no command, no path, no diff — because it is a surface that shows
/// without being opened.  Tapping it opens the approvals list, which is
/// where the evidence is.
struct ClutchLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClutchActivityAttributes.self) { context in
            ClutchLiveActivityLockScreen(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(ClutchApprovalsLink.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    ClutchActivitySummaryView(state: context.state)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ClutchActivitySessionList(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.waitingCount > 0 ? "hand.raised.fill" : "circle.dotted")
                    .font(ClutchFont.captionStrong)
                    .foregroundStyle(context.state.waitingCount > 0 ? .orange : .white.opacity(0.8))
            } compactTrailing: {
                Text("\(context.state.waitingCount + context.state.runningCount)")
                    .font(ClutchFont.bodyStrong)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.waitingCount > 0 ? "hand.raised.fill" : "circle.dotted")
                    .foregroundStyle(context.state.waitingCount > 0 ? .orange : .white)
            }
            .widgetURL(ClutchApprovalsLink.url)
        }
    }
}

/// The summary line:  how much is waiting and how much is running.
struct ClutchActivitySummaryView: View {
    let state: ClutchActivityAttributes.ContentState

    var body: some View {
        Text(ClutchActivitySummary.text(waiting: state.waitingCount, running: state.runningCount))
            .font(ClutchFont.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The sessions the island names, up to three.
///
/// The status is a word rather than a colour, so the line still reads on a
/// lock screen in grayscale and for an owner who cannot separate the two
/// colours.
struct ClutchActivitySessionList: View {
    let state: ClutchActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(state.sessions) { session in
                HStack(spacing: 6) {
                    Image(systemName: session.status == .waiting ? "hand.raised.fill" : "circle.dotted")
                        .font(ClutchFont.captionStrong)
                        .foregroundStyle(session.status == .waiting ? .orange : .white.opacity(0.7))
                    Text(session.title.isEmpty ? "Untitled Thread" : session.title)
                        .font(ClutchFont.footnote)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(session.status == .waiting ? "Waiting" : "Running")
                        .font(ClutchFont.micro)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}

/// The lock screen's own view of the same state.
struct ClutchLiveActivityLockScreen: View {
    let state: ClutchActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClutchActivitySummaryView(state: state)
            ClutchActivitySessionList(state: state)
        }
        .padding(14)
    }
}
