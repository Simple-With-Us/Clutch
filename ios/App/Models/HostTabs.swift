import Foundation

/// The tabs the native apps show, and the ones a host can take away.
///
/// The phone shows Workspace, Chat, Host and Fleet Recall; the Mac shows
/// Workspace, Agent Chat, Host and Fleet Recall.  A code-server host has no
/// dsh host behind it, so the Host console goes away on both.  The Mac also
/// loses its Agent Chat, because that surface talks to the dsh host; the
/// phone keeps its Chat tab, which is the surface a code server is for.
enum HostTabs {
    /// Which app the tabs belong to.
    enum Platform {
        case phone
        case mac

        /// The app this build is.
        static var current: Platform {
            #if os(macOS)
            return .mac
            #else
            return .phone
            #endif
        }
    }

    /// The tag of the workspace tab, and where a host that cannot keep its
    /// tab puts the owner.
    static let workspace = 0

    /// The tags a host cannot sit on.
    ///
    /// Empty for a host that keeps every tab.
    static func hidden(for host: ClutchHost, platform: Platform = .current) -> Set<Int> {
        guard host.isMiniMaxCodeOnly else { return [] }
        switch platform {
        case .mac: return [1, 2]
        case .phone: return [2]
        }
    }

    /// Keeps a selection on a tab that exists.
    ///
    /// The tab set changes when the owner picks another host, and when a host
    /// changes kind: a re-pair on the same origin turns a web host into a
    /// code server without changing its id, so the id alone does not catch
    /// it.  A selection left on a tab that is gone shows the owner nothing
    /// at all.
    static func clamp(_ tab: Int, for host: ClutchHost, platform: Platform = .current) -> Int {
        hidden(for: host, platform: platform).contains(tab) ? workspace : tab
    }
}
