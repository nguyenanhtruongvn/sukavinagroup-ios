import UIKit
import SwiftUI
import Combine
import Security
import UserNotifications
import Network
import LocalAuthentication
import WidgetKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import WebKit
import UniformTypeIdentifiers

struct AttendanceWorkMetrics {
    let coefficient: Double
    let overtimeHours: Double
}

// Only non-zero numeric quantities and their units receive an accent.
// The string values here are formatted locally as "0 ngày", "1.5 giờ", etc.
enum AttendanceReportValueStyle {
    static func hasData(_ value: String) -> Bool {
        guard let first = value.split(separator: " ").first,
              let amount = Double(String(first).replacingOccurrences(of: ",", with: ".")) else {
            return false
        }
        return abs(amount) > 0.000_001
    }
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
            "holiday", "office_day_off", "leave", "weekend",
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
        let values = statuses(day)
        let payrollException: Set<String> = ["holiday", "office_day_off", "leave", "weekend", "overtime"]
        if isUnfinishedToday(day), !values.contains(where: { payrollException.contains($0) }) {
            return ["pending"]
        }
        return values
    }

    // A calendar note is an attendance/payroll status, not proof of worked
    // hours. Keep notes visible without manufacturing 0/0 hour lines.
    static func calendarNote(_ day: AttendanceDay) -> String? {
        let values = displayStatuses(day)
        if let manual = day.overrideCode, !manual.isEmpty { return manual }
        // CT is confirmed by an approved business-trip request, so it is
        // meaningful before the day starts or ends (unlike an automatic KCC).
        if day.workdayCode == "CT" { return "CT" }
        if values.contains("holiday") { return "NL" }
        if values.contains("office_day_off") { return "NVP" }
        // Do not show a stale KCC for a workday that has not yet ended.
        if values.contains("pending") { return nil }
        // Legacy leave status does not establish available paid-leave balance.
        if let code = day.workdayCode, !code.isEmpty, code != "1" { return code }
        if isUnfinishedToday(day) { return nil }
        if values.contains("absent"), day.checkIn == nil, day.checkOut == nil {
            return "KCC"
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
        let excludedFromWorkdays = overtimeCategory(day) == "sunday"
            || (overtimeCategory(day) == "holiday" && overtime > 0)
        let coefficient: Double
        if let verifiedFactor = day.workdayFactor {
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
            .reduce(0) { $0 + overtimeHours($1, defaultStartTime: month.startTime, defaultEndTime: month.endTime) }
    }

    static func overtimeHours(for status: String, in month: AttendanceMonth) -> Double {
        let category = status == "overtime" ? "sunday" : status
        return month.days
            .filter { overtimeCategory($0) == category }
            .reduce(0) { $0 + overtimeHours($1, defaultStartTime: month.startTime, defaultEndTime: month.endTime) }
    }

    static func isPaidDay(_ day: AttendanceDay, month: AttendanceMonth) -> Bool {
        let values = statuses(day)
        if overtimeCategory(day) == "sunday" { return false }
        if overtimeCategory(day) == "holiday",
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

    static func paidDayCount(_ month: AttendanceMonth) -> Int {
        month.days.filter {
            if let factor = $0.workdayFactor { return factor >= 0.995 }
            return isPaidDay($0, month: month)
        }.count
    }

    static func missingPunchCount(_ month: AttendanceMonth) -> Int {
        month.days.filter { $0.punchCount == 1 && !isUnfinishedToday($0) }.count
    }

    static func absenceCount(_ month: AttendanceMonth) -> Int {
        month.days.filter { day in
            day.punchCount == 0 && statuses(day).contains("absent") && !isUnfinishedToday(day)
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

struct AttendanceStatementListView: View {
    @Environment(\.sessionActions) private var actions
    /// Methods and non-published values only; observing the whole session
    /// redrew this screen on every unrelated session change.
    private var session: SessionStore { actions.store }
    @EnvironmentObject private var revisions: DataRevisions
    @State private var reports: [AttendanceReport] = []
    @State private var isLoading = true

    var body: some View {
        // Read the persisted snapshot during the first body evaluation, before
        // SwiftUI starts the asynchronous refresh task. This avoids a visible
        // loading flash when the employee has already opened this screen.
        let displayedReports = reports.isEmpty ? session.cachedAttendanceReports() : reports
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                if isLoading && displayedReports.isEmpty {
                    ProgressView("Đang tải bảng công...")
                        .tint(AppTheme.red)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if displayedReports.isEmpty {
                    ContentUnavailableView(
                        "Chưa có bảng công",
                        systemImage: "calendar.badge.clock",
                        description: Text("Bảng công đã phát hành sẽ hiển thị tại đây.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(displayedReports.sorted { $0.month > $1.month }) { report in
                        NavigationLink(destination: ModernAttendanceHistoryView(initialMonth: report.month, releasedStatementMonths: displayedReports.map(\.month))) {
                            HStack(spacing: 14) {
                                Image(systemName: "calendar")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(AppTheme.red)
                                    .frame(width: 42, height: 42)
                                    .background(AppTheme.red.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(AttendanceMetrics.monthTitle(report.month))
                                    .font(.headline)
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppTheme.muted)
                            }
                            .padding(17)
                            .background(AppTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppTheme.ink.ignoresSafeArea())
        .navigationTitle("Bảng công")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: revisions.attendance) {
            let cached = session.cachedAttendanceReports()
            if !cached.isEmpty {
                reports = cached
            }
            isLoading = reports.isEmpty
            let refreshed = await session.loadAttendanceReports()
            if !refreshed.isEmpty || reports.isEmpty {
                reports = refreshed
            }
            isLoading = false
        }
    }
}

// The overtime bar and its numeric value use the same accent.
struct AttendanceOvertimeProgressRow: View {
    let title: String
    let hours: Double
    let total: Double
    let color: Color

    private var fraction: CGFloat {
        guard total > 0, hours > 0 else { return 0 }
        return CGFloat(min(1, max(0, hours / total)))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .frame(width: 116, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.18))
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            Text("\(AttendanceMetrics.hourText(hours)) giờ")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(hours > 0 ? color : Color.primary)
                .frame(minWidth: 51, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct AttendanceCodeLegend: View {
    // Shared across current attendance and released monthly statements.
    // Explanations reflect the HR-approved meaning of each payroll code.
    private static let notes: [(code: String, meaning: String)] = [
        ("1", "Làm đủ 1 ngày công 8h"),
        ("NP/2", "Nửa ngày công, nửa ngày hưởng lương phép năm"),
        ("RO", "Nghỉ có xin phép không hưởng lương"),
        ("RO/2", "Nửa ngày công, nửa ngày có xin phép và không hưởng lương"),
        ("B", "Nghỉ bệnh hưởng lương BHXH chi trả"),
        ("NP", "Nghỉ phép hưởng lương phép năm"),
        ("P/2", "Nghỉ cả ngày có đơn, 0,5 ngày hưởng phép năm, 0,5 ngày không lương"),
        ("NTL", "Nghỉ trừ lương (do nhân sự xác nhận)"),
        ("CT", "Công tác"),
        ("NN", "Ngày nghỉ (nghỉ hưởng chế độ, nghỉ bù)"),
        ("NVP", "Nghỉ văn phòng"),
        ("KCC", "Không chấm công"),
        ("NL", "Nghỉ lễ")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Ghi chú:")
                .font(.subheadline.bold())
                .italic()
                .foregroundStyle(Color.primary)

            ForEach(Self.notes.indices, id: \.self) { index in
                (Text("\(Self.notes[index].code): ").bold()
                 + Text(Self.notes[index].meaning).italic())
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(
                        "\(Self.notes[index].code): \(Self.notes[index].meaning)"
                    )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
