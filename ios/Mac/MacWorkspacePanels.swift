import SwiftUI
import AppKit

/// A vertically resizable transcript and independently scrolling activity pane
/// for the Mac workspace, with a preferred activity height that persists
/// across launches and temporarily clamps to short windows
struct MacWorkspacePanels<Transcript: View, Activity: View>: View {
    private let transcript: Transcript
    private let activity: Activity
    private let responseText: String

    @State private var preferredActivityHeight = MacWorkspacePanelHeight.current
    @State private var dragStartHeight: CGFloat?
    @State private var draggedActivityHeight: CGFloat?
    @State private var followsResponse = true

    init(
        responseText: String = "",
        @ViewBuilder transcript: () -> Transcript,
        @ViewBuilder activity: () -> Activity
    ) {
        self.transcript = transcript()
        self.activity = activity()
        self.responseText = responseText
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = MacWorkspacePanelLayout(
                totalHeight: geometry.size.height,
                preferredActivityHeight: draggedActivityHeight ?? preferredActivityHeight
            )

            VStack(spacing: 0) {
                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: layout.transcriptHeight)

                resizeDivider(height: layout.activityHeight, totalHeight: geometry.size.height)
                    .frame(height: MacWorkspacePanelLayout.dividerHeight)

                ScrollViewReader { proxy in
                    ScrollView {
                        activity
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: responseText) { _, text in
                        if followsResponse, !text.isEmpty {
                            proxy.scrollTo("current-response-end", anchor: .bottom)
                        }
                    }
                }
                .frame(height: layout.activityHeight)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resizeDivider(height: CGFloat, totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .overlay {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 44, height: 3)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartHeight == nil { dragStartHeight = height }
                        let start = dragStartHeight ?? height
                        draggedActivityHeight = MacWorkspacePanelLayout.clampedActivityHeight(
                            start - value.translation.height,
                            totalHeight: totalHeight
                        )
                    }
                    .onEnded { value in
                        let start = dragStartHeight ?? height
                        let final = MacWorkspacePanelLayout.clampedActivityHeight(
                            start - value.translation.height,
                            totalHeight: totalHeight
                        )
                        preferredActivityHeight = final
                        MacWorkspacePanelHeight.save(final)
                        draggedActivityHeight = nil
                        dragStartHeight = nil
                    }
            )
            .onTapGesture(count: 2, perform: resetSize)
            .contextMenu {
                Toggle("Follow Current Response", isOn: $followsResponse)
                Button("Reset Panel Size", action: resetSize)
            }
            .accessibilityElement()
            .accessibilityLabel("Resize Activity Panel")
            .accessibilityValue("\(Int(height.rounded())) points")
            .accessibilityHint("Adjusts the height of the activity panel")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 24
                let adjustment: CGFloat
                switch direction {
                case .increment: adjustment = step
                case .decrement: adjustment = -step
                @unknown default: adjustment = 0
                }
                let next = MacWorkspacePanelLayout.clampedActivityHeight(
                    height + adjustment,
                    totalHeight: totalHeight
                )
                preferredActivityHeight = next
                MacWorkspacePanelHeight.save(next)
            }
    }

    private func resetSize() {
        preferredActivityHeight = MacWorkspacePanelHeight.defaultHeight
        draggedActivityHeight = nil
        dragStartHeight = nil
        MacWorkspacePanelHeight.save(MacWorkspacePanelHeight.defaultHeight)
    }
}

private struct MacWorkspacePanelLayout {
    static let dividerHeight: CGFloat = 12
    static let minimumTranscriptHeight: CGFloat = 100
    static let minimumActivityHeight: CGFloat = 80

    let transcriptHeight: CGFloat
    let activityHeight: CGFloat

    init(totalHeight: CGFloat, preferredActivityHeight: CGFloat) {
        let contentHeight = max(0, totalHeight - Self.dividerHeight)
        if contentHeight >= Self.minimumTranscriptHeight + Self.minimumActivityHeight {
            activityHeight = min(
                max(preferredActivityHeight, Self.minimumActivityHeight),
                contentHeight - Self.minimumTranscriptHeight
            )
        } else {
            // Under the normal minimum size, leave room for both panes and
            // retain the saved preference for when the window grows again
            activityHeight = min(max(preferredActivityHeight, 0), contentHeight * 0.6)
        }
        transcriptHeight = max(0, contentHeight - activityHeight)
    }

    static func clampedActivityHeight(_ proposed: CGFloat, totalHeight: CGFloat) -> CGFloat {
        let contentHeight = max(0, totalHeight - dividerHeight)
        if contentHeight >= minimumTranscriptHeight + minimumActivityHeight {
            return min(max(proposed, minimumActivityHeight), contentHeight - minimumTranscriptHeight)
        }
        return min(max(proposed, 0), contentHeight * 0.6)
    }
}

private enum MacWorkspacePanelHeight {
    static let key = "codes.clutch.mac-workspace-activity-height"
    static let defaultHeight: CGFloat = 220

    static var current: CGFloat {
        let saved = UserDefaults.standard.double(forKey: key)
        return saved.isFinite && saved > 0 ? saved : defaultHeight
    }

    static func save(_ height: CGFloat) {
        UserDefaults.standard.set(height, forKey: key)
    }
}
