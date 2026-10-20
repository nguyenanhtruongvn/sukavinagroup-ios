import XCTest
@testable import SukavinaShared

final class PasswordPolicyTests: XCTestCase {
    func testRequiresLengthLetterAndDigit() {
        XCTAssertEqual(PasswordPolicy.problem("ab1"), "Mật khẩu phải có ít nhất 6 ký tự.")
        XCTAssertEqual(PasswordPolicy.problem("123456"), "Mật khẩu phải có ít nhất một chữ cái.")
        XCTAssertEqual(PasswordPolicy.problem("abcdef"), "Mật khẩu phải có ít nhất một chữ số.")
        XCTAssertNil(PasswordPolicy.problem("abc123"))
        XCTAssertNil(PasswordPolicy.problem("Mật khẩu 2026"))
    }
}
