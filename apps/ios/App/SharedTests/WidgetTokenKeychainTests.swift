import XCTest
@testable import SukavinaShared

final class WidgetTokenKeychainTests: XCTestCase {
    func testAcceptsOnlyATeamPrefixedSharedGroup() {
        XCTAssertTrue(WidgetTokenKeychain.isTeamPrefixed("TZWRHJ9UYN.net.sukavinagroup.shared"))
        // Unsigned builds leave $(AppIdentifierPrefix) empty or unexpanded.
        XCTAssertFalse(WidgetTokenKeychain.isTeamPrefixed("net.sukavinagroup.shared"))
        XCTAssertFalse(WidgetTokenKeychain.isTeamPrefixed("$(AppIdentifierPrefix)net.sukavinagroup.shared"))
        XCTAssertFalse(WidgetTokenKeychain.isTeamPrefixed(".net.sukavinagroup.shared"))
        XCTAssertFalse(WidgetTokenKeychain.isTeamPrefixed("TZWRHJ9UYN.net.sukavinagroup.user"))
    }

    func testWithoutTheInfoPlistGroupTheKeychainIsNotUsed() {
        // The test bundle has no SukavinaKeychainGroup: callers must fall back.
        XCTAssertFalse(WidgetTokenKeychain.isAvailable)
        XCTAssertFalse(WidgetTokenKeychain.save("token"))
        XCTAssertNil(WidgetTokenKeychain.load())
    }
}
