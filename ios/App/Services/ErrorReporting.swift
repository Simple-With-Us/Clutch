import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// Reported turn failures: engine and transport failures the owner already
/// sees as send errors.
///
/// Crash, hang, and failed-request capture is automatic; this covers the
/// failures that arrive as stream events or thrown client errors, which no
/// automatic hook sees — an ACP error from the sidecar would otherwise be
/// visible only on the device where it happened.
///
/// Privacy: URLs, credentials, email addresses and absolute paths are
/// redacted from every message at this boundary — Muse copy arrives safe,
/// but other engines forward raw provider text that can embed any of them.
/// Prompt, transcript, and token text never travel: only the failure line
/// the owner already reads.  Transport error descriptions can embed URLs,
/// so only the error's type, domain and code travel for those — enough to
/// tell offline from slow host from TLS failure, never the text itself.
public enum ErrorReporting {
    /// A turn the engine refused or failed, redacted for travel.
    public static func turnFailed(engine: String, message: String) {
        report(turnMessage(engine: engine, message: message))
    }

    /// A turn that failed outside the stream (transport, decode).
    public static func turnTransportFailed(engine: String, error: Error) {
        report(transportMessage(engine: engine, error: error))
    }

    /// A turn that failed outside the stream with no error value, such as
    /// a connection that closed before the completion update arrived.
    public static func turnTransportFailed(engine: String, reason: String) {
        report("[turn-transport-failed engine=\(engine)] \(reason)")
    }

    /// The report line for an engine failure.  Pure, so the shape is pinned
    /// without touching the telemetry backend.
    public static func turnMessage(engine: String, message: String) -> String {
        "[turn-failed engine=\(engine)] \(redacted(message))"
    }

    /// Strip URLs, credentials, email addresses and absolute paths from a
    /// message.  Safe copy passes through untouched; raw provider text
    /// loses its exfiltratable parts.
    public static func redacted(_ message: String) -> String {
        var out = message.replacingOccurrences(
            of: "https?://\\S+",
            with: "[url]",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)bearer\\s+\\S+",
            with: "[token]",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)(token|api[_-]?key|secret|password)=\\S+",
            with: "$1=[redacted]",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
            with: "[email]",
            options: .regularExpression
        )
        // An absolute path needs something after the slash, so a bare
        // " / " between words survives as the prose it is.
        out = out.replacingOccurrences(
            of: "(^|[\\s(])(~?/(?:[^/\\s]+/)*[^/\\s]+)",
            with: "$1[path]",
            options: .regularExpression
        )
        return out
    }

    /// The report line for a transport failure: the error's type, domain
    /// and code, never its description.
    ///
    /// The code is the diagnosis — `NSURLErrorDomain` -1009 is offline,
    /// -1001 is a timeout, -1200 is TLS — while the description is where
    /// URLs and host names hide.
    public static func transportMessage(engine: String, error: Error) -> String {
        let bridged = error as NSError
        return "[turn-transport-failed engine=\(engine)] "
            + "\(String(describing: type(of: error))) \(bridged.domain)/\(bridged.code)"
    }

    private static func report(_ message: String) {
        #if canImport(Sentry)
        SentrySDK.capture(error: ReportedFailure(message: message))
        #else
        // No telemetry backend links this target; the sidecar's own
        // turn-diagnostics log keeps the record.
        #endif
    }
}

/// A reportable failure line.  A dedicated error type keeps turn failures
/// grouped apart from crashes in the issue stream, and `LocalizedError`
/// is what Sentry reads through the NSError bridge — without it every
/// report would carry the same generic description.
private struct ReportedFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
