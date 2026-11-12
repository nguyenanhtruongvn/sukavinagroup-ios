import XCTest
@testable import SukavinaShared

private struct Employee: RequestRecipient {
    let id: String
    let fullName: String
    let isSelf: Bool
}

final class RequestFormRulesTests: XCTestCase {
    private let calendar = VietnamTime.calendar

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(VietnamTime.date(fromISO8601: value))
    }

    private func draft(_ kind: RequestFormKind, start: Date, end: Date) -> RequestFormRules.Draft {
        RequestFormRules.Draft(
            kind: kind, reason: "Lý do đủ dài để gửi", destination: "", transport: "personal_vehicle",
            distanceText: "", durationMinutesText: 30, start: start, end: end,
            recipientsLoaded: false, selectedRecipientCount: 0
        )
    }

    func testDurationsAreWholeStepsInRange() {
        XCTAssertEqual(RequestFormRules.validDuration(30), 30)
        XCTAssertNil(RequestFormRules.validDuration(32))
        XCTAssertNil(RequestFormRules.validDuration(30.5))
        XCTAssertNil(RequestFormRules.validDuration(0))
        XCTAssertNil(RequestFormRules.validDuration(1440))
        XCTAssertNil(RequestFormRules.validDuration(nil))
    }

    func testOvertimeSnapsToTheStepOnBothVersions() throws {
        // 47 minutes used to become 30 on iOS 17 and 45 on iOS 18.
        let start = try date("2026-11-10T17:00:00+07:00")
        let adjusted = RequestFormRules.overtimeAfterEndChange(start: start, end: start.addingTimeInterval(47 * 60), minutes: 30)
        XCTAssertEqual(adjusted.minutes, 45)
        XCTAssertEqual(adjusted.end, start.addingTimeInterval(45 * 60))
        let backwards = RequestFormRules.overtimeAfterEndChange(start: start, end: start.addingTimeInterval(-60), minutes: 30)
        XCTAssertEqual(backwards.start, start.addingTimeInterval(-60 - 30 * 60))
        let moved = RequestFormRules.overtimeAfterStartChange(start: start, end: start.addingTimeInterval(-60), minutes: 30)
        XCTAssertEqual(moved.end, start.addingTimeInterval(30 * 60))
    }

    func testShiftTimesAndNextSunday() throws {
        let day = try date("2026-11-10T00:00:00+07:00") // Tuesday
        XCTAssertEqual(VietnamTime.clock.string(from: RequestFormRules.shiftStart("08:15", on: day, calendar: calendar)), "08:15")
        // An invalid hour falls back alone; the valid minute is kept (as before).
        XCTAssertEqual(VietnamTime.clock.string(from: RequestFormRules.shiftStart("25:00", on: day, calendar: calendar)), "07:00")
        XCTAssertEqual(VietnamTime.clock.string(from: RequestFormRules.shiftStart("abc", on: day, calendar: calendar)), "07:30")
        XCTAssertEqual(VietnamTime.clock.string(from: RequestFormRules.shiftEnd(nil, on: day, calendar: calendar)), "16:30")
        let sunday = RequestFormRules.nextSunday(from: day, calendar: calendar)
        XCTAssertEqual(VietnamTime.dayKey.string(from: sunday), "2026-11-15")
        XCTAssertEqual(RequestFormRules.nextSunday(from: sunday, calendar: calendar), sunday)
    }

    func testKindDefaults() throws {
        let now = try date("2026-11-10T09:12:00+07:00")
        let business = try XCTUnwrap(RequestFormRules.defaults(for: .business, now: now, currentStart: now, workStart: nil, workEnd: nil, calendar: calendar))
        XCTAssertEqual(business.end.timeIntervalSince(business.start), 3600)
        let overtime = try XCTUnwrap(RequestFormRules.defaults(for: .overtime, now: now, currentStart: now, workStart: nil, workEnd: "17:00", calendar: calendar))
        XCTAssertEqual(VietnamTime.clock.string(from: overtime.start), "17:00")
        XCTAssertEqual(overtime.durationMinutes, 30)
        XCTAssertNil(RequestFormRules.defaults(for: .attendance, now: now, currentStart: now, workStart: nil, workEnd: nil, calendar: calendar))
    }

    func testLateAndEarlyFollowTheShift() throws {
        let day = try date("2026-11-10T13:00:00+07:00")
        let late = RequestFormRules.submissionDates(kind: .late, start: day, end: day, day: day, durationMinutes: 30, workStart: "08:00", workEnd: "17:00", calendar: calendar)
        XCTAssertEqual(VietnamTime.clock.string(from: late.start), "08:00")
        XCTAssertEqual(VietnamTime.clock.string(from: late.end), "08:30")
        let early = RequestFormRules.submissionDates(kind: .early, start: day, end: day, day: day, durationMinutes: 45, workStart: "08:00", workEnd: "17:00", calendar: calendar)
        XCTAssertEqual(VietnamTime.clock.string(from: early.start), "16:15")
        XCTAssertEqual(VietnamTime.clock.string(from: early.end), "17:00")
    }

    func testMissingRequirementOrderAndRules() throws {
        let start = try date("2026-11-10T09:00:00+07:00")
        let end = start.addingTimeInterval(3600)
        var business = draft(.business, start: start, end: end)
        XCTAssertEqual(RequestFormRules.missingRequirement(business, calendar: calendar), "Nhập nơi công tác để gửi đơn.")
        business.destination = "Hà Nội"
        XCTAssertEqual(RequestFormRules.missingRequirement(business, calendar: calendar), "Nhập quãng đường khi đi bằng xe cá nhân.")
        business.distanceText = "12,5"
        XCTAssertNil(RequestFormRules.missingRequirement(business, calendar: calendar))

        XCTAssertEqual(RequestFormRules.missingRequirement(draft(.sunday, start: start, end: end), calendar: calendar), "Ngày bắt đầu phải là Chủ nhật.")
        XCTAssertEqual(RequestFormRules.missingRequirement(draft(.overtime, start: end, end: start), calendar: calendar), "Giờ kết thúc phải sau giờ bắt đầu.")

        var late = draft(.late, start: start, end: end)
        late.durationMinutesText = 32
        XCTAssertEqual(RequestFormRules.missingRequirement(late, calendar: calendar), "Thời lượng phải từ 5 phút đến 23 giờ 55 phút, theo bước 5 phút.")

        var leave = draft(.leave, start: start, end: end)
        leave.recipientsLoaded = true
        XCTAssertEqual(RequestFormRules.missingRequirement(leave, calendar: calendar), "Chọn ít nhất một người tạo đơn.")
        leave.selectedRecipientCount = 1
        leave.reason = "ngắn"
        XCTAssertEqual(RequestFormRules.missingRequirement(leave, calendar: calendar), "Nội dung đơn cần tối thiểu 10 ký tự.")
        leave.reason = "Lý do đủ dài để gửi"
        leave.end = start.addingTimeInterval(-60)
        XCTAssertEqual(RequestFormRules.missingRequirement(leave, calendar: calendar), "Thời gian kết thúc phải sau thời gian bắt đầu.")
    }

    func testOvertimeOverlapIsShownBeforeSending() throws {
        let existing = RequestFormRules.ExistingOvertime(
            start: try date("2026-11-12T17:00:00+07:00"),
            end: try date("2026-11-12T19:00:00+07:00"),
            approved: false
        )
        var overtime = draft(.overtime, start: try date("2026-11-12T18:00:00+07:00"), end: try date("2026-11-12T20:00:00+07:00"))
        overtime.existingOvertime = [existing]
        overtime.reason = ""
        // Shown even before a reason is typed: the time is what must change.
        XCTAssertEqual(
            RequestFormRules.missingRequirement(overtime, calendar: calendar),
            "Trùng giờ với đơn làm thêm 17:00–19:00 ngày 12/11 (đang chờ duyệt)."
        )
        // An overnight request names both days.
        XCTAssertEqual(
            RequestFormRules.overtimeOverlapMessage(.init(
                start: try date("2026-11-12T22:00:00+07:00"), end: try date("2026-11-13T02:00:00+07:00"), approved: false
            )),
            "Trùng giờ với đơn làm thêm 22:00 12/11 – 02:00 13/11 (đang chờ duyệt)."
        )

        var approved = existing
        approved.approved = true
        overtime.existingOvertime = [approved]
        XCTAssertTrue(RequestFormRules.missingRequirement(overtime, calendar: calendar)?.contains("(đã duyệt)") == true)

        // Back-to-back is allowed, as on the server.
        overtime.reason = "Lý do đủ dài để gửi"
        overtime.start = try date("2026-11-12T19:00:00+07:00")
        overtime.end = try date("2026-11-12T21:00:00+07:00")
        XCTAssertNil(RequestFormRules.missingRequirement(overtime, calendar: calendar))

        // Sunday work is stored as overtime and follows the same rule.
        var sunday = draft(.sunday, start: try date("2026-11-15T08:00:00+07:00"), end: try date("2026-11-15T12:00:00+07:00"))
        sunday.existingOvertime = [.init(start: try date("2026-11-15T07:30:00+07:00"), end: try date("2026-11-15T16:30:00+07:00"), approved: true)]
        XCTAssertTrue(RequestFormRules.missingRequirement(sunday, calendar: calendar)?.hasPrefix("Trùng giờ với đơn làm thêm") == true)

        // Only for the user's own request; other kinds are not checked.
        sunday.includesSelf = false
        XCTAssertNil(RequestFormRules.missingRequirement(sunday, calendar: calendar))
        var leave = draft(.leave, start: try date("2026-11-12T18:00:00+07:00"), end: try date("2026-11-12T20:00:00+07:00"))
        leave.existingOvertime = [existing]
        XCTAssertNil(RequestFormRules.missingRequirement(leave, calendar: calendar))
    }

    func testBusinessFieldsOnlyForBusiness() {
        let leave = RequestFormRules.businessFields(kind: .leave, destination: "X", transport: "personal_vehicle", distanceText: "3", lunchMeal: true, dinnerMeal: true)
        XCTAssertNil(leave.destination)
        XCTAssertNil(leave.transport)
        XCTAssertNil(leave.distanceKm)
        XCTAssertNil(leave.lunchMeal)
        let business = RequestFormRules.businessFields(kind: .business, destination: " Hà Nội ", transport: "grab", distanceText: "3,5", lunchMeal: true, dinnerMeal: false)
        XCTAssertEqual(business.destination, "Hà Nội")
        XCTAssertEqual(business.transport, "grab")
        XCTAssertEqual(business.distanceKm, 3.5)
        XCTAssertEqual(business.dinnerMeal, false)
    }

    func testTextHelpers() {
        XCTAssertEqual(RequestFormRules.numberText(12), "12")
        XCTAssertEqual(RequestFormRules.numberText(12.5), "12.5")
        XCTAssertEqual(RequestFormRules.durationReason(kindTitle: "Đi trễ", minutes: 90, reason: "Kẹt xe"), "Đi trễ: 1 giờ 30 phút. Kẹt xe")
    }

    func testRecipientSummaryAndToggle() {
        let people = [
            Employee(id: "me", fullName: "Tôi", isSelf: true),
            Employee(id: "a", fullName: "An", isSelf: false),
            Employee(id: "b", fullName: "Bình", isSelf: false),
        ]
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: people, selected: [], loaded: false, initialized: false), "Tôi")
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: people, selected: [], loaded: true, initialized: false), "Tôi")
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: people, selected: [], loaded: true, initialized: true), "Chưa chọn người")
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: people, selected: ["me", "a", "b"], loaded: true, initialized: true), "Tất cả")
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: people, selected: ["me", "a"], loaded: true, initialized: true), "Tôi, An")

        let first = RequestFormRules.toggle("a", employees: people, selected: ["me"], hasChosenManagedEmployee: false)
        XCTAssertEqual(first.selected, ["a"])
        XCTAssertTrue(first.hasChosenManagedEmployee)
        let second = RequestFormRules.toggle("me", employees: people, selected: first.selected, hasChosenManagedEmployee: true)
        XCTAssertEqual(second.selected, ["a", "me"])
        let removed = RequestFormRules.toggle("a", employees: people, selected: second.selected, hasChosenManagedEmployee: true)
        XCTAssertEqual(removed.selected, ["me"])
    }
}
