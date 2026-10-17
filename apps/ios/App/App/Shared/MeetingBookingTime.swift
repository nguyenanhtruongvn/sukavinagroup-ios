import Foundation

/// Start-time rules for booking a room. Mirrors Android
/// `defaultBookingStart` / `bookingBlockReason` in MeetingBookingSheet.kt.
enum MeetingBookingTime {
    /// Start times move in 5-minute steps.
    static let minuteStep = 5

    /// How long a booking can last, in minutes: 5 minutes to 8 hours, in
    /// steps of `minuteStep`.
    static let durationRange = 5...480

    /// The duration is chosen with Apple's compact time picker, its hours
    /// and minutes read as a length of time ("01:30" is 1 giờ 30 phút), so
    /// it opens the same bubble as Bắt đầu. The picker's time sits on this
    /// fixed day; only its hour and minute mean anything.
    static func clockDate(forDuration minutes: Int, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.date(byAdding: .minute, value: minutes, to: day) ?? day
    }

    /// The duration a picker time stands for, on `minuteStep` and within
    /// `durationRange`.
    static func durationMinutes(fromClock date: Date, calendar: Calendar) -> Int {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (time.hour ?? 0) * 60 + (time.minute ?? 0)
        let stepped = Int((Double(minutes) / Double(minuteStep)).rounded()) * minuteStep
        return min(max(stepped, durationRange.lowerBound), durationRange.upperBound)
    }

    /// "45 phút", "1 giờ", "1 giờ 30 phút".
    static func durationTitle(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) phút" }
        if rest == 0 { return "\(hours) giờ" }
        return "\(hours) giờ \(rest) phút"
    }

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
