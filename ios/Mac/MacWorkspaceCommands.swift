import Foundation
import Observation

/// The commands the Mac menu bar offers.
///
/// A menu item cannot reach the state of a view it does not own, so the
/// window in front registers what its commands do here and the menu bar
/// calls that.  The commands work whether the thread rail is showing or
/// hidden, which is the whole reason they are in the menu bar and not on
/// a rail that can be closed.
@MainActor
@Observable
final class MacWorkspaceCommands {
    /// Starts a new thread.
    var newThread: (() -> Void)?
    /// Refreshes the open thread.
    var refresh: (() -> Void)?
    /// Opens the open thread in a window of its own.
    var newWindow: (() -> Void)?
    /// The name of the open thread, for the window title.
    var threadName: String = ""
}
