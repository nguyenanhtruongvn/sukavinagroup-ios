import Foundation

/// A room's status for one day: "Đang họp đến …", "Trống đến …" or
/// "Còn trống cả ngày". The iOS 18+ SwiftUI card and the iOS 17 UIKit card
/// computed this separately (and had started to differ); both use this now.
enum MeetingRoomAvailability: Equatable {
    case busy(until: Date)
    case freeUntil(Date)
    case freeAllDay

    var isAvailable: Bool {
        if case .busy = self { return false }
        return true
    }

    /// `meetings`: start and end of the room's bookings (other days are
    /// ignored). On another
    /// day the next meeting counts from that day's start, not from `day`'s
    /// time of day.
    static func status(
        meetings: [(start: Date, end: Date)],
        day: Date,
        now: Date,
        calendar: Calendar
    ) -> MeetingRoomAvailability {
        // Only `day`'s bookings: the UIKit card filtered them and the SwiftUI
        // card did not, so another day's booking could change its text.
        let meetings = meetings.filter { calendar.isDate($0.start, inSameDayAs: day) }
        let isToday = calendar.isDate(day, inSameDayAs: now)
        if isToday, let current = meetings.first(where: { now >= $0.start && now < $0.end }) {
            return .busy(until: current.end)
        }
        let point = isToday ? now : calendar.startOfDay(for: day)
        if let next = meetings.map(\.start).filter({ $0 > point }).min() {
            return .freeUntil(next)
        }
        return .freeAllDay
    }

    /// The card's status line, times in `clock` (Vietnam "HH:mm").
    func text(clock: DateFormatter) -> String {
        switch self {
        case .busy(let until): return "Đang họp đến \(clock.string(from: until))"
        case .freeUntil(let start): return "Trống đến \(clock.string(from: start))"
        case .freeAllDay: return "Còn trống cả ngày"
        }
    }
}
