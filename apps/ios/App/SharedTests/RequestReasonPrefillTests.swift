import XCTest
@testable import SukavinaShared

final class RequestReasonPrefillTests: XCTestCase {
    func testDurationPrefixBecomesTheDuration() {
        let overtime = RequestReasonPrefill(
            reason: "Làm thêm giờ: 3 giờ. soạn hàng đơn lắp ráp",
            kindTitle: "Làm thêm giờ",
            usesDuration: true
        )
        XCTAssertEqual(overtime.durationMinutes, 180)
        XCTAssertEqual(overtime.reason, "soạn hàng đơn lắp ráp")

        let late = RequestReasonPrefill(reason: "Đi trễ: 30 phút. Kẹt xe", kindTitle: "Đi trễ", usesDuration: true)
        XCTAssertEqual(late.durationMinutes, 30)
        XCTAssertEqual(late.reason, "Kẹt xe")
    }

    func testHoursAndMinutesReadBack() {
        let early = RequestReasonPrefill(reason: "Về sớm: 1 giờ 30 phút. Đón con", kindTitle: "Về sớm", usesDuration: true)
        XCTAssertEqual(early.durationMinutes, 90)
        XCTAssertEqual(early.reason, "Đón con")
    }

    func testEveryWrittenDurationReadsBack() {
        for minutes in stride(from: 5, through: 1435, by: 5) {
            let reason = "Làm thêm giờ: \(DurationClock.title(minutes: minutes)). Kiểm kho"
            let prefill = RequestReasonPrefill(reason: reason, kindTitle: "Làm thêm giờ", usesDuration: true)
            XCTAssertEqual(prefill.durationMinutes, minutes, reason)
            XCTAssertEqual(prefill.reason, "Kiểm kho")
        }
    }

    func testReasonWithoutThePrefixIsKeptAsIs() {
        let prefill = RequestReasonPrefill(reason: "  Kẹt xe  ", kindTitle: "Đi trễ", usesDuration: true)
        XCTAssertNil(prefill.durationMinutes)
        XCTAssertEqual(prefill.reason, "Kẹt xe")
    }

    func testKindsWithoutDurationKeepTheWholeReason() {
        let prefill = RequestReasonPrefill(reason: "Xin nghỉ: 2 giờ. việc riêng", kindTitle: "Xin nghỉ", usesDuration: false)
        XCTAssertNil(prefill.durationMinutes)
        XCTAssertEqual(prefill.reason, "Xin nghỉ: 2 giờ. việc riêng")
    }

    func testOutOfRangeDurationIsNotParsed() {
        let prefill = RequestReasonPrefill(reason: "Đi trễ: 90 phút. Kẹt xe", kindTitle: "Đi trễ", usesDuration: true)
        XCTAssertNil(prefill.durationMinutes)
        XCTAssertEqual(prefill.reason, "Đi trễ: 90 phút. Kẹt xe")
    }
}
