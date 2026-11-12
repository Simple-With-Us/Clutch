import XCTest
@testable import Clutch

/// The tabs a host can take away, and the selection that has to move when
/// it does.
///
/// A code-server host has no dsh host behind it, so the Host console goes
/// away — and the Mac loses its Agent Chat with it, while the phone keeps
/// its Chat tab.
final class HostTabsTests: XCTestCase {
    private func codeServer() -> ClutchHost {
        ClutchHost(name: "MiniMax", origin: URL(string: "http://127.0.0.1:3180")!, kind: .codeServer)
    }

    private func webHost() -> ClutchHost {
        ClutchHost(name: "Mac", origin: URL(string: "http://127.0.0.1:3180")!)
    }

    func testAWebHostKeepsEveryTab() {
        XCTAssertTrue(HostTabs.hidden(for: webHost(), platform: .phone).isEmpty)
        XCTAssertTrue(HostTabs.hidden(for: webHost(), platform: .mac).isEmpty)
    }

    func testACodeServerTakesTheHostConsoleOnBothPlatforms() {
        XCTAssertEqual(HostTabs.hidden(for: codeServer(), platform: .phone), [2])
        XCTAssertEqual(HostTabs.hidden(for: codeServer(), platform: .mac), [1, 2])
    }

    func testThePhoneKeepsItsChatTabForACodeServer() {
        // Tag 1 is Chat on the phone and Agent Chat on the Mac, so only the
        // Mac loses it.
        XCTAssertEqual(HostTabs.clamp(1, for: codeServer(), platform: .phone), 1)
        XCTAssertEqual(HostTabs.clamp(1, for: codeServer(), platform: .mac), 0)
    }

    func testASelectionOnATabThatIsGoneMovesToTheWorkspace() {
        XCTAssertEqual(HostTabs.clamp(2, for: codeServer(), platform: .phone), 0)
        XCTAssertEqual(HostTabs.clamp(2, for: codeServer(), platform: .mac), 0)
    }

    func testTheFleetRecallTabIsAlwaysThere() {
        XCTAssertEqual(HostTabs.clamp(3, for: codeServer(), platform: .phone), 3)
        XCTAssertEqual(HostTabs.clamp(3, for: codeServer(), platform: .mac), 3)
    }

    func testAWebHostKeepsTheSelectionWhereItIs() {
        XCTAssertEqual(HostTabs.clamp(1, for: webHost(), platform: .phone), 1)
        XCTAssertEqual(HostTabs.clamp(2, for: webHost(), platform: .mac), 2)
    }
}
