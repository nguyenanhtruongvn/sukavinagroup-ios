import Foundation

// Non-UI rules of the request composer, shared by the iOS 18+ SwiftUI
// `RequestComposer` and the iOS 17 UIKit `LegacyRequestComposerController`.
// Both UIs stay (iOS 17 crashed building the SwiftUI composer); the rules are
// one copy here, unit-tested, so the two can no longer drift apart. They had:
// different validation order and rules, overtime durations (47 min became 30
// on iOS 17, 45 on iOS 18) and business fields sent with every request kind.

/// The request kinds as the form rules see them (`EmployeeRequestKind` in the
/// app maps to this; same raw values as the API).
enum RequestFormKind: String {
    case leave, late, early, overtime, business, attendance, gate, sunday

    /// Đi trễ, Về sớm and Làm thêm giờ are entered as a duration.
    var usesDuration: Bool { self == .late || self == .early || self == .overtime }
}

/// Someone a manager can create the request for (`ManagedRequestEmployee`).
protocol RequestRecipient {
    var id: String { get }
    var fullName: String { get }
    var isSelf: Bool { get }
}

enum RequestFormRules {
    // MARK: Durations

    /// 5 minutes to 23 giờ 55 phút, in 5-minute steps (`DurationClock`).
    static let durationRange = 5...1435
    static let durationStep = 5
    static let defaultDurationMinutes = 30

    /// A typed duration, or nil when it is not a whole number on the step
    /// within the range.
    static func validDuration(_ raw: Double?) -> Int? {
        guard let raw, raw == raw.rounded() else { return nil }
        let minutes = Int(raw)
        guard durationRange.contains(minutes), minutes.isMultiple(of: durationStep) else { return nil }
        return minutes
    }

    /// The overtime length between two picker times, snapped to the step and
    /// kept within the range.
    static func overtimeMinutes(from start: Date, to end: Date) -> Int {
        let raw = Int(end.timeIntervalSince(start) / 60)
        let snapped = Int((Double(raw) / Double(durationStep)).rounded()) * durationStep
        return min(max(snapped, durationRange.lowerBound), durationRange.upperBound)
    }

    /// Overtime after the start picker moved: the end follows so the request
    /// keeps a valid, stepped length.
    static func overtimeAfterStartChange(start: Date, end: Date, minutes: Int) -> (start: Date, end: Date, minutes: Int) {
        let minutes = start < end ? overtimeMinutes(from: start, to: end) : minutes
        return (start, start.addingTimeInterval(TimeInterval(minutes * 60)), minutes)
    }

    /// Overtime after the end picker moved; an end before the start moves
    /// the start back by the current length.
    static func overtimeAfterEndChange(start: Date, end: Date, minutes: Int) -> (start: Date, end: Date, minutes: Int) {
        guard end > start else {
            return (end.addingTimeInterval(TimeInterval(-minutes * 60)), end, minutes)
        }
        let minutes = overtimeMinutes(from: start, to: end)
        return (start, start.addingTimeInterval(TimeInterval(minutes * 60)), minutes)
    }

    // MARK: Shift times and dates

    /// The shift's "HH:mm" on `date`, or the fallback time when missing/invalid.
    static func shiftTime(_ value: String?, on date: Date, fallbackHour: Int, fallbackMinute: Int, calendar: Calendar) -> Date {
        let parts = value?.split(separator: ":").compactMap { Int($0) } ?? []
        let hour = parts.count == 2 && (0...23).contains(parts[0]) ? parts[0] : fallbackHour
        let minute = parts.count == 2 && (0...59).contains(parts[1]) ? parts[1] : fallbackMinute
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    static func shiftStart(_ workStart: String?, on date: Date, calendar: Calendar) -> Date {
        shiftTime(workStart, on: date, fallbackHour: 7, fallbackMinute: 30, calendar: calendar)
    }

    static func shiftEnd(_ workEnd: String?, on date: Date, calendar: Calendar) -> Date {
        shiftTime(workEnd, on: date, fallbackHour: 16, fallbackMinute: 30, calendar: calendar)
    }

    /// Today when it is a Sunday, otherwise the next Sunday.
    static func nextSunday(from now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let daysToSunday = (8 - calendar.component(.weekday, from: today)) % 7
        return calendar.date(byAdding: .day, value: daysToSunday, to: today) ?? today
    }

    /// The times a newly chosen kind starts from, or nil to keep the current
    /// ones. `durationMinutes` is set for the duration kinds.
    static func defaults(
        for kind: RequestFormKind, now: Date, currentStart: Date,
        workStart: String?, workEnd: String?, calendar: Calendar
    ) -> (start: Date, end: Date, durationMinutes: Int?)? {
        switch kind {
        case .business, .gate:
            return (now, now.addingTimeInterval(60 * 60), nil)
        case .sunday:
            let sunday = nextSunday(from: now, calendar: calendar)
            return (shiftStart(workStart, on: sunday, calendar: calendar), shiftEnd(workEnd, on: sunday, calendar: calendar), nil)
        case .leave:
            let day = calendar.startOfDay(for: currentStart)
            return (shiftStart(workStart, on: day, calendar: calendar), shiftEnd(workEnd, on: day, calendar: calendar), nil)
        case .late, .early:
            let day = calendar.startOfDay(for: now)
            return (day, day.addingTimeInterval(TimeInterval(defaultDurationMinutes * 60)), defaultDurationMinutes)
        case .overtime:
            let start = shiftEnd(workEnd, on: now, calendar: calendar)
            return (start, start.addingTimeInterval(TimeInterval(defaultDurationMinutes * 60)), defaultDurationMinutes)
        case .attendance:
            return nil
        }
    }

    /// The times actually sent: Đi trễ starts at the shift start of `day`,
    /// Về sớm ends at its shift end; other kinds use the pickers.
    static func submissionDates(
        kind: RequestFormKind, start: Date, end: Date, day: Date, durationMinutes: Int,
        workStart: String?, workEnd: String?, calendar: Calendar
    ) -> (start: Date, end: Date) {
        let day = calendar.startOfDay(for: day)
        switch kind {
        case .late:
            let shiftStart = shiftStart(workStart, on: day, calendar: calendar)
            return (shiftStart, shiftStart.addingTimeInterval(TimeInterval(durationMinutes * 60)))
        case .early:
            let shiftEnd = shiftEnd(workEnd, on: day, calendar: calendar)
            return (shiftEnd.addingTimeInterval(TimeInterval(-durationMinutes * 60)), shiftEnd)
        default:
            return (start, end)
        }
    }

    // MARK: Text

    /// `.decimalPad` follows the device locale, so Vietnamese keyboards enter ",".
    static func decimal(_ text: String?) -> Double? {
        Double((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }

    /// 12 -> "12", 12.5 -> "12.5" for the numeric text fields.
    static func numberText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    /// "Đi trễ: 30 phút. <reason>", which `RequestReasonPrefill` reads back.
    static func durationReason(kindTitle: String, minutes: Int, reason: String) -> String {
        "\(kindTitle): \(DurationClock.title(minutes: minutes)). \(reason)"
    }

    // MARK: Validation

    struct Draft {
        var kind: RequestFormKind
        var reason: String
        var destination: String
        var transport: String
        var distanceText: String
        /// The typed or picked duration (duration kinds only).
        var durationMinutesText: Double?
        /// The times as they will be sent (`submissionDates`).
        var start: Date
        var end: Date
        var recipientsLoaded: Bool
        var selectedRecipientCount: Int
        /// The user's own pending or approved overtime requests (Làm thêm
        /// giờ and Làm chủ nhật), for the overlap warning.
        var existingOvertime: [ExistingOvertime] = []
        /// The request is created for the user (alone or with reports).
        var includesSelf = true
    }

    /// A pending or approved overtime request the new one may not overlap.
    struct ExistingOvertime: Equatable {
        var start: Date
        var end: Date
        var approved: Bool
    }

    /// The first existing request that shares time with start..end. Touching
    /// intervals (one ends as the next starts) do not overlap: the server
    /// applies the same rule and rejects the request otherwise.
    static func overlappingOvertime(start: Date, end: Date, existing: [ExistingOvertime]) -> ExistingOvertime? {
        existing
            .filter { $0.start < end && $0.end > start }
            .min { $0.start < $1.start }
    }

    /// The server's wording, shown before sending instead of after.
    static func overtimeOverlapMessage(_ request: ExistingOvertime) -> String {
        let start = VietnamTime.dateTime.string(from: request.start)
        let end = VietnamTime.dateTime.string(from: request.end)
        let status = request.approved ? "đã duyệt" : "đang chờ duyệt"
        return "Khung giờ làm thêm bị trùng với đơn \(start) – \(end) (\(status)). Vui lòng chọn khung giờ khác."
    }

    /// What still blocks "Gửi đơn", or nil. One order on both iOS versions
    /// (the Android order, plus the iOS 17 duration and overtime checks).
    static func missingRequirement(_ draft: Draft, calendar: Calendar) -> String? {
        if draft.kind == .business {
            if draft.destination.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                return "Nhập nơi công tác để gửi đơn."
            }
            if draft.transport == "personal_vehicle" && !((decimal(draft.distanceText) ?? 0) > 0) {
                return "Nhập quãng đường khi đi bằng xe cá nhân."
            }
        }
        if draft.kind == .sunday && calendar.component(.weekday, from: draft.start) != 1 {
            return "Ngày bắt đầu phải là Chủ nhật."
        }
        if draft.recipientsLoaded && draft.selectedRecipientCount == 0 {
            return "Chọn ít nhất một người tạo đơn."
        }
        if (draft.kind == .sunday || draft.kind == .overtime) && draft.end <= draft.start {
            return "Giờ kết thúc phải sau giờ bắt đầu."
        }
        // Before the reason check: the time is what has to change.
        if (draft.kind == .sunday || draft.kind == .overtime) && draft.includesSelf,
           let clash = overlappingOvertime(start: draft.start, end: draft.end, existing: draft.existingOvertime) {
            return overtimeOverlapMessage(clash)
        }
        if draft.kind.usesDuration && validDuration(draft.durationMinutesText) == nil {
            return "Thời lượng phải từ 5 phút đến 23 giờ 55 phút, theo bước 5 phút."
        }
        if draft.reason.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 {
            return "Nội dung đơn cần tối thiểu 10 ký tự."
        }
        if draft.end < draft.start { return "Thời gian kết thúc phải sau thời gian bắt đầu." }
        return nil
    }

    // MARK: Payload

    /// The business fields sent with a request: only a Công tác request
    /// carries them (iOS 18 used to send a transport for every kind).
    static func businessFields(
        kind: RequestFormKind, destination: String, transport: String,
        distanceText: String, lunchMeal: Bool, dinnerMeal: Bool
    ) -> (destination: String?, transport: String?, distanceKm: Double?, lunchMeal: Bool?, dinnerMeal: Bool?) {
        guard kind == .business else { return (nil, nil, nil, nil, nil) }
        return (
            destination.trimmingCharacters(in: .whitespacesAndNewlines),
            transport,
            decimal(distanceText),
            lunchMeal,
            dinnerMeal
        )
    }

    // MARK: Recipients

    /// "Tôi", "Tất cả", "Chưa chọn người" or the chosen names. Before the
    /// selection is initialised an empty one still reads "Tôi".
    static func recipientSummary<Person: RequestRecipient>(
        employees: [Person], selected: Set<String>, loaded: Bool, initialized: Bool
    ) -> String {
        guard loaded else { return "Tôi" }
        let chosen = employees.filter { selected.contains($0.id) }
        if chosen.isEmpty { return initialized ? "Chưa chọn người" : "Tôi" }
        if chosen.count == 1 && chosen[0].isSelf { return "Tôi" }
        let all = Set(employees.map(\.id))
        if chosen.count > 1 && !all.isEmpty && selected.isSuperset(of: all) { return "Tất cả" }
        return chosen.map { $0.isSelf ? "Tôi" : $0.fullName }.joined(separator: ", ")
    }

    /// Tapping a direct report: the first one replaces the default "Tôi",
    /// later ones join the request; tapping a chosen one removes it.
    static func toggle<Person: RequestRecipient>(
        _ id: String, employees: [Person], selected: Set<String>, hasChosenManagedEmployee: Bool
    ) -> (selected: Set<String>, hasChosenManagedEmployee: Bool) {
        var selected = selected
        guard let selfID = employees.first(where: \.isSelf)?.id else {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            return (selected, hasChosenManagedEmployee)
        }
        if selected.contains(id) {
            selected.remove(id)
            return (selected, hasChosenManagedEmployee)
        }
        if !hasChosenManagedEmployee && selected == [selfID] {
            return ([id], true)
        }
        selected.insert(id)
        return (selected, true)
    }
}
