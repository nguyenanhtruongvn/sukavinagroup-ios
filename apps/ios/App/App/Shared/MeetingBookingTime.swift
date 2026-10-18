import Foundation

/// A length of time chosen with Apple's compact time picker, its hours and
/// minutes read as a duration ("01:30" is 1 giờ 30 phút), so it opens the
/// same bubble as a start time. Used by the booking's Thời lượng and by the
/// Đi trễ / Về sớm / Làm thêm giờ requests.
enum DurationClock {
    /// The picker's time for `minutes`, on a fixed day; only its hour and
    /// minute mean anything.
    static func date(forMinutes minutes: Int, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.date(byAdding: .minute, value: minutes, to: day) ?? day
    }

    /// The duration a picker time stands for, on `step` and within `range`.
    static func minutes(from date: Date, step: Int, range: ClosedRange<Int>, calendar: Calendar) -> Int {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (time.hour ?? 0) * 60 + (time.minute ?? 0)
        let stepped = Int((Double(minutes) / Double(step)).rounded()) * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// "45 phút", "1 giờ", "1 giờ 30 phút".
    static func title(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) phút" }
        if rest == 0 { return "\(hours) giờ" }
        return "\(hours) giờ \(rest) phút"
    }
}

/// Start-time rules for booking a room. Mirrors Android
/// `defaultBookingStart` / `bookingBlockReason` in MeetingBookingSheet.kt.
enum MeetingBookingTime {
    /// Start times move in 5-minute steps.
    static let minuteStep = 5

    /// How long a booking can last, in minutes: 5 minutes to 8 hours, in
    /// steps of `minuteStep` (`DurationClock`).
    static let durationRange = 5...480

    /// The current Vietnam time of day rounded up to the next 5-minute mark
    /// (09:07 -> 09:10), placed on `day`. Never rolls past 23:55.
    static func defaultStart(on day: Date, now: Date, calendar: Calendar) -> Date {
        let minuteNow = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        let minute = calendar.component(.minute, from: minuteNow)
        let roundUp = (minuteStep - minute % minuteStep) % minuteStep
        let rounded = calendar.date(byAdding: .minute, value: roundUp, to: minuteNow) ?? minuteNow
        let time = calendar.isDate(rounded, inSameDayAs: minuteNow)
            ? calendar.dateComponents([.hour, .minute], from: rounded)
            : DateComponents(hour: 23, minute: 60 - minuteStep)
        return calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    /// Why the booking cannot be confirmed yet, or nil when it can.
    static func blockReason(start: Date, now: Date, attendeeCount: Int, capacity: Int, calendar: Calendar) -> String? {
        let minuteNow = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        if start < minuteNow {
            return "Giờ bắt đầu đã qua. Hãy chọn giờ muộn hơn."
        }
        if attendeeCount > capacity {
            return "Vượt sức chứa phòng (\(attendeeCount)/\(capacity) chỗ). Hãy bớt người được mời."
        }
        return nil
    }

    /// The moments after `now` when a room's "Trống" / "Đang họp" status can
    /// change: every booking start or end, plus the next midnight (the day
    /// rolls over). Screens refresh exactly then instead of every minute.
    static func statusChangeTimes(after now: Date, boundaries: [Date], calendar: Calendar) -> [Date] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        return Array(Set(boundaries.filter { $0 > now && $0 < tomorrow } + [tomorrow])).sorted()
    }
}

/// How far the organiser can extend an active meeting: in 5-minute steps, at
/// most two hours, keeping five minutes free before the room's next booking.
/// Shared by the booking detail, the meeting notification and the iOS 17
/// UIKit detail so all three offer the same limit.
enum MeetingExtension {
    static let step = 5
    static let limitMinutes = 120
    static let changeoverMinutes = 5

    /// The first of `starts` at or after `end`. A meeting that begins exactly
    /// when this one ends counts: it leaves no room to extend.
    static func nextStart(after end: Date, among starts: [Date]) -> Date? {
        starts.filter { $0 >= end }.min()
    }

    /// Minutes that can still be added to a meeting ending at `end`.
    static func maximumMinutes(end: Date, nextStart: Date?) -> Int {
        guard let nextStart else { return limitMinutes }
        let free = Int(nextStart.timeIntervalSince(end) / 60) - changeoverMinutes
        return min(limitMinutes, max(0, free))
    }
}
