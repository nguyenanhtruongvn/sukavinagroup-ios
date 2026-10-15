import Foundation

/// The company time zone, calendar and the date formats the app shows.
///
/// Every date the user picks or reads is Vietnam time, whatever the device
/// time zone is (AGENTS.md). Formatters are expensive to create and safe to
/// share, so each format exists once. Mirrors Android `VietnamTime`.
///
/// Compiled into the app and the widget extension (widgets and Live
/// Activities), so this file may only depend on Foundation.
enum VietnamTime {
    static let timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    static let locale = Locale(identifier: "vi_VN")
    static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone
        value.locale = locale
        return value
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso8601Standard = ISO8601DateFormatter()

    /// Parses API timestamps with or without fractional seconds.
    static func date(fromISO8601 value: String) -> Date? {
        // Most API timestamps carry milliseconds; try the format that matches
        // first instead of parsing every string twice.
        value.contains(".")
            ? iso8601Fractional.date(from: value) ?? iso8601Standard.date(from: value)
            : iso8601Standard.date(from: value) ?? iso8601Fractional.date(from: value)
    }

    /// API timestamp for a date (UTC, the format the server expects).
    static func iso8601String(from date: Date) -> String {
        iso8601Standard.string(from: date)
    }

    private static func formatter(_ format: String, locale: Locale = VietnamTime.locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.dateFormat = format
        return formatter
    }

    /// 08:30
    static let clock = formatter("HH:mm")
    /// 14/10/2026
    static let shortDate = formatter("dd/MM/yyyy")
    /// 14/10/2026 08:30
    static let dateTime = formatter("dd/MM/yyyy HH:mm")
    /// 08:30 14/10/2026
    static let clockDate = formatter("HH:mm dd/MM/yyyy")
    /// 11/2026
    static let monthYear = formatter("MM/yyyy")
    /// 2026-10 (API month key)
    static let monthKey = formatter("yyyy-MM", locale: Locale(identifier: "en_US_POSIX"))
    /// 2026-10-14 (API day key)
    static let dayKey = formatter("yyyy-MM-dd", locale: Locale(identifier: "en_US_POSIX"))
    /// 08:30:15
    static let clockWithSeconds = formatter("HH:mm:ss")
    /// Thứ Tư, 14/10/2026
    static let weekdayDate = formatter("EEEE, dd/MM/yyyy")
    /// Thứ Tư, 14 tháng 10, 2026
    static let weekdayLongDate = formatter("EEEE, dd 'tháng' MM, yyyy")
    /// Thứ Tư, 14 tháng 10
    static let weekdayLongDayMonth = formatter("EEEE, dd 'tháng' MM")
    /// Tháng 10/2026
    static let monthTitle = formatter("'Tháng' M/yyyy")
    /// Tháng 10 / 2026
    static let monthTitleSpaced = formatter("'Tháng' M / yyyy")
    /// Tháng 10 • 2026 (widget header)
    static let monthTitleBullet = formatter("'Tháng' M • yyyy")
    /// System date/time styles (e.g. "14 thg 10, 2026, 08:30") in Vietnam time;
    /// `Date.formatted(date:time:)` would use the device time zone.
    static func format(_ value: Date, date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        value.formatted(Date.FormatStyle(date: date, time: time, locale: locale, calendar: calendar, timeZone: timeZone))
    }
    /// API schedule timestamps: "2026-10-14 08:30:00" or "2026-10-14 08:30".
    static let scheduleParsers = [
        formatter("yyyy-MM-dd HH:mm:ss", locale: Locale(identifier: "en_US_POSIX")),
        formatter("yyyy-MM-dd HH:mm", locale: Locale(identifier: "en_US_POSIX")),
    ]
}
