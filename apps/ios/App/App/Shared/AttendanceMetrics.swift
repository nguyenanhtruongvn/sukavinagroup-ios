import Foundation

// Monthly attendance as the API returns it, and the payroll arithmetic on it
// (workday coefficient, overtime, leave and violation counts) shown by the
// attendance calendar and statements. Foundation-only so it is unit-tested
// (SharedTests/AttendanceMetricsTests.swift).

struct AttendanceMonth: Codable {
    let month: String
    let startTime: String?
    let endTime: String?
    let department: String?
    let days: [AttendanceDay]
    let leaveSummary: AttendanceLeaveSummary?
    let leaveSummaryExact: AttendanceLeaveSummary?
}

struct AttendanceLeaveSummary: Codable {
    let openingBalance: Double
    let accruedDays: Double
    let usedDays: Double
    let unpaidDays: Double
    let sickDays: Double
    let closingBalance: Double
}

struct AttendanceDay: Codable, Identifiable {
    let date: String
    let checkIn: String?
    let checkOut: String?
    let classification: String?
    let punchCount: Int
    let status: String?
    let statuses: [String]?
    /// Company-wide day off; same leave accounting, not an employee request.
    var companyLeave: Bool? = nil
    let startTime: String?
    let endTime: String?
    let sources: [String]?
    let punches: [AttendancePunch]?
    // Additive API fields: old cached responses without them remain decodable.
    let workdayCode: String?
    let workdayFactor: Double?
    let overrideCode: String?
    // Ca đêm entered by an administrator, beside the day shift. workdayFactor
    // is the date's total and already includes nightShift.workdays.
    let nightShift: AttendanceNightShift?
    // Times adjusted by an administrator: checkIn/checkOut above already apply
    // them; overtimeHours is set when the administrator typed the overtime.
    let adjustment: AttendanceAdjustment?
    let overtimeHours: Double?
    var id: String { date }
}

struct AttendanceAdjustment: Codable {
    let checkIn: String?
    let checkOut: String?
    let overtimeHours: Double?
}

struct AttendanceNightShift: Codable {
    let workdays: Double
    let overtimeHours: Double
}

struct AttendancePunch: Codable, Identifiable {
    let id: String
    let punchedAt: String
    let source: String
    let machineNo: Int
}

struct AttendanceWorkMetrics {
    let coefficient: Double
    let overtimeHours: Double
}

enum AttendanceMetrics {
    private static var vietnamCalendar: Calendar { VietnamTime.calendar }
    // A public holiday takes precedence over Sunday. These categories are
    // mutually exclusive, so every minute is added to the monthly total once.
    private static func overtimeCategory(_ day: AttendanceDay) -> String {
        let values = statuses(day)
        if values.contains("holiday") { return "holiday" }
        // Parse the yyyy-MM-dd date with a Vietnam-timezone Calendar rather
        // than a shared mutable DateFormatter (safe under Swift 6 concurrency).
        let components = day.date.split(separator: "-").compactMap { Int($0) }
        let sunday: Bool
        if components.count == 3,
           let date = vietnamCalendar.date(from: DateComponents(
               year: components[0], month: components[1], day: components[2]
           )) {
            sunday = vietnamCalendar.component(.weekday, from: date) == 1
        } else {
            sunday = false
        }
        if sunday || values.contains("overtime") { return "sunday" }
        return "regular"
    }

    static func statuses(_ day: AttendanceDay) -> [String] {
        let serverStatuses = day.statuses ?? day.status.map { [$0] } ?? []
        let exemptStatuses: Set<String> = [
            "holiday", "office_day_off", "leave", "company_leave", "weekend",
            "overtime", "upcoming", "not-started", "absent",
        ]
        if serverStatuses.contains(where: { exemptStatuses.contains($0) }) {
            return serverStatuses
        }
        if day.checkIn == nil, day.checkOut != nil { return ["missing_checkin"] }
        if day.checkIn != nil, day.checkOut == nil { return ["missing_checkout"] }
        if day.classification == "ambiguous" { return ["incomplete"] }
        return serverStatuses
    }

    static func isUnfinishedToday(_ day: AttendanceDay) -> Bool {
        guard day.punchCount < 2 else { return false }
        let components = day.date.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3,
              let date = vietnamCalendar.date(from: DateComponents(
                  year: components[0], month: components[1], day: components[2]
              )) else { return false }
        return vietnamCalendar.isDateInToday(date)
    }

    static func displayStatuses(_ day: AttendanceDay) -> [String] {
        // Keep old wire statuses intact; never display a company-wide day off
        // as a personal "Xin nghỉ" or include it in personal-request counts.
        let values = day.companyLeave == true ? ["company_leave"] : statuses(day)
        let payrollException: Set<String> = ["holiday", "office_day_off", "leave", "company_leave", "weekend", "overtime"]
        if isUnfinishedToday(day), !values.contains(where: { payrollException.contains($0) }) {
            return ["pending"]
        }
        return values
    }

    // A calendar note is an attendance/payroll status, not proof of worked
    // hours. Keep notes visible without manufacturing 0/0 hour lines.
    // Presentation-only alias: preserve KCC in payroll/API records and caches.
    static func calendarDisplayCode(_ code: String) -> String {
        code == "KCC" ? "V" : code
    }

    static func calendarNote(_ day: AttendanceDay) -> String? {
        let values = displayStatuses(day)
        if let manual = day.overrideCode, !manual.isEmpty { return calendarDisplayCode(manual) }
        // CT is confirmed by an approved business-trip request, so it is
        // meaningful before the day starts or ends (unlike an automatic KCC).
        if day.workdayCode == "CT" { return "CT" }
        if values.contains("holiday") { return "NL" }
        if values.contains("office_day_off") { return "NVP" }
        // Do not show a stale KCC for a workday that has not yet ended.
        if values.contains("pending") { return nil }
        // Legacy leave status does not establish available paid-leave balance.
        if let code = day.workdayCode, !code.isEmpty, code != "1" { return calendarDisplayCode(code) }
        if isUnfinishedToday(day) { return nil }
        if values.contains("absent"), day.checkIn == nil, day.checkOut == nil {
            return "V"
        }
        return nil
    }

    // The standard calendar shows punch times when present. A day without
    // either punch has no times to show, so its recorded payroll/leave code is
    // displayed in both calendar modes.
    static func calendarDisplayNote(
        _ day: AttendanceDay, showWorkMetrics: Bool
    ) -> String? {
        let note = calendarNote(day)
        // CT marks a business trip only when there is no attendance on that
        // date. A recorded punch must keep the normal coefficient/overtime
        // display (or 0/0 when the punch pair is incomplete).
        if note == "CT", day.checkIn != nil || day.checkOut != nil { return nil }
        if let manual = day.overrideCode, !manual.isEmpty { return note }
        if showWorkMetrics || (day.checkIn == nil && day.checkOut == nil && note != nil) {
            return note
        }
        let values = displayStatuses(day)
        if values.contains("holiday") { return "NL" }
        if values.contains("office_day_off") { return "NVP" }
        return nil
    }

    static func hasCompletePunchPair(_ day: AttendanceDay) -> Bool {
        guard let start = instant(day.checkIn), let end = instant(day.checkOut) else {
            return false
        }
        return end > start
    }

    static func workMetrics(_ day: AttendanceDay, month: AttendanceMonth) -> AttendanceWorkMetrics {
        let start = scheduledDate(day.date, time: day.startTime ?? month.startTime)
        let end = scheduledDate(day.date, time: day.endTime ?? month.endTime)
        let checkIn = instant(day.checkIn)
        let checkOut = instant(day.checkOut)

        let scheduledMinutes: Int
        if let start, let end {
            scheduledMinutes = max(0, Int(end.timeIntervalSince(start) / 60))
        } else {
            scheduledMinutes = 0
        }
        let fullWorkMinutes = max(0, scheduledMinutes - (scheduledMinutes >= 8 * 60 ? 60 : 0))

        let latePenalty = positiveHalfHourPenalty(from: start, to: checkIn)
        let earlyPenalty = positiveHalfHourPenalty(from: checkOut, to: end)
        let recognizedMinutes: Int
        if checkIn == nil || checkOut == nil {
            recognizedMinutes = 0
        } else {
            recognizedMinutes = min(fullWorkMinutes, max(0, fullWorkMinutes - latePenalty - earlyPenalty))
        }

        let overtime = overtimeHours(
            day, defaultStartTime: month.startTime, defaultEndTime: month.endTime
        )
        // Sunday work only accrues overtime. A holiday remains a paid day
        // when nobody worked, but must not add a second workday when overtime
        // was recorded on that holiday.
        let category = overtimeCategory(day)
        let excludedFromWorkdays = category == "sunday" || (category == "holiday" && overtime > 0)
        let coefficient: Double
        if let verifiedFactor = dayShiftWorkdayFactor(day) {
            coefficient = verifiedFactor
        } else {
            coefficient = (fullWorkMinutes == 0 || excludedFromWorkdays)
                ? 0
                : Double(recognizedMinutes) / Double(fullWorkMinutes)
        }
        return AttendanceWorkMetrics(
            coefficient: coefficient,
            overtimeHours: overtime
        )
    }

    static func overtimeHours(
        _ day: AttendanceDay, defaultStartTime: String?, defaultEndTime: String?
    ) -> Double {
        // Overtime typed by an administrator wins over the hours from the times.
        if let typed = day.overtimeHours { return typed }
        // Two valid punches are required to recognize overtime.
        guard let checkIn = instant(day.checkIn),
              let checkOut = instant(day.checkOut),
              checkOut > checkIn else { return 0 }

        let minutes: Int
        if overtimeCategory(day) == "regular" {
            // Weekdays only count time after the employee's scheduled shift.
            guard let scheduledEnd = scheduledDate(day.date, time: day.endTime ?? defaultEndTime) else {
                return 0
            }
            minutes = max(0, Int(checkOut.timeIntervalSince(scheduledEnd) / 60))
        } else {
            // On Sunday/holidays overtime begins at the configured shift start
            // (employee override first, then department schedule), never at
            // an earlier check-in. A missing schedule must not create overtime.
            guard let scheduledStart = scheduledDate(day.date, time: day.startTime ?? defaultStartTime) else {
                return 0
            }
            let effectiveStart = max(checkIn, scheduledStart)
            let elapsed = max(0, Int(checkOut.timeIntervalSince(effectiveStart) / 60))
            minutes = max(0, elapsed - (elapsed >= 8 * 60 ? 60 : 0))
        }
        guard minutes >= 30 else { return 0 }
        return Double(minutes / 30) * 0.5
    }

    static func regularOvertimeHours(_ month: AttendanceMonth) -> Double {
        month.days
            .filter { overtimeCategory($0) == "regular" }
            .reduce(0) {
                $0 + overtimeHours($1, defaultStartTime: month.startTime, defaultEndTime: month.endTime)
                    + nightShiftOvertimeHours($1)
            }
    }

    static func overtimeHours(for status: String, in month: AttendanceMonth) -> Double {
        let category = status == "overtime" ? "sunday" : status
        return month.days
            .filter { overtimeCategory($0) == category }
            .reduce(0) {
                $0 + overtimeHours($1, defaultStartTime: month.startTime, defaultEndTime: month.endTime)
                    + nightShiftOvertimeHours($1)
            }
    }

    /// Night-shift overtime counts in the category of its date (weekday, Sunday, holiday).
    static func nightShiftOvertimeHours(_ day: AttendanceDay) -> Double {
        day.nightShift?.overtimeHours ?? 0
    }

    /// The day shift's own workday: the date's total minus the night shift.
    static func dayShiftWorkdayFactor(_ day: AttendanceDay) -> Double? {
        guard let total = day.workdayFactor else { return nil }
        return max(0, total - (day.nightShift?.workdays ?? 0))
    }

    /// Day-shift workdays ("ngày công thường"): the month total without night shifts.
    static func dayShiftWorkDays(_ month: AttendanceMonth) -> Double {
        max(0, totalWorkDays(month) - month.days.reduce(0) { $0 + ($1.nightShift?.workdays ?? 0) })
    }

    /// Night-shift workdays on Sundays, or on every other date.
    static func nightShiftWorkdays(_ month: AttendanceMonth, sunday: Bool) -> Double {
        month.days
            .filter { $0.nightShift != nil && (overtimeCategory($0) == "sunday") == sunday }
            .reduce(0) { $0 + ($1.nightShift?.workdays ?? 0) }
    }

    static func isPaidDay(_ day: AttendanceDay, month: AttendanceMonth) -> Bool {
        let values = statuses(day)
        let category = overtimeCategory(day)
        if category == "sunday" { return false }
        if category == "holiday",
           overtimeHours(
               day, defaultStartTime: month.startTime, defaultEndTime: month.endTime
           ) > 0 {
            return false
        }
        return values.contains("present")
            || values.contains("holiday")
            || values.contains("office_day_off")
    }

    static func totalWorkDays(_ month: AttendanceMonth) -> Double {
        month.days.reduce(0) { total, day in
            if let serverFactor = day.workdayFactor { return total + serverFactor }
            let values = statuses(day)
            if values.contains("holiday") || values.contains("office_day_off") {
                return total + (isPaidDay(day, month: month) ? 1 : 0)
            }
            return total + workMetrics(day, month: month).coefficient
        }
    }

    // "Đủ công" counts day shifts only: a night shift alone is not a full day-shift day.
    static func paidDayCount(_ month: AttendanceMonth) -> Int {
        month.days.filter {
            if let factor = dayShiftWorkdayFactor($0) { return factor >= 0.995 }
            return isPaidDay($0, month: month)
        }.count
    }

    static func missingPunchCount(_ month: AttendanceMonth) -> Int {
        month.days.filter { $0.punchCount == 1 && !isUnfinishedToday($0) }.count
    }

    static func absenceCount(_ month: AttendanceMonth) -> Int {
        month.days.filter { day in
            // An HR-confirmed absence (V) counts even when the day has stray punches.
            day.overrideCode == "V" ||
                (day.punchCount == 0 && statuses(day).contains("absent") && !isUnfinishedToday(day))
        }.count
    }

    static func violationCount(_ month: AttendanceMonth) -> Int {
        let dayStatuses = month.days.map { statuses($0) }
        return dayStatuses.filter { $0.contains("late") }.count
            + dayStatuses.filter { $0.contains("early") }.count
            + missingPunchCount(month)
    }

    static func hourText(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.005
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
    }

    static func workFactorText(_ value: Double) -> String {
        // Keep at most two decimals, with a dot and no unnecessary zeros.
        // The API already rounds each coefficient to two decimal places.
        var text = String(format: "%.2f", value).replacingOccurrences(of: ",", with: ".")
        while text.contains(".") && text.last == "0" {
            text.removeLast()
        }
        if text.last == "." { text.removeLast() }
        return text
    }

    static func workDayTotalText(_ value: Double) -> String {
        workFactorText(value)
    }

    static func monthTitle(_ month: String) -> String {
        guard let date = VietnamTime.monthKey.date(from: month) else { return month }
        return VietnamTime.monthTitle.string(from: date)
    }

    private static func instant(_ value: String?) -> Date? {
        guard let value else { return nil }
        return VietnamTime.date(fromISO8601: value)
    }

    private static func scheduledDate(_ day: String, time: String?) -> Date? {
        guard let time, !time.isEmpty else { return nil }
        for parser in VietnamTime.scheduleParsers {
            if let value = parser.date(from: "\(day) \(time)") { return value }
        }
        return nil
    }

    private static func positiveHalfHourPenalty(from start: Date?, to end: Date?) -> Int {
        guard let start, let end else { return 0 }
        let seconds = end.timeIntervalSince(start)
        guard seconds > 0 else { return 0 }
        return Int(ceil(seconds / 1_800)) * 30
    }
}
