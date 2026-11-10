import XCTest
@testable import SukavinaShared

final class MeetingRoomAvailabilityTests: XCTestCase {
    private let calendar = VietnamTime.calendar

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(VietnamTime.date(fromISO8601: value))
    }

    func testBusyDuringAMeetingToday() throws {
        let meetings = [(start: try date("2026-11-10T09:00:00+07:00"), end: try date("2026-11-10T10:00:00+07:00"))]
        let now = try date("2026-11-10T09:30:00+07:00")
        let status = MeetingRoomAvailability.status(meetings: meetings, day: now, now: now, calendar: calendar)
        XCTAssertEqual(status, .busy(until: meetings[0].end))
        XCTAssertFalse(status.isAvailable)
        XCTAssertEqual(status.text(clock: VietnamTime.clock), "Đang họp đến 10:00")
    }

    func testFreeUntilTheEarliestLaterMeetingWhateverTheOrder() throws {
        let meetings = [
            (start: try date("2026-11-10T15:00:00+07:00"), end: try date("2026-11-10T16:00:00+07:00")),
            (start: try date("2026-11-10T11:00:00+07:00"), end: try date("2026-11-10T12:00:00+07:00")),
        ]
        let now = try date("2026-11-10T10:00:00+07:00")
        let status = MeetingRoomAvailability.status(meetings: meetings, day: now, now: now, calendar: calendar)
        XCTAssertEqual(status.text(clock: VietnamTime.clock), "Trống đến 11:00")
        XCTAssertTrue(status.isAvailable)
    }

    func testAnotherDayCountsFromItsStart() throws {
        // Tomorrow picked at 10:00 must still see a 08:00 meeting.
        let meetings = [(start: try date("2026-11-11T08:00:00+07:00"), end: try date("2026-11-11T09:00:00+07:00"))]
        let now = try date("2026-11-10T10:00:00+07:00")
        let day = try date("2026-11-11T10:00:00+07:00")
        let status = MeetingRoomAvailability.status(meetings: meetings, day: day, now: now, calendar: calendar)
        XCTAssertEqual(status.text(clock: VietnamTime.clock), "Trống đến 08:00")
    }

    func testFreeAllDayWithoutLaterMeetings() throws {
        let meetings = [(start: try date("2026-11-10T08:00:00+07:00"), end: try date("2026-11-10T09:00:00+07:00"))]
        let now = try date("2026-11-10T10:00:00+07:00")
        let status = MeetingRoomAvailability.status(meetings: meetings, day: now, now: now, calendar: calendar)
        XCTAssertEqual(status, .freeAllDay)
        XCTAssertEqual(status.text(clock: VietnamTime.clock), "Còn trống cả ngày")
    }
}
