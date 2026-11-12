import XCTest
@testable import Clutch

/// The credentials live in the keychain, so a token that can drive a coding
/// session is not in the preferences file.
final class KeychainStoreTests: XCTestCase {
    func testAValueRoundTrips() {
        let account = "test.\(UUID().uuidString)"
        XCTAssertNil(KeychainStore.read(account))
        XCTAssertTrue(KeychainStore.write("secret", account: account))
        XCTAssertEqual(KeychainStore.read(account), "secret")
        // A second write replaces the first.
        XCTAssertTrue(KeychainStore.write("second", account: account))
        XCTAssertEqual(KeychainStore.read(account), "second")
        KeychainStore.delete(account)
        XCTAssertNil(KeychainStore.read(account))
    }

    func testAnEmptyValueIsNotStored() {
        let account = "test.\(UUID().uuidString)"
        XCTAssertFalse(KeychainStore.write("", account: account))
        XCTAssertNil(KeychainStore.read(account))
    }

    func testAnUnknownAccountHasNothing() {
        XCTAssertNil(KeychainStore.read("test.\(UUID().uuidString)"))
    }
}
