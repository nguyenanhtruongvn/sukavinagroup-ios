import XCTest
@testable import SukavinaShared

final class AttendanceMetricsTests: XCTestCase {
    /// A month on the 07:30-16:30 shift (8 working hours after the lunch hour).
    private func month(_ days: [String]) throws -> AttendanceMonth {
        let json = #"{"month":"2026-10","startTime":"07:30","endTime":"16:30","days":["# + days.joined(separator: ",") + "]}"
        return try JSONDecoder().decode(AttendanceMonth.self, from: Data(json.utf8))
    }

    private func day(_ date: String, in checkIn: String? = nil, out checkOut: String? = nil, extra: String = "") -> String {
        var fields = [#""date":"\#(date)""#, #""punchCount":\#([checkIn, checkOut].compactMap { $0 }.count)"#]
        if let value = checkIn { fields.append(#""checkIn":"\#(date)T\#(value):00+07:00""#) }
        if let value = checkOut { fields.append(#""checkOut":"\#(date)T\#(value):00+07:00""#) }
        if !extra.isEmpty { fields.append(extra) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    // 2026-10-12 is a Monday, 2026-10-11 a Sunday.

    func testFullWeekdayIsOneWorkdayWithoutOvertime() throws {
        let data = try month([day("2026-10-12", in: "07:25", out: "16:35")])
        let metrics = AttendanceMetrics.workMetrics(data.days[0], month: data)
        XCTAssertEqual(metrics.coefficient, 1, accuracy: 0.0001)
        XCTAssertEqual(metrics.overtimeHours, 0)
    }

    func testLatenessCostsWholeHalfHours() throws {
        let data = try month([day("2026-10-12", in: "07:40", out: "16:30")])
        // 10 minutes late is a 30-minute penalty: 450 of 480 minutes.
        XCTAssertEqual(AttendanceMetrics.workMetrics(data.days[0], month: data).coefficient, 450.0 / 480.0, accuracy: 0.0001)
    }

    func testWeekdayOvertimeStartsAtShiftEndInHalfHours() throws {
        let data = try month([day("2026-10-12", in: "07:30", out: "18:10")])
        // 100 minutes after 16:30 counts as 1.5 hours.
        XCTAssertEqual(AttendanceMetrics.workMetrics(data.days[0], month: data).overtimeHours, 1.5)
        XCTAssertEqual(AttendanceMetrics.regularOvertimeHours(data), 1.5)
    }

    func testSundayWorkIsOvertimeFromShiftStartAndNotAWorkday() throws {
        let data = try month([day("2026-10-11", in: "07:00", out: "12:00")])
        let metrics = AttendanceMetrics.workMetrics(data.days[0], month: data)
        // Counted from 07:30, not the earlier check-in: 270 minutes.
        XCTAssertEqual(metrics.overtimeHours, 4.5)
        XCTAssertEqual(metrics.coefficient, 0)
        XCTAssertEqual(AttendanceMetrics.overtimeHours(for: "overtime", in: data), 4.5)
        XCTAssertFalse(AttendanceMetrics.isPaidDay(data.days[0], month: data))
    }

    func testMissingPunchRecognizesNoTimeAndCountsAsMissing() throws {
        let data = try month([day("2026-10-12", in: "07:30")])
        XCTAssertEqual(AttendanceMetrics.statuses(data.days[0]), ["missing_checkout"])
        XCTAssertEqual(AttendanceMetrics.workMetrics(data.days[0], month: data).coefficient, 0)
        XCTAssertEqual(AttendanceMetrics.missingPunchCount(data), 1)
    }

    func testTypedOvertimeAndServerFactorsWin() throws {
        let data = try month([
            day("2026-10-12", in: "07:30", out: "16:30", extra: #""overtimeHours":2,"workdayFactor":1.5,"nightShift":{"workdays":0.5,"overtimeHours":1}"#),
        ])
        let metrics = AttendanceMetrics.workMetrics(data.days[0], month: data)
        XCTAssertEqual(metrics.overtimeHours, 2)
        // The day shift is the date's total minus the night shift.
        XCTAssertEqual(metrics.coefficient, 1)
        XCTAssertEqual(AttendanceMetrics.totalWorkDays(data), 1.5)
        XCTAssertEqual(AttendanceMetrics.dayShiftWorkDays(data), 1)
        XCTAssertEqual(AttendanceMetrics.regularOvertimeHours(data), 3)
    }

    func testHolidayIsPaidUnlessWorkedAsOvertime() throws {
        let data = try month([
            day("2026-10-13", extra: #""statuses":["holiday"]"#),
            day("2026-10-14", in: "07:30", out: "12:00", extra: #""statuses":["holiday"]"#),
        ])
        XCTAssertTrue(AttendanceMetrics.isPaidDay(data.days[0], month: data))
        XCTAssertFalse(AttendanceMetrics.isPaidDay(data.days[1], month: data))
        XCTAssertEqual(AttendanceMetrics.totalWorkDays(data), 1)
        XCTAssertEqual(AttendanceMetrics.calendarNote(data.days[0]), "NL")
    }

    func testAbsenceDisplayUsesVForAllLegacyKccSources() throws {
        let data = try month([
            day("2026-10-05", extra: #""overrideCode":"KCC","workdayCode":"KCC","statuses":["absent"]"#),
            day("2026-10-06", extra: #""workdayCode":"KCC","statuses":["absent"]"#),
            day("2026-10-07", extra: #""statuses":["absent"]"#),
            day("2026-10-08", extra: #""workdayCode":"NP""#),
            day("2026-10-09", extra: #""overrideCode":"V""#),
        ])
        for index in 0..<3 {
            XCTAssertEqual(AttendanceMetrics.calendarNote(data.days[index]), "V")
            XCTAssertEqual(AttendanceMetrics.calendarDisplayNote(data.days[index], showWorkMetrics: false), "V")
        }
        XCTAssertEqual(AttendanceMetrics.calendarNote(data.days[3]), "NP")
        XCTAssertEqual(AttendanceMetrics.calendarNote(data.days[4]), "V")
        // Display conversion must not change the raw payroll/override values.
        XCTAssertEqual(data.days[0].overrideCode, "KCC")
        XCTAssertEqual(data.days[1].workdayCode, "KCC")
    }

    func testNumberTexts() {
        XCTAssertEqual(AttendanceMetrics.hourText(1.5), "1.5")
        XCTAssertEqual(AttendanceMetrics.hourText(2), "2")
        XCTAssertEqual(AttendanceMetrics.workFactorText(0.9375), "0.94")
        XCTAssertEqual(AttendanceMetrics.workFactorText(1), "1")
        XCTAssertEqual(AttendanceMetrics.workFactorText(0.5), "0.5")
    }
    func testCompanyDayOffIsNotPresentedAsPersonalLeave() throws {
        // Backwards-compatible wire status: only the additive companyLeave
        // flag changes the visible status. The server still calculates NP.
        let company = try month([day("2026-10-12", extra: #""status":"leave","statuses":["leave"],"companyLeave":true,"workdayCode":"NP""#)])
        XCTAssertEqual(AttendanceMetrics.displayStatuses(company.days[0]), ["company_leave"])
        XCTAssertEqual(AttendanceMetrics.calendarNote(company.days[0]), "NP")
        let personal = try month([day("2026-10-12", extra: #""status":"leave","statuses":["leave"],"workdayCode":"NP""#)])
        XCTAssertEqual(AttendanceMetrics.displayStatuses(personal.days[0]), ["leave"])
    }

}
