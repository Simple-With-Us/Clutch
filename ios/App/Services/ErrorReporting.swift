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
/// Privacy: only the sidecar's safe display copy travels (engine name and
/// the failure line the owner already reads — never prompt, transcript,
/// path, or token text).  Transport error descriptions can embed URLs, so
/// only the error's type name travels for those.
public enum ErrorReporting {
    /// A turn the engine refused or failed, with the sidecar's safe copy.
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
        "[turn-failed engine=\(engine)] \(message)"
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
/// grouped apart from crashes in the issue stream.
private struct ReportedFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
