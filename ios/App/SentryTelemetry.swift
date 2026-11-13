import Foundation
import Sentry

/// Native Sentry telemetry and crash reporting for Clutch iOS.
///
/// DSN is read only from Info.plist (`SENTRY_DSN`).  There is no hardcoded
/// fallback — missing or empty skips init so a leaked default cannot be
/// pointed at the wrong project.
enum SentryTelemetry {
    static func start() {
        guard let dsn = plistString("SENTRY_DSN"), !dsn.isEmpty else { return }

        let releaseName = plistString("CFBundleShortVersionString")
        let dist = plistString("CFBundleVersion")

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = "production"
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
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.sendDefaultPii = false
            options.sessionReplay.sessionSampleRate = 0.01
            options.sessionReplay.onErrorSampleRate = 1.0
            options.sessionReplay.maskAllText = true
            options.sessionReplay.maskAllImages = true
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
