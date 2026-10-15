import Foundation

/// Start-time rules for booking a room. Mirrors Android
/// `defaultBookingStart` / `bookingBlockReason` in MeetingBookingSheet.kt.
enum MeetingBookingTime {
    /// Start times move in 5-minute steps.
    static let minuteStep = 5

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
}
