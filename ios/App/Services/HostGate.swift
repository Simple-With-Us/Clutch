import Foundation

/// How the active host stands with this device, as the native apps can see it.
///
/// The web canvas used to answer this by asking the web origin for its auth
/// wall.  The native apps never speak to the web origin, so they ask the
/// sidecar's own health route instead: the same gate the session list passes,
/// so the answer is the one the surfaces will actually meet.
public enum HostGateState: Equatable, Sendable {
    /// The sidecar answered and accepted this device.
    case ready
    /// The sidecar is there, but it does not accept this device's token.
    case needsPairing
    /// The sidecar could not be reached at all.
    case unreachable(String)

    public var isReady: Bool { self == .ready }
}

/// The gate check, kept apart from the view so it can be tested on its own.
public enum HostGate {
    /// Classifies the sidecar's health answer.
    ///
    /// A `401` means the sidecar is running and refused this device's token,
    /// which is a pairing problem and not a reachability problem.  Any other
    /// answer means the sidecar spoke, so the surfaces show their own errors
    /// rather than a gate card over them.
    public static func classify(status: Int) -> HostGateState {
        switch status {
        case 200: return .ready
        case 401, 403: return .needsPairing
        default: return .ready
        }
    }

    /// Asks the sidecar's health route how it stands with this device.
    ///
    /// A device with no token cannot ask, and it cannot be answered either,
    /// so it needs pairing.
    public static func check(host: ClutchHost, timeout: TimeInterval = 10) async -> HostGateState {
        guard let token = host.chatToken, !token.isEmpty else { return .needsPairing }
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        comps.path = "/clutch/v1/health"
        guard let url = comps.url else {
            return .unreachable("This host has no usable chat address.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status != 0 else { return .unreachable("The host did not answer.") }
            return classify(status: status)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
