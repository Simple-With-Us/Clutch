import Foundation
import Network
import Combine

public struct DiscoveredHost: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let serviceType: String
    public let advertisedHost: String?
    public let advertisedPort: Int?
    public let txtMetadata: [String: String]

    public var isMiniMax: Bool {
        serviceType.contains("minimax") || serviceType.contains("MiniMax")
    }

    public var isHarness: Bool {
        serviceType.contains("harness") || serviceType.contains("Harness")
    }

    public var defaultPort: Int {
        if let p = advertisedPort { return p }
        return isMiniMax ? 7842 : 3080
    }

    public var effectiveHost: String {
        advertisedHost ?? "127.0.0.1"
    }
}

@MainActor
public final class BonjourDiscovery: ObservableObject {
    public static let shared = BonjourDiscovery()

    @Published public private(set) var discoveredHosts: [DiscoveredHost] = []
    @Published public private(set) var isBrowsing: Bool = false
    @Published public private(set) var discoveryError: String?

    private var browsers: [NWBrowser] = []
    private let serviceTypes = ["_harness._tcp", "_minimax._tcp"]

    private init() {}

    public func startDiscovery() {
        guard !isBrowsing else { return }
        stopDiscovery()
        isBrowsing = true
        discoveryError = nil
        discoveredHosts = []

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        for sType in serviceTypes {
            let browser = NWBrowser(for: .bonjour(type: sType, domain: nil), using: parameters)

            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .failed(let error):
                        self?.discoveryError = "Discovery failed: \(error.localizedDescription)"
                    case .ready:
                        self?.discoveryError = nil
                    default:
                        break
                    }
                }
            }

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor [weak self] in
                    self?.processResults(results, serviceType: sType)
                }
            }

            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    public func stopDiscovery() {
        for b in browsers {
            b.cancel()
        }
        browsers.removeAll()
        isBrowsing = false
    }

    private func processResults(_ results: Set<NWBrowser.Result>, serviceType: String) {
        var parsed: [DiscoveredHost] = []

        for res in results {
            guard case let .service(name, type, _, _) = res.endpoint else { continue }
            var metadata: [String: String] = [:]
            var host: String?
            var port: Int?

            if case let .bonjour(txt) = res.metadata {
                for (k, v) in txt.dictionary {
                    metadata[k] = v
                }
                host = txt["host"]
                if let pStr = txt["port"], let pInt = Int(pStr) {
                    port = pInt
                }
            }

            let item = DiscoveredHost(
                id: "\(type):\(name)",
                name: name,
                serviceType: type,
                advertisedHost: host,
                advertisedPort: port,
                txtMetadata: metadata
            )
            parsed.append(item)
        }

        // Merge with existing hosts from other service types
        var current = discoveredHosts.filter { $0.serviceType != serviceType }
        current.append(contentsOf: parsed)
        self.discoveredHosts = current.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
