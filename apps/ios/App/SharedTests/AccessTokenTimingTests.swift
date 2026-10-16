import XCTest
@testable import SukavinaShared

final class AccessTokenTimingTests: XCTestCase {
    private func token(exp: TimeInterval) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["sub": "employee-1", "exp": exp])
        let base64url = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(base64url).signature"
    }

    func testRenewsTenMinutesBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = now.addingTimeInterval(24 * 60 * 60)
        let renewal = AccessTokenTiming.renewalDate(for: token(exp: expiry.timeIntervalSince1970), now: now)
        XCTAssertEqual(renewal, expiry.addingTimeInterval(-600))
    }

    func testAnOldTokenIsRenewedImmediately() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let renewal = AccessTokenTiming.renewalDate(for: token(exp: now.addingTimeInterval(300).timeIntervalSince1970), now: now)
        XCTAssertEqual(renewal, now)
    }

    func testUnreadableTokenFallsBack() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(AccessTokenTiming.expiry(of: "not-a-jwt"))
        XCTAssertEqual(AccessTokenTiming.renewalDate(for: "not-a-jwt", now: now), now.addingTimeInterval(12 * 60 * 60))
    }
}
