import XCTest
@testable import Harness

final class PairingLinkTests: XCTestCase {
    private func payload(_ raw: String, file: StaticString = #filePath, line: UInt = #line) throws -> PairingPayload {
        switch PairingLink.parse(raw) {
        case .success(let p): return p
        case .failure(let e):
            XCTFail("expected success for \(raw), got \(e)", file: file, line: line)
            throw e
        }
    }

    private func failure(_ raw: String) -> PairingLinkError? {
        if case .failure(let e) = PairingLink.parse(raw) { return e }
        return nil
    }

    func testHarnessLinkWrappingTailnetLaunchURL() throws {
        let inner = "https://jay-macbook.boa-roygbiv.ts.net:3080/?token=abc123"
        var comps = URLComponents(string: "harness://pair")!
        comps.queryItems = [URLQueryItem(name: "url", value: inner), URLQueryItem(name: "name", value: "Jay's MacBook")]
        let p = try payload(comps.url!.absoluteString)
        XCTAssertEqual(p.origin.absoluteString, "https://jay-macbook.boa-roygbiv.ts.net:3080")
        XCTAssertEqual(p.launchToken, "abc123")
        XCTAssertEqual(p.name, "Jay's MacBook")
    }

    func testPlainLaunchURLFromDshWeb() throws {
        let p = try payload("http://127.0.0.1:3080/?token=t0k")
        XCTAssertEqual(p.origin.absoluteString, "http://127.0.0.1:3080")
        XCTAssertEqual(p.launchToken, "t0k")
        XCTAssertEqual(p.name, "This Mac")
    }

    func testLegacyV02HarnessForm() throws {
        let p = try payload("harness://pair?name=Studio&h=studio.local&p=3080&tls=0&t=xyz&v=1")
        XCTAssertEqual(p.origin.absoluteString, "http://studio.local:3080")
        XCTAssertEqual(p.launchToken, "xyz")
        XCTAssertEqual(p.name, "Studio")
    }

    func testBareAddressDefaultsPortAndScheme() throws {
        XCTAssertEqual(try payload("127.0.0.1").origin.absoluteString, "http://127.0.0.1:3080")
        XCTAssertEqual(try payload("jay-macbook.boa-roygbiv.ts.net").origin.absoluteString, "https://jay-macbook.boa-roygbiv.ts.net:3080")
        XCTAssertEqual(try payload("jay-macbook.boa-roygbiv.ts.net").name, "jay-macbook")
        XCTAssertNil(try payload("127.0.0.1:3080").launchToken)
    }

    func testRetiredMiniMaxCompanionIsRejected() {
        XCTAssertEqual(failure("minimax://pair?h=10.0.0.2&p=7842&t=x"), .retiredCompanion)
        XCTAssertEqual(failure("minimax-remote://pair?h=10.0.0.2"), .retiredCompanion)
        XCTAssertEqual(failure("http://10.0.0.2:7842/"), .retiredCompanion)
        XCTAssertEqual(failure("harness://pair?h=10.0.0.2&p=7842"), .retiredCompanion)
    }

    func testGarbageIsRejected() {
        XCTAssertEqual(failure("   "), .empty)
        XCTAssertEqual(failure("ftp://example.com"), .unsupportedScheme("ftp"))
        XCTAssertEqual(failure("harness://pair?name=x"), .missingHost)
        XCTAssertEqual(failure("not a link"), .invalidURL)
    }
}

final class HarnessHostTests: XCTestCase {
    func testLaunchURLCarriesTokenOnlyWhilePending() {
        var host = HarnessHost(name: "Mac", origin: URL(string: "https://mac.example.ts.net:3080")!, pendingLaunchToken: "abc")
        XCTAssertEqual(host.launchURL.absoluteString, "https://mac.example.ts.net:3080/?token=abc")
        host.pendingLaunchToken = nil
        XCTAssertEqual(host.launchURL.absoluteString, "https://mac.example.ts.net:3080/")
    }

    func testSameOriginComparesSchemeHostAndPort() {
        let host = HarnessHost(name: "Mac", origin: URL(string: "http://127.0.0.1:3080")!)
        XCTAssertTrue(host.isSameOrigin(URL(string: "http://127.0.0.1:3080/api/x")!))
        XCTAssertFalse(host.isSameOrigin(URL(string: "http://127.0.0.1:3081/")!))
        XCTAssertFalse(host.isSameOrigin(URL(string: "https://127.0.0.1:3080/")!))
        XCTAssertFalse(host.isSameOrigin(URL(string: "https://github.com/")!))
        let tls = HarnessHost(name: "TLS", origin: URL(string: "https://example.com")!)
        XCTAssertTrue(tls.isSameOrigin(URL(string: "https://example.com:443/x")!))
    }
}

final class HostProbeTests: XCTestCase {
    func testAuthWallMeansHarnessIsOnline() {
        XCTAssertEqual(HostProbe.classify(statusCode: 401, body: "dsh web authentication required; reopen the URL printed by dsh web.\n"), .online)
    }

    func testOtherResponsesAreNotHarness() {
        XCTAssertEqual(HostProbe.classify(statusCode: 401, body: "Unauthorized"), .notHarness)
        XCTAssertEqual(HostProbe.classify(statusCode: 200, body: "<html>"), .notHarness)
        XCTAssertEqual(HostProbe.classify(statusCode: 0, body: ""), .offline)
    }
}

@MainActor
final class HostStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "HostStoreTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testPairAddsActivatesAndPersists() {
        let defaults = freshDefaults()
        let store = HostStore(defaults: defaults)
        XCTAssertNil(store.activeHost)
        let host = store.pair(PairingPayload(name: "Mac", origin: URL(string: "http://127.0.0.1:3080")!, launchToken: "one"))
        XCTAssertEqual(store.activeHost?.id, host.id)
        XCTAssertEqual(store.loadGeneration, 1)

        let reloaded = HostStore(defaults: defaults)
        XCTAssertEqual(reloaded.hosts.count, 1)
        XCTAssertEqual(reloaded.activeHost?.pendingLaunchToken, "one")
    }

    func testRepairSameOriginRefreshesTokenInsteadOfDuplicating() {
        let store = HostStore(defaults: freshDefaults())
        let first = store.pair(PairingPayload(name: "Mac", origin: URL(string: "http://127.0.0.1:3080")!, launchToken: "one"))
        store.consumeLaunchToken(for: first.id)
        XCTAssertNil(store.activeHost?.pendingLaunchToken)
        store.pair(PairingPayload(name: "Other", origin: URL(string: "http://127.0.0.1:3080")!, launchToken: "two"))
        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertEqual(store.activeHost?.pendingLaunchToken, "two")
        XCTAssertEqual(store.activeHost?.name, "Mac")
        XCTAssertEqual(store.loadGeneration, 2)
    }

    func testRemoveActiveFallsBackToRemainingHost() {
        let store = HostStore(defaults: freshDefaults())
        let a = store.pair(PairingPayload(name: "A", origin: URL(string: "http://127.0.0.1:3080")!, launchToken: nil))
        let b = store.pair(PairingPayload(name: "B", origin: URL(string: "https://b.example.ts.net:3080")!, launchToken: nil))
        XCTAssertEqual(store.activeHost?.id, b.id)
        store.remove(b)
        XCTAssertEqual(store.activeHost?.id, a.id)
    }
}
