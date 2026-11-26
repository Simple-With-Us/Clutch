import Foundation
import Observation

/// The approvals list the app has been asked to open.
///
/// A link can arrive while the app is running or while it is starting, and
/// the surface that shows the list may not exist yet, so the request is
/// held here until a surface is ready to take it.
@MainActor
@Observable
public final class ApprovalsLinkRouter {
    public static let shared = ApprovalsLinkRouter()

    /// Whether an approvals list is waiting to be shown.
    public var pending = false

    public init() {}

    /// Asks for the approvals list to be opened.
    public func request() {
        pending = true
    }

    /// The waiting request, and the waiting is over.
    ///
    /// The request is taken rather than read, so the list is not opened
    /// twice by two surfaces that both happen to be on screen.
    public func take() -> Bool {
        let wasPending = pending
        pending = false
        return wasPending
    }
}
