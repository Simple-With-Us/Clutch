import Foundation
import Sentry

/// Native Sentry telemetry and crash reporting for Clutch iOS.
///
/// DSN is read only from Info.plist (`SENTRY_DSN`).  There is no hardcoded
/// fallback — missing or empty skips init so a leaked default cannot be
/// pointed at the wrong project.
enum SentryTelemetry {
    /// Which stream of builds an event came from.
    ///
    /// Debug and TestFlight noise does not belong in the production issue
    /// stream: a crash only a developer build can hit would otherwise page
    /// like a shipped one.  TestFlight installs carry a sandbox receipt,
    /// which is the mark that separates them from App Store installs.
    static func environmentName(isDebug: Bool, receiptLastPathComponent: String?) -> String {
        if isDebug { return "development" }
        return receiptLastPathComponent == "sandboxReceipt" ? "testflight" : "production"
    }

    static func start() {
        guard let dsn = plistString("SENTRY_DSN"), !dsn.isEmpty else { return }

        let releaseName = plistString("CFBundleShortVersionString")
        let dist = plistString("CFBundleVersion")

        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environmentName(
                isDebug: isDebugBuild,
                receiptLastPathComponent: Bundle.main.appStoreReceiptURL?.lastPathComponent
            )
            // The same redaction boundary the failure lines pass, applied
            // to everything else as defense in depth: a crash title or a
            // breadcrumb can carry provider text no reporter scrubbed.
            options.beforeSend = { event in
                if let message = event.message {
                    // `formatted` is read-only, so the scrubbed line rides a
                    // fresh message with the raw form scrubbed to match.
                    let scrubbed = SentryMessage(formatted: ErrorReporting.redacted(message.formatted))
                    scrubbed.message = message.message.map(ErrorReporting.redacted)
                    scrubbed.params = message.params?.map(ErrorReporting.redacted)
                    event.message = scrubbed
                }
                event.breadcrumbs?.forEach { breadcrumb in
                    if let text = breadcrumb.message {
                        breadcrumb.message = ErrorReporting.redacted(text)
                    }
                }
                return event
            }
            if let releaseName, !releaseName.isEmpty {
                options.releaseName = releaseName
            }
            if let dist, !dist.isEmpty {
                options.dist = dist
            }
            options.tracesSampleRate = 0.2
            // Sentry 9 samples profiling sessions, not individual transactions.
            // Trace lifecycle keeps profiling tied to sampled root spans.
            options.configureProfiling = { profiling in
                profiling.lifecycle = .trace
                profiling.sessionSampleRate = 0.1
            }
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2.0
            options.enableCaptureFailedRequests = true
            options.failedRequestStatusCodes = [HttpStatusCodeRange(min: 500, max: 599)]
            options.sendDefaultPii = false
            // Screenshot, view-hierarchy, and replay attachment exist only
            // on iOS in sentry-cocoa; the macOS target shares this file.
            #if os(iOS)
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.sessionReplay.sessionSampleRate = 0.01
            options.sessionReplay.onErrorSampleRate = 1.0
            options.sessionReplay.maskAllText = true
            options.sessionReplay.maskAllImages = true
            #endif
        }

        // One stable dimension worth slicing by: which native app sent the
        // event.  Engine and host names stay out — the failure lines
        // already name the engine, and a host name is the owner's to keep.
        SentrySDK.configureScope { scope in
            #if os(iOS)
            scope.setTag(value: "ios", key: "clutch.platform")
            #else
            scope.setTag(value: "macos", key: "clutch.platform")
            #endif
        }
    }

    /// Info.plist string, treating unsubstituted `$(VAR)` build settings as missing.
    private static func plistString(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("$(") { return nil }
        return trimmed
    }
}
