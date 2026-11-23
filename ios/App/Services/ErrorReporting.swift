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
/// Privacy: URLs and absolute paths are redacted from every message at
/// this boundary — Muse copy arrives safe, but other engines forward raw
/// provider text that can embed URLs or paths.  Prompt, transcript, and
/// token text never travel: only the failure line the owner already reads.
/// Transport error descriptions can embed URLs, so only the error's type
/// name travels for those.
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

    /// Strip URLs and absolute paths from a message.  Safe copy passes
    /// through untouched; raw provider text loses its exfiltratable parts.
    public static func redacted(_ message: String) -> String {
        var out = message.replacingOccurrences(
            of: "https?://\\S+",
            with: "[url]",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(^|[\\s(])(~?/(?:[^/\\s]+/)*[^/\\s]*)",
            with: "$1[path]",
            options: .regularExpression
        )
        return out
    }

    /// The report line for a transport failure: the error's type only.
    public static func transportMessage(engine: String, error: Error) -> String {
        "[turn-transport-failed engine=\(engine)] \(String(describing: type(of: error)))"
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
