import XCTest
@testable import SukavinaShared

final class VietnamTimeTests: XCTestCase {
    func testParsesTimestampsWithAndWithoutFraction() throws {
        let fractional = try XCTUnwrap(VietnamTime.date(fromISO8601: "2026-10-15T00:30:00.000Z"))
        let standard = try XCTUnwrap(VietnamTime.date(fromISO8601: "2026-10-15T07:30:00+07:00"))
        XCTAssertEqual(fractional, standard)
        XCTAssertNil(VietnamTime.date(fromISO8601: "15/10/2026"))
    }

    func testRepeatedParsingReturnsTheSameDate() throws {
        let first = try XCTUnwrap(VietnamTime.date(fromISO8601: "2026-11-10T02:15:00.000Z"))
        let second = try XCTUnwrap(VietnamTime.date(fromISO8601: "2026-11-10T02:15:00.000Z"))
        XCTAssertEqual(first, second)
        XCTAssertNil(VietnamTime.date(fromISO8601: "not a date"))
        XCTAssertNil(VietnamTime.date(fromISO8601: "not a date"))
    }

    func testFormatsInVietnamTimeWhateverTheDeviceZone() throws {
        let date = try XCTUnwrap(VietnamTime.date(fromISO8601: "2026-10-14T17:30:00Z"))
        // 17:30 UTC on the 14th is 00:30 on the 15th in Vietnam.
        XCTAssertEqual(VietnamTime.clock.string(from: date), "00:30")
        XCTAssertEqual(VietnamTime.dayKey.string(from: date), "2026-10-15")
        XCTAssertEqual(VietnamTime.monthKey.string(from: date), "2026-10")
    }
}
