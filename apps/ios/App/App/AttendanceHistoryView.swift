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

struct ModernAttendanceHistoryView: View {
    private static let absentColor = Color(red: 0.78, green: 0.07, blue: 0.11)

    @Environment(\.sessionActions) private var actions
    /// Methods and non-published values only; observing the whole session
    /// redrew this screen on every unrelated session change.
    private var session: SessionStore { actions.store }
    @EnvironmentObject private var revisions: DataRevisions
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let initialMonth: String?
    let restrictToInitialMonth: Bool
    let releasedStatementMonths: [String]?
    @State private var selectedMonth: String
    @State private var cache: [String: AttendanceMonth] = [:]
    @State private var errors: [String: String] = [:]
    @State private var loadingMonths = Set<String>()
    @State private var monthIndex = 0
    @State private var releasedMonths = Set<String>()
    @State private var workMetricMonths = Set<String>()

    init(initialMonth: String? = nil, restrictToInitialMonth: Bool = false, releasedStatementMonths: [String]? = nil) {
        self.initialMonth = initialMonth
        self.restrictToInitialMonth = restrictToInitialMonth
        self.releasedStatementMonths = releasedStatementMonths
        _selectedMonth = State(initialValue: initialMonth ?? Self.monthValue(Date()))
    }

    var body: some View {
        GeometryReader { proxy in
            let useTwoPane = horizontalSizeClass == .regular && proxy.size.width >= 900
            VStack(spacing: 0) {
                if useTwoPane {
                    HStack(spacing: 12) {
                        ForEach(options.indices, id: \.self) { index in
                            VStack(spacing: 8) {
                                Text(monthTitle(for: options[index]))
                                    .font(.headline.bold())
                                    .foregroundStyle(Color.primary)
                                preloadedMonthPage(index)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(.horizontal, 12)
                } else {
                    monthNavigation.padding(.horizontal, 16).padding(.bottom, 8)
                    TabView(selection: $monthIndex) {
                        ForEach(options.indices, id: \.self) { index in
                            preloadedMonthPage(index)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .transaction { transaction in
                        // A simultaneous cell-height animation makes the
                        // cached page briefly shorter than its full grid.
                        transaction.animation = nil
                    }
                    .background {
                        if #available(iOS 18.0, *) {
                            AttendanceScrollInsetNeutralizer()
                        }
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        }
        .background(AppTheme.ink.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle("Lịch chấm công")
        .navigationBarTitleDisplayMode(.inline)
        .adaptivePortalTabBarBackground()
        .onChange(of: monthIndex) { _, newIndex in
            guard options.indices.contains(newIndex) else { return }
            selectedMonth = options[newIndex]
            UISelectionFeedbackGenerator().selectionChanged()
            if releasedStatementMonths != nil {
                Task { await preloadAdjacentMonths() }
            } else {
                Task { await preloadMonth(options[newIndex]) }
            }
        }
        .onChange(of: releasedMonths) { _, _ in
            // Adding months after a report refresh must not move the reader away
            // from the month that was opened through its notification.
            guard releasedStatementMonths != nil,
                  let index = options.firstIndex(of: selectedMonth) else { return }
            if monthIndex != index { monthIndex = index }
        }
        .task {
            // Hydrate the on-disk month snapshots before the first network await.
            // Previously the reports request ran first, so a perfectly valid
            // attendance cache still looked like a cold load on a slow network.
            hydrateCachedMonths()
            if let index = options.firstIndex(of: selectedMonth) {
                monthIndex = index
            } else if let first = options.first {
                selectedMonth = first
                monthIndex = 0
            }

            // Release metadata and attendance revalidation are independent.
            // Run them together while leaving cached calendar data visible.
            async let reportsTask = session.loadAttendanceReports()
            // Cache-first on a normal open: only stale months hit the network.
            // Realtime events below still force refresh after actual changes.
            await preloadAdjacentMonths()
            releasedMonths = Set((await reportsTask).map(\.month))
        }
        .task(id: revisions.attendance) {
            guard revisions.attendance > 0 else { return }
            // Keep the last rendered month visible while refreshing. Clearing
            // the in-memory cache here caused the page to flash a spinner and
            // made every realtime attendance event feel like a cold load.
            errors.removeAll()
            hydrateCachedMonths()
            async let reportsTask = session.loadAttendanceReports()
            await preloadAdjacentMonths(forceNetwork: true)
            releasedMonths = Set((await reportsTask).map(\.month))
        }
    }

    private func preloadedMonthPage(_ index: Int) -> some View {
        let month = options[index]
        // Read the persisted month during the first body evaluation. Waiting
        // for hydrateCachedMonths() in .task caused a brief loading view even
        // though the statement had already been cached on this device.
        let data = cache[month] ?? session.cachedAttendanceMonth(month)
        let showWorkMetrics = workMetricMonths.contains(month)
        let visibleReleasedMonths = releasedMonths.isEmpty
            ? Set(session.cachedAttendanceReports().map(\.month))
            : releasedMonths
        return ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                if let data {
                    preloadedSummaryCards(data, showWorkMetrics: showWorkMetrics)
                    preloadedCalendarCard(data, month: month, showWorkMetrics: showWorkMetrics)
                    if visibleReleasedMonths.contains(month) {
                        preloadedMonthlyDetails(data)
                    }
                } else if let message = errors[month] {
                    ContentUnavailableView {
                        Label("Không tải được bảng công", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Thử lại") {
                            errors.removeValue(forKey: month)
                            Task { await preloadMonth(month) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.red)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ProgressView("Đang tải tháng kế bên...")
                        .tint(AppTheme.red)
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 112)
        }
        .background {
            if #available(iOS 18.0, *) {
                AttendanceScrollInsetNeutralizer()
            }
        }
        .hidesPortalBottomScrollEdgeEffect()
    }

    @ViewBuilder
    private func preloadedSummaryCards(_ data: AttendanceMonth, showWorkMetrics: Bool) -> some View {
        if showWorkMetrics {
            HStack(spacing: 6) {
                metricSummary(
                    AttendanceMetrics.workDayTotalText(AttendanceMetrics.totalWorkDays(data)),
                    "Tổng ngày công",
                    .green
                )
                metricSummary(
                    AttendanceMetrics.hourText(
                        data.days.reduce(0) {
                            $0 + AttendanceMetrics.workMetrics($1, month: data).overtimeHours
                                + AttendanceMetrics.nightShiftOvertimeHours($1)
                        }
                    ),
                    "Tổng giờ tăng ca",
                    .orange
                )
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .dynamicTypeSize(.xSmall ... .accessibility1)
        } else {
            let values: [(String, Int, Color)] = [
                ("Đủ công", AttendanceMetrics.paidDayCount(data), Color(red: 22.0 / 255.0, green: 163.0 / 255.0, blue: 74.0 / 255.0)),
                ("Đi trễ", preloadedCount("late", in: data), Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 6.0 / 255.0)),
                ("Về sớm", preloadedCount("early", in: data), Color(red: 219.0 / 255.0, green: 39.0 / 255.0, blue: 119.0 / 255.0)),
                ("Quên chấm công", AttendanceMetrics.missingPunchCount(data), Color(red: 8.0 / 255.0, green: 145.0 / 255.0, blue: 178.0 / 255.0)),
                ("Xin nghỉ", preloadedCount("leave", in: data), Color(red: 37.0 / 255.0, green: 99.0 / 255.0, blue: 235.0 / 255.0)),
                ("Vắng", AttendanceMetrics.absenceCount(data), Self.absentColor),
                ("Làm chủ nhật", preloadedCount("overtime", in: data), Color(red: 124.0 / 255.0, green: 58.0 / 255.0, blue: 237.0 / 255.0)),
            ].filter { $0.1 > 0 }
            if !values.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                        summary(item.1, item.0, item.2)
                    }
                }
                // Size the row to its tallest cell so every cell matches it.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .dynamicTypeSize(.xSmall ... .accessibility1)
            }
        }
    }

    private func preloadedCalendarCard(
        _ data: AttendanceMonth,
        month: String,
        showWorkMetrics: Bool
    ) -> some View {
        let cellHeight: CGFloat = 80
        return VStack(alignment: .leading, spacing: 14) {
            Text(showWorkMetrics ? "Lịch chấm công · Hệ số công / Tăng ca" : "Lịch chấm công")
                .font(.headline)
                .foregroundStyle(Color.primary)
            HStack(spacing: 4) {
                ForEach(["T2", "T3", "T4", "T5", "T6", "T7", "CN"], id: \.self) {
                    Text($0).font(.caption.bold()).foregroundStyle(AppTheme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 7) {
                ForEach(0..<preloadedLeadingEmptyDays(data), id: \.self) { _ in
                    Color.clear.frame(height: cellHeight)
                }
                ForEach(data.days, id: \.id) { (day: AttendanceDay) in
                    PreloadedAttendanceDayCell(
                        day: day,
                        month: data,
                        showWorkMetrics: showWorkMetrics,
                        cellHeight: cellHeight
                    )
                }
            }
        }
        .padding(18)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            UISelectionFeedbackGenerator().selectionChanged()
            if workMetricMonths.contains(month) {
                workMetricMonths.remove(month)
            } else {
                workMetricMonths.insert(month)
            }
        }
    }

    private func preloadedCount(_ status: String, in data: AttendanceMonth) -> Int {
        data.days.filter { dayStatuses($0).contains(status) }.count
    }

    private func preloadedMonthlyDetails(_ data: AttendanceMonth) -> some View {
        let leave = data.leaveSummaryExact ?? data.leaveSummary
        let regularOvertime = AttendanceMetrics.regularOvertimeHours(data)
        let sundayOvertime = AttendanceMetrics.overtimeHours(for: "overtime", in: data)
        let holidayOvertime = AttendanceMetrics.overtimeHours(for: "holiday", in: data)
        let totalOvertime = regularOvertime + sundayOvertime + holidayOvertime
        let violations = AttendanceMetrics.violationCount(data)
        return VStack(alignment: .leading, spacing: 14) {
            attendanceReportCard(title: "Chi tiết công", icon: "doc.text.fill", color: AppTheme.red) {
                // Paid differently, so listed apart: day shift, night shift, night shift on Sunday.
                reportRow("Ngày công thường", "\(AttendanceMetrics.workDayTotalText(AttendanceMetrics.dayShiftWorkDays(data))) ngày", color: .blue)
                reportRow("Ngày công ca đêm thường", "\(AttendanceMetrics.workDayTotalText(AttendanceMetrics.nightShiftWorkdays(data, sunday: false))) ngày", color: .blue)
                reportRow("Ngày công ca đêm chủ nhật", "\(AttendanceMetrics.workDayTotalText(AttendanceMetrics.nightShiftWorkdays(data, sunday: true))) ngày", color: .blue)
            }
            attendanceReportCard(title: "Chi tiết tăng ca", icon: "clock.fill", color: .orange) {
                AttendanceOvertimeProgressRow(title: "Tăng ca thường", hours: regularOvertime, total: totalOvertime, color: .orange)
                AttendanceOvertimeProgressRow(title: "Tăng ca chủ nhật", hours: sundayOvertime, total: totalOvertime, color: .orange)
                AttendanceOvertimeProgressRow(title: "Tăng ca lễ", hours: holidayOvertime, total: totalOvertime, color: .orange)
                Divider()
                reportRow("Tổng tăng ca", "\(AttendanceMetrics.hourText(totalOvertime)) giờ", color: AppTheme.red, bold: true)
            }
            attendanceReportCard(title: "Tổng hợp ngày nghỉ", icon: "beach.umbrella.fill", color: .green) {
                reportRow("Tổng số phép còn trong tháng trước", "\(AttendanceMetrics.workDayTotalText(leave?.openingBalance ?? 0)) ngày", color: .green)
                reportRow("Số ngày phép được hưởng trong tháng", "\(AttendanceMetrics.workDayTotalText(leave?.accruedDays ?? 0)) ngày", color: .green)
                reportRow("Số ngày phép đã dùng trong tháng", "\(AttendanceMetrics.workDayTotalText(leave?.usedDays ?? 0)) ngày", color: .blue)
                reportRow("Số ngày nghỉ không lương trong tháng", "\(AttendanceMetrics.workDayTotalText(leave?.unpaidDays ?? 0)) ngày", color: .orange)
                reportRow("Số ngày nghỉ bệnh trong tháng", "\(AttendanceMetrics.workDayTotalText(leave?.sickDays ?? 0)) ngày", color: .blue)
                Divider()
                reportRow("Số phép còn lại trong tháng", "\(AttendanceMetrics.workDayTotalText(leave?.closingBalance ?? 0)) ngày", color: .green, bold: true)
            }
            attendanceReportCard(title: "Tổng hợp vi phạm", icon: "exclamationmark.triangle.fill", color: AppTheme.red) {
                reportRow("Tổng số lần quên chấm công / đi trễ / về sớm", "\(violations) lần", color: .orange, bold: true)
            }
            AttendanceCodeLegend()
        }
    }

    private func attendanceReportCard<Content: View>(title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .foregroundStyle(Color.primary)
            }
            .font(.headline)
            content()
        }
        .padding(18)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func reportRow(_ title: String, _ value: String, color: Color, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(bold ? .subheadline.bold() : .subheadline.weight(.semibold))
                .foregroundStyle(AttendanceReportValueStyle.hasData(value) ? color : Color.primary)
        }
    }

    private func preloadedLeadingEmptyDays(_ data: AttendanceMonth) -> Int {
        guard let value = data.days.first?.date, let date = Self.dayParser.date(from: value) else { return 0 }
        // The day key is a Vietnam date: read its weekday in Vietnam time, or
        // a device far from UTC+7 shifted the whole grid by a column.
        return (VietnamTime.calendar.component(.weekday, from: date) + 5) % 7
    }

    private func hydrateCachedMonths() {
        for month in options {
            guard cache[month] == nil,
                  let cached = session.cachedAttendanceMonth(month) else { continue }
            cache[month] = cached
        }
    }

    private func preloadMonth(_ month: String, forceNetwork: Bool = false) async {
        // Keep already-rendered data on screen while a refresh is in flight.
        // This mirrors Android: cache first, then revalidate without replacing
        // the calendar with a loading state.
        // A forced reload (realtime change) is never dropped because a load is
        // running: SessionStore re-runs a running request for it.
        guard forceNetwork || !loadingMonths.contains(month) else { return }
        loadingMonths.insert(month)
        defer { loadingMonths.remove(month) }

        if cache[month] == nil, let cached = session.cachedAttendanceMonth(month) {
            cache[month] = cached
        }

        guard forceNetwork || session.shouldRevalidateAttendanceMonth(month) else { return }
        guard let token = session.token else { return }
        do {
            let loaded = try await session.loadAttendanceMonth(month, token: token, force: forceNetwork)
            cache[month] = loaded
            errors.removeValue(forKey: month)
        } catch {
            // If cached data exists, keep it visible and do not replace the
            // whole month with an error state just because revalidation failed.
            if cache[month] == nil {
                errors[month] = error.localizedDescription
            }
        }
    }

    private func moveMonth(by offset: Int) {
        let target = monthIndex + offset
        guard options.indices.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            monthIndex = target
        }
    }

    private var monthNavigation: some View {
        HStack {
            monthButton("chevron.left", target: -1)
            Spacer()
            Text(monthTitle).font(.headline.bold()).foregroundStyle(Color.primary)
            Spacer()
            monthButton("chevron.right", target: 1)
        }
        .padding(12).background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func monthButton(_ icon: String, target offset: Int) -> some View {
        let index = options.firstIndex(of: selectedMonth) ?? 0
        let target = index + offset
        return Button {
            moveMonth(by: offset)
        } label: {
            Image(systemName: icon).font(.caption.bold())
                .foregroundStyle(Color.primary.opacity(0.78))
                .frame(width: 40, height: 40)
                .background(Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .disabled(!options.indices.contains(target))
        .opacity(options.indices.contains(target) ? 1 : 0.35)
    }

    private func summary(_ value: Int, _ label: String, _ color: Color) -> some View {
        summaryCell(Text("\(value)"), label, color)
    }

    private func metricSummary(_ value: String, _ label: String, _ color: Color) -> some View {
        summaryCell(Text(value), label, color)
    }

    /// A long label ("Quên chấm công") wraps to a second line instead of being
    /// cut off; the row stretches every cell to the tallest one so they stay even.
    /// Content is top-aligned so numbers and labels line up across cells.
    private func summaryCell(_ value: Text, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 5) {
            value.font(.title3.bold()).foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.vertical, 13)
        .background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 15))
    }

    private var options: [String] {
        if let releasedStatementMonths {
            // Published statements can be opened from a notification before the
            // reports list has been viewed. Merge the notification month with
            // cached and freshly fetched published months only.
            let cachedMonths = session.cachedAttendanceReports().map(\.month)
            return Array(Set(releasedStatementMonths)
                .union(cachedMonths)
                .union(releasedMonths)).sorted()
        }
        if restrictToInitialMonth, let initialMonth {
            return [initialMonth]
        }
        // The normal attendance screen intentionally exposes only this month
        // and the immediately previous month. Older released statements are
        // opened explicitly from "Bảng công" or from their notification.
        return (0..<2).compactMap {
            VietnamTime.calendar.date(byAdding: .month, value: -$0, to: Date())
        }.map(Self.monthValue).sorted()
    }
    private var monthTitle: String { monthTitle(for: selectedMonth) }

    private func monthTitle(for month: String) -> String {
        guard let date = Self.monthParser.date(from: month) else { return month }
        return VietnamTime.monthTitleSpaced.string(from: date)
    }
    private func dayStatuses(_ day: AttendanceDay) -> [String] {
        AttendanceMetrics.displayStatuses(day)
    }
    private func preloadAdjacentMonths(forceNetwork: Bool = false) async {
        // Always hydrate the visible month first. A missing neighbouring month
        // must never block it behind a slow or offline network request.
        let orderedMonths: [String]
        if releasedStatementMonths != nil, let index = options.firstIndex(of: selectedMonth) {
            // Published history can span years; revalidate only this page and
            // adjacent pages, then load more as the employee swipes.
            orderedMonths = [index, index - 1, index + 1]
                .filter { options.indices.contains($0) }
                .map { options[$0] }
        } else {
            orderedMonths = [selectedMonth] + options.filter { $0 != selectedMonth }
        }
        for month in orderedMonths {
            await preloadMonth(month, forceNetwork: forceNetwork)
        }
    }
    private static func monthValue(_ date: Date) -> String { VietnamTime.monthKey.string(from: date) }
    private static let monthParser = VietnamTime.monthKey
    private static let dayParser = VietnamTime.dayKey
}
