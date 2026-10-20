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

    func testMeeting00010UpcomingAt1736AndNotEndedUntil1945() throws {
        let start = try date("2026-10-20T19:15:00+07:00")
        let end = try date("2026-10-20T19:45:00+07:00")
        let before = try date("2026-10-20T17:36:00+07:00")
        XCTAssertEqual(MeetingBookingTime.phase(start: start, end: end, now: before), .upcoming)
        XCTAssertFalse(MeetingBookingTime.hasEnded(end: end, now: before))
        XCTAssertEqual(MeetingBookingTime.phase(start: start, end: end, now: start), .inProgress)
        XCTAssertEqual(MeetingBookingTime.phase(
            start: start, end: end, now: try date("2026-10-20T19:44:59+07:00")
        ), .inProgress)
        XCTAssertEqual(MeetingBookingTime.phase(start: start, end: end, now: end), .ended)
        XCTAssertTrue(MeetingBookingTime.hasEnded(end: end, now: end))
    }

    func testMeetingMissingEndRemainsUpcomingUntilStart() throws {
        let start = try date("2026-10-20T19:15:00+07:00")
        XCTAssertEqual(MeetingBookingTime.phase(
            start: start, end: nil, now: try date("2026-10-20T17:36:00+07:00")
        ), .upcoming)
        XCTAssertEqual(MeetingBookingTime.phase(start: start, end: nil, now: start), .inProgress)
        XCTAssertFalse(MeetingBookingTime.hasEnded(end: nil, now: start))
    }

    func testMeetingLifecycleUsesAbsoluteTimeAcrossTimezones() throws {
        let start = try date("2026-10-20T19:15:00+07:00")
        let end = try date("2026-10-20T19:45:00+07:00")
        XCTAssertEqual(MeetingBookingTime.phase(
            start: start, end: end, now: try date("2026-10-20T10:36:00Z")
        ), .upcoming)
        XCTAssertEqual(MeetingBookingTime.phase(
            start: start, end: end, now: try date("2026-10-20T12:30:00Z")
        ), .inProgress)
        XCTAssertEqual(MeetingBookingTime.phase(
            start: start, end: end, now: try date("2026-10-20T12:45:00Z")
        ), .ended)
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

    func testDurationClockRoundTripsEveryStep() {
        for minutes in stride(from: 5, through: 1435, by: 5) {
            let clock = DurationClock.date(forMinutes: minutes, calendar: calendar)
            XCTAssertEqual(DurationClock.minutes(from: clock, step: 5, range: 5...1435, calendar: calendar), minutes)
        }
        let ninety = DurationClock.date(forMinutes: 90, calendar: calendar)
        XCTAssertEqual(VietnamTime.clock.string(from: ninety), "01:30")
    }

    func testDurationFromClockStaysOnStepAndInRange() throws {
        let day = DurationClock.date(forMinutes: 0, calendar: calendar)
        func clock(_ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day))
        }
        let range = MeetingBookingTime.durationRange
        XCTAssertEqual(DurationClock.minutes(from: try clock(0, 0), step: 5, range: range, calendar: calendar), 5)
        XCTAssertEqual(DurationClock.minutes(from: try clock(0, 7), step: 5, range: range, calendar: calendar), 5)
        XCTAssertEqual(DurationClock.minutes(from: try clock(1, 33), step: 5, range: range, calendar: calendar), 95)
        XCTAssertEqual(DurationClock.minutes(from: try clock(9, 30), step: 5, range: range, calendar: calendar), 480)
    }

    func testDurationTitleSplitsHoursAndMinutes() {
        XCTAssertEqual(DurationClock.title(minutes: 30), "30 phút")
        XCTAssertEqual(DurationClock.title(minutes: 60), "1 giờ")
        XCTAssertEqual(DurationClock.title(minutes: 150), "2 giờ 30 phút")
    }

    func testPastStartAndOverCapacityAreBlockedWithAReason() throws {
        let now = try date("2026-10-15T14:20:00+07:00")
        XCTAssertNotNil(MeetingBookingTime.blockReason(start: try date("2026-10-15T14:15:00+07:00"), now: now, attendeeCount: 1, capacity: 10, calendar: calendar))
        XCTAssertNil(MeetingBookingTime.blockReason(start: try date("2026-10-15T14:20:00+07:00"), now: now, attendeeCount: 1, capacity: 10, calendar: calendar))
        XCTAssertNotNil(MeetingBookingTime.blockReason(start: try date("2026-10-16T09:00:00+07:00"), now: now, attendeeCount: 11, capacity: 10, calendar: calendar))
    }

    func testBookingCapacityWarningAppearsAtSameConfirmPositionAsPastTime() throws {
        let now = try date("2026-10-20T17:36:00+07:00")
        let past = try date("2026-10-20T17:30:00+07:00")
        let future = try date("2026-10-20T19:15:00+07:00")
        let timeWarning = "Giờ bắt đầu đã qua. Hãy chọn giờ muộn hơn."
        let capacityWarning = "Vượt sức chứa phòng (6/5 chỗ). Hãy bớt người được mời."

        // Priority 1: past start masks the capacity warning when both fail.
        XCTAssertEqual(MeetingBookingTime.blockReason(
            start: past, now: now, attendeeCount: 6, capacity: 5, calendar: calendar
        ), timeWarning)

        // Priority 2: only a valid future time exposes the capacity warning.
        XCTAssertEqual(MeetingBookingTime.blockReason(
            start: future, now: now, attendeeCount: 6, capacity: 5, calendar: calendar
        ), capacityWarning)

        // The organiser is included in attendeeCount (5 invited + organiser).
        XCTAssertNil(MeetingBookingTime.blockReason(
            start: future, now: now, attendeeCount: 5, capacity: 5, calendar: calendar
        ))
        XCTAssertEqual(MeetingBookingTime.blockReason(
            start: future, now: now, attendeeCount: 6, capacity: 5, calendar: calendar
        ), capacityWarning)
    }

    func testOnePersonOverCapacityAlsoWarnsWhenRoomHasNoAvailableSeats() throws {
        let now = try date("2026-10-20T17:36:00+07:00")
        let start = try date("2026-10-20T19:15:00+07:00")
        XCTAssertEqual(MeetingBookingTime.blockReason(
            start: start, now: now, attendeeCount: 1, capacity: 0, calendar: calendar
        ), "Vượt sức chứa phòng (1/0 chỗ). Hãy bớt người được mời.")
    }

    func testBackToBackMeetingLeavesNoExtension() throws {
        let end = try date("2026-10-15T10:00:00+07:00")
        let earlier = try date("2026-10-15T09:00:00+07:00")
        let backToBack = try date("2026-10-15T10:00:00+07:00")
        let later = try date("2026-10-15T11:00:00+07:00")
        let next = MeetingExtension.nextStart(after: end, among: [later, earlier, backToBack])
        XCTAssertEqual(next, backToBack)
        XCTAssertEqual(MeetingExtension.maximumMinutes(end: end, nextStart: next), 0)
    }

    func testExtensionKeepsChangeoverAndTwoHourLimit() throws {
        let end = try date("2026-10-15T10:00:00+07:00")
        XCTAssertEqual(MeetingExtension.maximumMinutes(end: end, nextStart: try date("2026-10-15T10:30:00+07:00")), 25)
        XCTAssertEqual(MeetingExtension.maximumMinutes(end: end, nextStart: try date("2026-10-15T10:04:00+07:00")), 0)
        XCTAssertEqual(MeetingExtension.maximumMinutes(end: end, nextStart: try date("2026-10-15T15:00:00+07:00")), 120)
        XCTAssertEqual(MeetingExtension.maximumMinutes(end: end, nextStart: nil), 120)
        XCTAssertNil(MeetingExtension.nextStart(after: end, among: [try date("2026-10-15T09:00:00+07:00")]))
    }
}
