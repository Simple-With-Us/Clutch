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
            // A window that is bigger than the screen is clipped by the
            // screen, and a control that sits in the clipped part cannot be
            // clicked at all.  A runner's screen can be smaller than the
            // size a test asks for, so the size is clamped to what the
            // screen can show and the surface under test is the whole
            // window rather than the part of it that fits.
            let size = Self.clampToScreen(size, for: window)
            window.setContentSize(NSSize(width: size.width, height: size.height))
            // A window that hangs over the edge of the screen shows only the
            // part of itself that is on screen, and the controls in the part
            // that hangs over are not in the accessibility tree at all:  the
            // run then finds a surface that is plainly there with its
            // controls missing.  So the window is moved back inside the
            // screen it is on after it has been sized.
            Self.keepInsideScreen(window)
            // The window can open on a space the machine was not showing, and
            // a window on another space is not in the accessibility tree, so
            // a test would see no window at all.  Ordering it front brings
            // it onto the space the test is looking at.
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

extension ClutchTestWindowModifier {
    /// The size the screen can show, for a size that is bigger than it.
    ///
    /// The screen is the one the window is on, and the first one the machine
    /// has when the window does not know yet.  The main screen is not used:
    /// it is the screen of the app that holds the keyboard, and an app that
    /// has no key window yet has no main screen, so asking for it would
    /// leave the size unclamped exactly when the size is applied.
    static func clampToScreen(_ size: CGSize, for window: NSWindow) -> CGSize {
        let screen = window.screen ?? NSScreen.screens.first
        guard let screen else { return size }
        let frame = screen.visibleFrame
        // The title bar is part of the window's frame and not of its
        // content, so the content is made short enough for the whole window
        // to fit on the screen and not only its content area.
        //
        // The window has to fit.  A window taller than the screen is
        // clipped, and the controls in the clipped part are not in the
        // accessibility tree at all, so a floor that asked for more room
        // than the screen has would hide the very controls a test is
        // looking for.
        let chrome = max(0, window.frame.height - (window.contentView?.bounds.height ?? 0))
        let usable = max(0, frame.height - chrome)
        return CGSize(
            width: min(size.width, frame.width),
            height: min(size.height, usable)
        )
    }

    /// Moves a window back inside the screen it is on.
    ///
    /// The size is clamped to what the screen can show, but a window also
    /// has a place on that screen:  a window that hangs over the edge keeps
    /// only the part of itself that is on screen, and the controls in the
    /// part that hangs over are not in the accessibility tree at all.  A
    /// runner's screen is small, and a restored frame is put back where the
    /// last run left it, so the window has to be moved as well as sized.
    static func keepInsideScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        guard frame.size.width <= visible.width, frame.size.height <= visible.height else { return }
        let origin = NSPoint(
            x: min(max(frame.origin.x, visible.minX), visible.maxX - frame.size.width),
            y: min(max(frame.origin.y, visible.minY), visible.maxY - frame.size.height)
        )
        if origin != frame.origin {
            window.setFrameOrigin(origin)
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
    /// How long the app keeps bringing itself forward, in half-second ticks.
    ///
    /// The window is a UI test's whole subject, and a UI test spends its
    /// first minute looking at it:  a run that opens a thread, previews it
    /// and then resumes it is still tapping buttons long after a window
    /// that only came forward for twenty seconds has fallen behind
    /// whatever the session put in front of it.  A control in a background
    /// app is not clickable at all, so the run would fail on the machine
    /// rather than on the surface.
    private static let forwardTicks = 240
    /// How often, in ticks, the app asks for the foreground again.
    ///
    /// Ordering the windows in is not the same as being the frontmost app:
    /// a panel that took the foreground (a menu, an alert, another window)
    /// leaves the app behind it, and the app has to ask its way back.
    private static let activateEveryTicks = 20
    private var forwardTimer: Timer?
    private var forwardTicks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard DebugLaunch.windowSize != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI opens the window of its scene when the app is activated,
        // and an app that was started by running its binary never receives
        // that event.  Asking the running app to activate itself is what
        // delivers it.
        //
        // It has to be this app and not a second copy of it:  asking
        // LaunchServices to open the bundle would find no registered running
        // instance, because the app was started by running its binary rather
        // than through LaunchServices, and would launch a second copy.  The
        // second copy takes the foreground, the first one is left with a
        // window the automation session cannot see, and the run reports a
        // machine that cannot host the test instead of the surface.
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        // Activating ourselves is not always enough:  an app started by
        // running its binary is not a frontmost application, and macOS lets
        // only a frontmost application take the foreground.  Asking
        // LaunchServices to open the bundle is the system-mediated way in,
        // and LaunchServices activates the running instance of the bundle
        // rather than launching a second copy of it.
        Self.activateThroughLaunchServices()

        // The window is created a moment after the app is activated, and a
        // window created while the app is still in the background lands on a
        // space the runner is not showing.  A window on another space is not
        // in the accessibility tree at all, so the runner sees an app with no
        // window even though it has one.
        //
        // So the app keeps bringing itself forward for a while after it
        // launches:  every window that appears is moved to the space the
        // runner is showing and ordered in front of it.  A one-shot ordering
        // loses the race with the window being created.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.forwardTicks += 1
            Self.orderWindowsIn()
            if self.forwardTicks % Self.activateEveryTicks == 0 {
                // The app asks for the foreground again every few seconds:
                // a menu, an alert or another window can take it, and a
                // background app's controls cannot be clicked at all.
                //
                // It only asks when it does not have the foreground.  An
                // app that takes the foreground it already holds takes it
                // away from whatever else the session is doing, and the
                // hosted runner is a session that belongs to somebody
                // else.
                if NSRunningApplication.current.isActive == false {
                    NSRunningApplication.current.activate(
                        options: [.activateAllWindows, .activateIgnoringOtherApps]
                    )
                }
            }
            if self.forwardTicks >= Self.forwardTicks {
                self.forwardTimer?.invalidate()
                self.forwardTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        forwardTimer = timer
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
