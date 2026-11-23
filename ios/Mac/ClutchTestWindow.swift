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

/// Brings the app forward when a UI test asked for it.
///
/// A UI test launches the app by running its binary, and an app started that
/// way never receives the activation event a launch through the Dock gives
/// it.  Its windows are created, but they are never ordered in front, so
/// they sit off screen and the accessibility tree cannot see them at all.
/// The runner then looks at an app that plainly has a window and finds
/// nothing.
///
/// So the app orders its own windows in once it has finished launching,
/// which is the only point where that works:  activating before the launch
/// finishes leaves the app with no window at all.  The windows are ordered
/// in more than once, because the first ones appear a moment after the
/// launch finishes and a window that is never ordered in stays where it
/// was.
///
/// This is a debug-only hook.  It does nothing unless the run asked for a
/// window size, so a shipped build never takes this path.
final class ClutchTestActivationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard DebugLaunch.windowSize != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI opens the window of its scene when the app is activated,
        // and an app that was started by running its binary never receives
        // that event.  Asking LaunchServices to open the app is what
        // delivers it:  LaunchServices finds the running instance and
        // activates it, and the window comes up.
        Self.activateThroughLaunchServices()
        for delay in [0.2, 0.5, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.orderWindowsIn()
            }
        }
    }

    /// Asks LaunchServices to activate this app.
    static func activateThroughLaunchServices() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in }
    }

    /// Orders every real window in front, on the space the runner is showing.
    static func orderWindowsIn() {
        for window in NSApp.windows where window.contentView != nil {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
