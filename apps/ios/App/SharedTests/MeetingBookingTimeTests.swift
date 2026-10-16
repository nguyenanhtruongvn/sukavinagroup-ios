import XCTest
@testable import SukavinaShared

final class MeetingBookingTimeTests: XCTestCase {
    func testStatusChangesAtBookingBoundariesAndMidnightOnly() throws {
        let calendar = VietnamTime.calendar
        let now = try XCTUnwrap(VietnamTime.date(fromISO8601: "2026-10-16T09:00:00+07:00"))
        let past = try XCTUnwrap(VietnamTime.date(fromISO8601: "2026-10-16T08:00:00+07:00"))
        let start = try XCTUnwrap(VietnamTime.date(fromISO8601: "2026-10-16T10:00:00+07:00"))
        let end = try XCTUnwrap(VietnamTime.date(fromISO8601: "2026-10-16T11:30:00+07:00"))
        let times = MeetingBookingTime.statusChangeTimes(after: now, boundaries: [end, past, start, start], calendar: calendar)
        XCTAssertEqual(times.map { VietnamTime.clock.string(from: $0) }, ["10:00", "11:30", "00:00"])
        XCTAssertEqual(VietnamTime.dayKey.string(from: try XCTUnwrap(times.last)), "2026-10-17")
    }

    private let calendar = VietnamTime.calendar

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(VietnamTime.date(fromISO8601: iso))
    }

    func testStartRoundsUpToTheNextFiveMinutes() throws {
        let day = try date("2026-10-15T00:00:00+07:00")
        let start = MeetingBookingTime.defaultStart(on: day, now: try date("2026-10-15T09:07:30+07:00"), calendar: calendar)
        XCTAssertEqual(VietnamTime.clock.string(from: start), "09:10")
        let exact = MeetingBookingTime.defaultStart(on: day, now: try date("2026-10-15T09:10:00+07:00"), calendar: calendar)
        XCTAssertEqual(VietnamTime.clock.string(from: exact), "09:10")
        let hour = MeetingBookingTime.defaultStart(on: day, now: try date("2026-10-15T09:56:00+07:00"), calendar: calendar)
        XCTAssertEqual(VietnamTime.clock.string(from: hour), "10:00")
    }

    func testStartStaysOnTheChosenDayAndNeverRollsOver() throws {
        let tomorrow = try date("2026-10-16T00:00:00+07:00")
        let start = MeetingBookingTime.defaultStart(on: tomorrow, now: try date("2026-10-15T23:58:00+07:00"), calendar: calendar)
        XCTAssertEqual(VietnamTime.dayKey.string(from: start), "2026-10-16")
        XCTAssertEqual(VietnamTime.clock.string(from: start), "23:55")
    }

    func testPastStartAndOverCapacityAreBlockedWithAReason() throws {
        let now = try date("2026-10-15T14:20:00+07:00")
        XCTAssertNotNil(MeetingBookingTime.blockReason(start: try date("2026-10-15T14:15:00+07:00"), now: now, attendeeCount: 1, capacity: 10, calendar: calendar))
        XCTAssertNil(MeetingBookingTime.blockReason(start: try date("2026-10-15T14:20:00+07:00"), now: now, attendeeCount: 1, capacity: 10, calendar: calendar))
        XCTAssertNotNil(MeetingBookingTime.blockReason(start: try date("2026-10-16T09:00:00+07:00"), now: now, attendeeCount: 11, capacity: 10, calendar: calendar))
    }
}
