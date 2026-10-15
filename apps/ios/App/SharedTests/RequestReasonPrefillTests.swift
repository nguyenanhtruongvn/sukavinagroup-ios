import XCTest
@testable import SukavinaShared

final class RequestReasonPrefillTests: XCTestCase {
    func testDurationPrefixBecomesTheDurationFields() {
        let overtime = RequestReasonPrefill(
            reason: "Làm thêm giờ: 3 giờ. soạn hàng đơn lắp ráp",
            kindTitle: "Làm thêm giờ",
            usesDuration: true
        )
        XCTAssertEqual(overtime.durationValue, 3)
        XCTAssertTrue(overtime.durationIsHours)
        XCTAssertEqual(overtime.reason, "soạn hàng đơn lắp ráp")

        let late = RequestReasonPrefill(reason: "Đi trễ: 30 phút. Kẹt xe", kindTitle: "Đi trễ", usesDuration: true)
        XCTAssertEqual(late.durationValue, 30)
        XCTAssertFalse(late.durationIsHours)
        XCTAssertEqual(late.reason, "Kẹt xe")
    }

    func testReasonWithoutThePrefixIsKeptAsIs() {
        let prefill = RequestReasonPrefill(reason: "  Kẹt xe  ", kindTitle: "Đi trễ", usesDuration: true)
        XCTAssertNil(prefill.durationValue)
        XCTAssertEqual(prefill.reason, "Kẹt xe")
    }

    func testKindsWithoutDurationKeepTheWholeReason() {
        let prefill = RequestReasonPrefill(reason: "Xin nghỉ: 2 giờ. việc riêng", kindTitle: "Xin nghỉ", usesDuration: false)
        XCTAssertNil(prefill.durationValue)
        XCTAssertEqual(prefill.reason, "Xin nghỉ: 2 giờ. việc riêng")
    }

    func testOutOfRangeDurationIsNotParsed() {
        let prefill = RequestReasonPrefill(reason: "Đi trễ: 90 phút. Kẹt xe", kindTitle: "Đi trễ", usesDuration: true)
        XCTAssertNil(prefill.durationValue)
        XCTAssertEqual(prefill.reason, "Đi trễ: 90 phút. Kẹt xe")
    }
}
