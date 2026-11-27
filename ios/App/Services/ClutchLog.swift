import Foundation
import os

/// Structured local logging for support sessions.
///
/// The apps had crash telemetry but no Console trail at all, so a support
/// session started from nothing.  These categories carry states and
/// outcomes only — never a prompt, a title, a path, or a token — which is
/// the same no-content rule the Sentry boundary already keeps, so a log
/// capture the owner shares carries nothing they did not say out loud.
enum ClutchLog {
    private static var subsystem: String {
        Bundle.main.bundleIdentifier ?? "codes.clutch"
    }

    /// Host reachability and pairing outcomes.
    static var host: Logger { Logger(subsystem: subsystem, category: "host") }
    /// Mux connection lifecycle: connect, drop, reconnect.
    static var stream: Logger { Logger(subsystem: subsystem, category: "stream") }
    /// Permission answer delivery.
    static var permissions: Logger { Logger(subsystem: subsystem, category: "permissions") }
}
