import Foundation
import Observation

/// A link that names a thread, so the app can open that exact thread.
///
/// The shape is `clutch://thread/<session id>?host=<host id>`.  The host is
/// optional because a thread id only means something on the host that owns
/// it, and the app already knows which host it is looking at most of the
/// time.  The pairing link owns the `pair` host of the same scheme, so the
/// two never collide.
public struct ThreadLink: Equatable, Sendable {
    /// The thread's session id.
    public var sessionId: String
    /// The host that owns the thread, when the link names one.
    public var hostId: UUID?

    public init(sessionId: String, hostId: UUID? = nil) {
        self.sessionId = sessionId
        self.hostId = hostId
    }

    /// The link that opens this thread.
    public static func url(sessionId: String, hostId: UUID?) -> URL? {
        var comps = URLComponents()
        comps.scheme = "clutch"
        comps.host = "thread"
        comps.path = "/\(sessionId)"
        if let hostId {
            comps.queryItems = [URLQueryItem(name: "host", value: hostId.uuidString)]
        }
        return comps.url
    }

    /// The thread a link names, when it names one.
    ///
    /// A pairing link is not a thread link, and neither is a link to
    /// anything else the app understands:  a link the app cannot read is
    /// left alone rather than guessed at.
    public static func parse(_ url: URL) -> ThreadLink? {
        guard url.scheme?.lowercased() == "clutch",
              url.host?.lowercased() == "thread" else { return nil }
        let sessionId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !sessionId.isEmpty else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let hostId = items.first(where: { $0.name == "host" })?.value.flatMap(UUID.init(uuidString:))
        return ThreadLink(sessionId: sessionId, hostId: hostId)
    }
}

/// The thread the app has been asked to open.
///
/// A link can arrive while the app is running or while it is starting, and
/// the surface that can open a thread may not exist yet, so the request is
/// held here until a surface is ready to take it.
@MainActor
@Observable
public final class ThreadLinkRouter {
    public static let shared = ThreadLinkRouter()

    /// The thread waiting to be opened.
    public var pending: ThreadLink?

    public init() {}

    /// Asks for a thread to be opened.
    public func request(_ link: ThreadLink) {
        pending = link
    }

    /// The waiting thread, and the waiting is over.
    ///
    /// The link is taken rather than read, so the same thread is not opened
    /// twice by two surfaces that both happen to be on screen.
    public func take() -> ThreadLink? {
        let link = pending
        pending = nil
        return link
    }
}
