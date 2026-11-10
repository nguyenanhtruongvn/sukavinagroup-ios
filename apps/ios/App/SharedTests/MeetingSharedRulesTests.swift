import XCTest
@testable import SukavinaShared

private struct Person: MeetingInviteeSearchable {
    let id: String
    let fullName: String
    let employeeCode: String
    let department: String
}

final class MeetingSharedRulesTests: XCTestCase {
    private let people = [
        Person(id: "1", fullName: "Nguyễn An", employeeCode: "00010", department: "Kế toán"),
        Person(id: "2", fullName: "Trần Bình", employeeCode: "00020", department: "Nhân sự"),
        Person(id: "3", fullName: "Lê Chi", employeeCode: "00030", department: "kế toán"),
        Person(id: "4", fullName: "Phạm Dung", employeeCode: "00040", department: " "),
    ]

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(VietnamTime.date(fromISO8601: value))
    }

    func testBookingTitleAndUnsavedInput() {
        XCTAssertEqual(MeetingBookingForm.title(type: "Nội bộ", text: "  "), "Nội bộ")
        XCTAssertEqual(MeetingBookingForm.title(type: "Nội bộ", text: " Giao ban "), "Nội bộ · Giao ban")
        XCTAssertFalse(MeetingBookingForm.hasUnsavedInput(title: " ", selectedCount: 0))
        XCTAssertTrue(MeetingBookingForm.hasUnsavedInput(title: "", selectedCount: 1))
    }

    func testPeopleNeedAQueryOrADepartment() {
        XCTAssertTrue(MeetingBookingForm.people(people, query: " ", departments: []).isEmpty)
        XCTAssertEqual(MeetingBookingForm.people(people, query: "bình", departments: []).map(\.id), ["2"])
        XCTAssertEqual(MeetingBookingForm.people(people, query: "000", departments: ["Kế toán"]).map(\.id), ["1"])
        XCTAssertEqual(MeetingBookingForm.people(people, query: "", departments: ["Nhân sự"]).map(\.id), ["2"])
    }

    func testDepartmentsAreDistinctNonEmptyAndSearchable() {
        let departments = MeetingBookingForm.departments(people)
        XCTAssertEqual(Set(departments), ["Kế toán", "kế toán", "Nhân sự"])
        XCTAssertTrue(MeetingBookingForm.matchingDepartments(departments, query: "").isEmpty)
        XCTAssertEqual(MeetingBookingForm.matchingDepartments(departments, query: "nhân"), ["Nhân sự"])
        XCTAssertEqual(
            MeetingBookingForm.uninvited(people, departments: ["Kế toán"], selected: ["1"]).map(\.id), []
        )
        XCTAssertEqual(
            MeetingBookingForm.uninvited(people, departments: ["Nhân sự"], selected: []).map(\.id), ["2"]
        )
    }

    func testOrganizerActionsSwitchAtTheStart() throws {
        let start = try date("2026-11-10T09:00:00+07:00")
        let before = start.addingTimeInterval(-60)
        XCTAssertTrue(MeetingDetailRules.canCancel(isOwner: true, status: "confirmed", start: start, now: before))
        XCTAssertFalse(MeetingDetailRules.showsControls(isOwner: true, status: "confirmed", start: start, now: before))
        XCTAssertFalse(MeetingDetailRules.canCancel(isOwner: true, status: "confirmed", start: start, now: start))
        XCTAssertTrue(MeetingDetailRules.showsControls(isOwner: true, status: "confirmed", start: start, now: start))
        XCTAssertFalse(MeetingDetailRules.canCancel(isOwner: false, status: "confirmed", start: start, now: before))
        XCTAssertFalse(MeetingDetailRules.showsControls(isOwner: true, status: "cancelled", start: start, now: start))
    }

    func testDetailTexts() throws {
        XCTAssertEqual(MeetingDetailRules.roleTitle(isOwner: true, isLimitedViewer: false), "Bạn là người tổ chức")
        XCTAssertEqual(MeetingDetailRules.roleTitle(isOwner: true, isLimitedViewer: true), "Thông tin giới hạn dành cho Phòng Nhân sự")
        let start = try date("2026-11-10T09:00:00+07:00")
        XCTAssertEqual(MeetingDetailRules.durationTitle(start: start, end: start.addingTimeInterval(5_400)), "1 giờ 30 phút")
        XCTAssertEqual(MeetingDetailRules.durationTitle(start: nil, end: start), "—")
        XCTAssertEqual(MeetingDetailRules.dateTitle(start: nil), "Chưa xác định")
        XCTAssertEqual(
            MeetingDetailRules.extensionBlockMessage(roomName: "Phòng A", next: (title: "", startText: "10:00")),
            "Không thể gia hạn vì Phòng A có cuộc họp tiếp theo lúc 10:00."
        )
        XCTAssertEqual(MeetingDetailRules.extensionToSend(chosen: 30, maximum: 15), 15)
    }

    func testUpcomingEndsExactlyAtTheEndTime() throws {
        let end = try date("2026-11-10T10:00:00+07:00")
        XCTAssertTrue(MeetingDetailRules.isUpcoming(end: end, now: end.addingTimeInterval(-1)))
        XCTAssertFalse(MeetingDetailRules.isUpcoming(end: end, now: end))
        XCTAssertTrue(MeetingDetailRules.isUpcoming(end: nil, now: end))
    }

    func testRoomStatusIgnoresOtherDaysBookings() throws {
        let now = try date("2026-11-10T10:00:00+07:00")
        let tomorrow = (start: try date("2026-11-11T08:00:00+07:00"), end: try date("2026-11-11T09:00:00+07:00"))
        let status = MeetingRoomAvailability.status(meetings: [tomorrow], day: now, now: now, calendar: VietnamTime.calendar)
        XCTAssertEqual(status, .freeAllDay)
    }
}
