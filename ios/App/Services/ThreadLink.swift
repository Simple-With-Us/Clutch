import Foundation
import Observation

/// A link that names a thread, so the app can open that exact thread.
///
/// The shape is
/// `clutch://thread/<session id>?host=<host id>&engine=<engine>`.  The host
/// is optional because a thread id only means something on the host that
/// owns it, and the app already knows which host it is looking at most of the
/// time.  The engine is optional too:  every engine on a host numbers its own
/// sessions, so a link that names one opens that engine, and a link written
/// before the engine rode in it still opens, resolved from what the device
/// has actually seen rather than from a guess.  The pairing link owns the
/// `pair` host of the same scheme, so the two never collide.
public struct ThreadLink: Equatable, Sendable {
    /// The thread's session id.
    public var sessionId: String
    /// The host that owns the thread, when the link names one.
    public var hostId: UUID?
    /// The engine the thread runs on, when the link names one.
    public var engine: String?

    public init(sessionId: String, hostId: UUID? = nil, engine: String? = nil) {
        self.sessionId = sessionId
        self.hostId = hostId
        self.engine = engine
    }

    /// The link that opens this thread.
    public static func url(sessionId: String, hostId: UUID?, engine: String? = nil) -> URL? {
        var comps = URLComponents()
        comps.scheme = "clutch"
        comps.host = "thread"
        comps.path = "/\(sessionId)"
        var items: [URLQueryItem] = []
        if let hostId {
            items.append(URLQueryItem(name: "host", value: hostId.uuidString))
        }
        if let engine, !engine.isEmpty {
            items.append(URLQueryItem(name: "engine", value: engine))
        }
        if !items.isEmpty { comps.queryItems = items }
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
        let namedEngine = items.first(where: { $0.name == "engine" })?.value
        let engine = (namedEngine?.isEmpty == false) ? namedEngine : nil
        return ThreadLink(sessionId: sessionId, hostId: hostId, engine: engine)
    }

    /// The engine a link opens on, when the link and the device settle it.
    ///
    /// A link that names an engine opens on that engine, so an approval Muse
    /// raised opens Muse even while the sidebar is showing MiniMax Code:  the
    /// destination carries its own engine and never borrows the sidebar's.
    /// A named engine the host does not offer is refused rather than passed
    /// on, because a link is untrusted input and the name reaches the session
    /// client.
    /// A link that names none is an older link, and it resolves to the engine
    /// this device has seen activity for only when exactly one engine has
    /// it.  When none or several do there is nothing to resolve without
    /// guessing, so the answer is nothing and the caller keeps the engine its
    /// own surface is showing.
    public static func resolveEngine(
        named: String?,
        activityEngines: [String],
        known: Set<String>? = nil
    ) -> String? {
        if let named, !named.isEmpty {
            // A link is a URL, so its engine is a claim and not a fact.  When
            // the surface knows which engines its host offers, a name outside
            // that list is not an engine this app can run and is refused, so
            // a crafted link cannot point the session client at a route the
            // host never advertised.
            if let known, !known.isEmpty, !known.contains(named) { return nil }
            return named
        }
        return activityEngines.count == 1 ? activityEngines[0] : nil
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
