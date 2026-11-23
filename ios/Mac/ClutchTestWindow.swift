import AppKit
import SwiftUI

/// Puts the workspace window into the shape a UI test expects.
///
/// The window size and the thread rail width are both restored from the last
/// run on the machine, so they differ from machine to machine and a
/// screenshot taken on one is not a screenshot of the same surface on
/// another.  A test run asks for a window size with `-ClutchWindowSize`,
/// and the app then puts the window at that size and drops the saved rail
/// width, so the surface under test is the same everywhere.
///
/// This is a debug-only hook.  It does nothing in a shipped build.
struct ClutchTestWindowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let size = DebugLaunch.windowSize else { return }
                if DebugLaunch.resetsLayout {
                    MacSidebarWidth.reset()
                }
                // AppKit restores the saved frame while the window is being
                // made, so the size is applied again a moment later to win.
                apply(size: size)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    apply(size: size)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    apply(size: size)
                }
            }
    }

    private func apply(size: CGSize) {
        for window in NSApp.windows where window.contentView != nil {
            window.setContentSize(NSSize(width: size.width, height: size.height))
            // The window can open on a space the machine was not showing, and
            // a window on another space is not in the accessibility tree, so
            // a test would see no window at all.  Ordering it front brings
            // it onto the space the test is looking at.
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

extension View {
    /// Applies the test window shape when the run asked for one.
    func clutchTestWindow() -> some View {
        modifier(ClutchTestWindowModifier())
    }
}
