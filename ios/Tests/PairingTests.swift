import XCTest
@testable import Clutch

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

    func testClutchLinkWrappingTailnetLaunchURL() throws {
        let inner = "https://jay-macbook.boa-roygbiv.ts.net:3180/?token=abc123"
        var comps = URLComponents(string: "clutch://pair")!
        comps.queryItems = [URLQueryItem(name: "url", value: inner), URLQueryItem(name: "name", value: "Jay's MacBook")]
        let p = try payload(comps.url!.absoluteString)
        XCTAssertEqual(p.origin.absoluteString, "https://jay-macbook.boa-roygbiv.ts.net:3180")
        XCTAssertEqual(p.launchToken, "abc123")
        XCTAssertEqual(p.name, "Jay's MacBook")
    }

    func testPlainLaunchURLFromDshWeb() throws {
        let p = try payload("http://127.0.0.1:3180/?token=t0k")
        XCTAssertEqual(p.origin.absoluteString, "http://127.0.0.1:3180")
        XCTAssertEqual(p.launchToken, "t0k")
        XCTAssertEqual(p.name, "This Mac")
    }

    func testLegacyV02Form() throws {
        let p = try payload("clutch://pair?name=Studio&h=studio.local&p=3180&tls=0&t=xyz&v=1")
        XCTAssertEqual(p.origin.absoluteString, "http://studio.local:3180")
        XCTAssertEqual(p.launchToken, "xyz")
        XCTAssertEqual(p.name, "Studio")
    }

    func testLegacyMiniMaxSchemeUsesClutchPort() throws {
        let p = try payload("minimax://pair?h=studio.local")
        XCTAssertEqual(p.origin.absoluteString, "http://studio.local:3180")
        XCTAssertEqual(p.name, "MiniMax Remote")
    }

    func testBareAddressDefaultsPortAndScheme() throws {
        XCTAssertEqual(try payload("127.0.0.1").origin.absoluteString, "http://127.0.0.1:3180")
        XCTAssertEqual(try payload("jay-macbook.boa-roygbiv.ts.net").origin.absoluteString, "https://jay-macbook.boa-roygbiv.ts.net:3180")
        XCTAssertEqual(try payload("jay-macbook.boa-roygbiv.ts.net").name, "jay-macbook")
        XCTAssertNil(try payload("127.0.0.1:3180").launchToken)
    }

    func testServerLinkPairsMiniMaxCodeHostWithoutLaunchToken() throws {
        let p = try payload("clutch://pair?h=jay-server.boa-roygbiv.ts.net&tls=1&kind=mcode&chat=bridge-token-9&chatPort=3181&name=jay-server")
        XCTAssertEqual(p.kind, .codeServer)
        XCTAssertEqual(p.chatToken, "bridge-token-9")
        XCTAssertEqual(p.chatPort, 3181)
        XCTAssertNil(p.launchToken)
        // No web port exists on a server host: the origin rides the chat port.
        XCTAssertEqual(p.origin.absoluteString, "https://jay-server.boa-roygbiv.ts.net:3181")
        XCTAssertEqual(p.name, "jay-server")
    }

    func testWebLinksCarryNoServerKind() throws {
        let p = try payload("http://127.0.0.1:3180/?token=t0k")
        XCTAssertNil(p.kind)
    }

    func testGarbageIsRejected() {
        XCTAssertEqual(failure("   "), .empty)
        XCTAssertEqual(failure("ftp://example.com"), .unsupportedScheme("ftp"))
        XCTAssertEqual(failure("clutch://pair?name=x"), .missingHost)
        XCTAssertEqual(failure("not a link"), .invalidURL)
    }

    func testChatTokenAndPortRideThePairingLink() throws {
        var comps = URLComponents(string: "clutch://pair")!
        comps.queryItems = [
            URLQueryItem(name: "url", value: "https://mac.example.ts.net:3180/?token=abc123"),
            URLQueryItem(name: "chat", value: "bridge-token-1"),
            URLQueryItem(name: "chatPort", value: "3911"),
        ]
        let p = try payload(comps.url!.absoluteString)
        XCTAssertEqual(p.launchToken, "abc123")
        XCTAssertEqual(p.chatToken, "bridge-token-1")
        XCTAssertEqual(p.chatPort, 3911)

        let plain = try payload("http://127.0.0.1:3180/?token=t0k")
        XCTAssertNil(plain.chatToken)
        XCTAssertNil(plain.chatPort)
    }
}

final class ClutchHostTests: XCTestCase {
    func testLaunchURLCarriesTokenOnlyWhilePending() {
        var host = ClutchHost(name: "Mac", origin: URL(string: "https://mac.example.ts.net:3180")!, pendingLaunchToken: "abc")
        XCTAssertEqual(host.launchURL.absoluteString, "https://mac.example.ts.net:3180/?token=abc")
        host.pendingLaunchToken = nil
        XCTAssertEqual(host.launchURL.absoluteString, "https://mac.example.ts.net:3180/")
    }

    func testSameOriginComparesSchemeHostAndPort() {
        let host = ClutchHost(name: "Mac", origin: URL(string: "http://127.0.0.1:3180")!)
        XCTAssertTrue(host.isSameOrigin(URL(string: "http://127.0.0.1:3180/api/x")!))
        XCTAssertFalse(host.isSameOrigin(URL(string: "http://127.0.0.1:3081/")!))
        XCTAssertFalse(host.isSameOrigin(URL(string: "https://127.0.0.1:3180/")!))
        XCTAssertFalse(host.isSameOrigin(URL(string: "https://github.com/")!))
        let tls = ClutchHost(name: "TLS", origin: URL(string: "https://example.com")!)
        XCTAssertTrue(tls.isSameOrigin(URL(string: "https://example.com:443/x")!))
    }
}

final class HostProbeTests: XCTestCase {
    func testAuthWallMeansClutchIsOnline() {
        XCTAssertEqual(HostProbe.classify(statusCode: 401, body: "dsh web authentication required; reopen the URL printed by dsh web.\n"), .online)
    }

    func testMiniMaxCodeProbeTrustsTheSidecarHealthAnswers() {
        XCTAssertEqual(HostProbe.classifyMiniMaxCode(statusCode: 200), .online)
        XCTAssertEqual(HostProbe.classifyMiniMaxCode(statusCode: 401), .online)
        XCTAssertEqual(HostProbe.classifyMiniMaxCode(statusCode: 404), .notClutch)
        XCTAssertEqual(HostProbe.classifyMiniMaxCode(statusCode: 0), .offline)
    }

    func testOtherResponsesAreNotClutch() {
        XCTAssertEqual(HostProbe.classify(statusCode: 401, body: "Unauthorized"), .notClutch)
        XCTAssertEqual(HostProbe.classify(statusCode: 200, body: "<html>"), .notClutch)
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
        let host = store.pair(PairingPayload(name: "Mac", origin: URL(string: "http://127.0.0.1:3180")!, launchToken: "one"))
        XCTAssertEqual(store.activeHost?.id, host.id)
        XCTAssertEqual(store.loadGeneration, 1)

        let reloaded = HostStore(defaults: defaults)
        XCTAssertEqual(reloaded.hosts.count, 1)
        XCTAssertEqual(reloaded.activeHost?.pendingLaunchToken, "one")
    }

    func testRepairSameOriginRefreshesTokenInsteadOfDuplicating() {
        let store = HostStore(defaults: freshDefaults())
        let first = store.pair(PairingPayload(name: "Mac", origin: URL(string: "http://127.0.0.1:3180")!, launchToken: "one"))
        store.consumeLaunchToken(for: first.id)
        XCTAssertNil(store.activeHost?.pendingLaunchToken)
        store.pair(PairingPayload(name: "Other", origin: URL(string: "http://127.0.0.1:3180")!, launchToken: "two"))
        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertEqual(store.activeHost?.pendingLaunchToken, "two")
        XCTAssertEqual(store.activeHost?.name, "Mac")
        XCTAssertEqual(store.loadGeneration, 2)
    }

    func testRemoveActiveFallsBackToRemainingHost() {
        let store = HostStore(defaults: freshDefaults())
        let a = store.pair(PairingPayload(name: "A", origin: URL(string: "http://127.0.0.1:3180")!, launchToken: nil))
        let b = store.pair(PairingPayload(name: "B", origin: URL(string: "https://b.example.ts.net:3180")!, launchToken: nil))
        XCTAssertEqual(store.activeHost?.id, b.id)
        store.remove(b)
        XCTAssertEqual(store.activeHost?.id, a.id)
    }

    func testChatTokenPersistsAndRefreshesOnRepair() {
        let defaults = freshDefaults()
        let store = HostStore(defaults: defaults)
        var payload = PairingPayload(name: "Mac", origin: URL(string: "http://127.0.0.1:3180")!, launchToken: "one")
        payload.chatToken = "chat-one"
        payload.chatPort = 3911
        store.pair(payload)
        XCTAssertEqual(store.activeHost?.chatToken, "chat-one")
        XCTAssertEqual(store.activeHost?.chatPort, 3911)

        let reloaded = HostStore(defaults: defaults)
        XCTAssertEqual(reloaded.activeHost?.chatToken, "chat-one")
        XCTAssertEqual(reloaded.activeHost?.chatPort, 3911)

        var repair = PairingPayload(name: "Other", origin: URL(string: "http://127.0.0.1:3180")!, launchToken: "two")
        repair.chatToken = "chat-two"
        store.pair(repair)
        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertEqual(store.activeHost?.chatToken, "chat-two")
        // chatPort absent from the repair link: keep what the host has.
        XCTAssertEqual(store.activeHost?.chatPort, 3911)
    }

    func testPreChatArchiveDecodesWithNilChatToken() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Mac","origin":"http://127.0.0.1:3180","status":"online"}
        """.data(using: .utf8)!
        let host = try JSONDecoder().decode(ClutchHost.self, from: json)
        XCTAssertNil(host.chatToken)
        XCTAssertNil(host.pendingLaunchToken)
        XCTAssertEqual(host.chatPort, 3181)
        XCTAssertEqual(host.status, .online)
        // Archives written before server hosts existed decode as web hosts.
        XCTAssertEqual(host.kind, .web)
        XCTAssertFalse(host.isMiniMaxCodeOnly)
    }

    func testServerPairingPersistsKind() {
        let defaults = freshDefaults()
        let store = HostStore(defaults: defaults)
        var payload = PairingPayload(name: "jay-server", origin: URL(string: "https://jay-server.boa-roygbiv.ts.net:3181")!, launchToken: nil)
        payload.kind = .codeServer
        payload.chatToken = "chat-server"
        store.pair(payload)
        XCTAssertEqual(store.activeHost?.kind, .codeServer)
        XCTAssertTrue(store.activeHost?.isMiniMaxCodeOnly == true)

        let reloaded = HostStore(defaults: defaults)
        XCTAssertEqual(reloaded.activeHost?.kind, .codeServer)
    }
}
