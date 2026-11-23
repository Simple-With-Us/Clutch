import AppKit
import Foundation
import Observation

/// The commands the Mac menu bar offers.
///
/// A menu item cannot reach the state of a view it does not own, so each
/// window registers what its commands do here and the menu bar calls the
/// registration of the window in front.  The commands work whether the
/// thread rail is showing or hidden, which is the whole reason they are in
/// the menu bar and not on a rail that can be closed.
@MainActor
@Observable
final class MacWorkspaceCommands {
    /// What one window's commands do.
    ///
    /// The registration belongs to a window, so two windows open at once
    /// each keep their own commands and the menu bar reaches the one that
    /// is in front.
    final class Registration {
        /// The window the registration belongs to.
        weak var window: NSWindow?
        /// Starts a new thread.
        var newThread: (() -> Void)?
        /// Refreshes the open thread.
        var refresh: (() -> Void)?
        /// Opens the open thread in a window of its own.
        var newWindow: (() -> Void)?
        /// The name of the open thread, for the window title.
        var threadName: String = ""
    }

    private var registrations: [Registration] = []

    /// Registers a window's commands, or replaces the ones it had.
    func register(_ registration: Registration) {
        registrations.removeAll { $0 === registration }
        registrations.append(registration)
    }

    /// Forgets a window's commands, when the window goes away.
    func unregister(_ registration: Registration) {
        registrations.removeAll { $0 === registration }
    }

    /// The window the menu bar acts on.
    ///
    /// The menu bar belongs to the application and not to a window, so the
    /// commands follow the window in front.  The most recent registration
    /// is the fallback for the moment before a window is known.
    private var active: Registration? {
        if let key = NSApp.keyWindow {
            for registration in registrations.reversed() where registration.window === key {
                return registration
            }
        }
        return registrations.last
    }

    /// Starts a new thread in the window in front.
    var newThread: (() -> Void)? { active?.newThread }

    /// Refreshes the thread in the window in front.
    var refresh: (() -> Void)? { active?.refresh }

    /// Opens the thread in the window in front in a window of its own.
    var newWindow: (() -> Void)? { active?.newWindow }

    /// The name of the thread in the window in front.
    var threadName: String { active?.threadName ?? "" }
}
