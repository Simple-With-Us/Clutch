import Foundation
#if os(iOS)
import MetricKit
#endif
#if canImport(Sentry)
import Sentry
#endif

/// Forwards the field diagnostics Apple already collects to the Sentry
/// project the apps already report to.
///
/// MetricKit payloads (hangs, CPU and disk-write exceptions, app
/// exceptions) used to be discarded by never subscribing, so field hangs
/// were invisible unless they crashed.  Only the counts travel: one info
/// event per diagnostic payload with how many of each kind it carried,
/// never a stack, a path, or any payload content.  That fits the privacy
/// manifest's performance-data declaration as written.  Metric payloads
/// (launch and run-time aggregates) are not forwarded yet: there is no
/// stats backend decision behind them, and counts without a reader are
/// noise, so they wait for the product-metrics pass.
#if os(iOS)
final class MetricKitForwarder: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitForwarder()

    /// Subscribes for the payloads the system delivers about a day late.
    /// Safe to call when Sentry never started (no DSN): forwarding checks.
    func start() {
        MXMetricManager.shared.add(self)
    }

    /// The one-line counts summary an event carries, or nil when the
    /// payload held nothing worth reporting.
    static func summary(hangs: Int, crashes: Int, diskWrites: Int, cpu: Int) -> String? {
        guard hangs + crashes + diskWrites + cpu > 0 else { return nil }
        return "[metrickit-diagnostics] hangs=\(hangs) crashes=\(crashes) diskWrites=\(diskWrites) cpu=\(cpu)"
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            guard let line = Self.summary(
                hangs: payload.hangDiagnostics?.count ?? 0,
                crashes: payload.crashDiagnostics?.count ?? 0,
                diskWrites: payload.diskWriteExceptionDiagnostics?.count ?? 0,
                cpu: payload.cpuExceptionDiagnostics?.count ?? 0
            ) else { continue }
            #if canImport(Sentry)
            guard SentrySDK.isEnabled else { continue }
            SentrySDK.capture(message: line) { scope in
                scope.setLevel(.info)
            }
            #endif
        }
    }

    /// Metric payloads are deliberately not forwarded yet; subscribing
    /// still requires the slot to exist.
    func didReceive(_ payloads: [MXMetricPayload]) {}
}
#endif
