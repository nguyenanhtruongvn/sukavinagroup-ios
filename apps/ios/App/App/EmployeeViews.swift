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

/// The signed-in portal on iOS 18+. iOS 17 never builds this view: just
/// instantiating it aborted in SwiftUI type-metadata construction there, so
/// AppDelegate hosts `LegacyEmployeePortalController` (UIKit tabs) instead.
/// Keep iOS 17 work out of this type; the availability makes the compiler
/// enforce that.
@available(iOS 18.0, *)
struct EmployeePortalView: View {
    @Environment(\.sessionActions) private var actions
    /// Methods and non-published values only; observing the whole session
    /// redrew this screen on every unrelated session change.
    private var session: SessionStore { actions.store }
    @EnvironmentObject private var badge: NotificationBadgeState
    @EnvironmentObject private var notificationRouter: APNsNotificationRouter
    @State private var selectedTab = 0
    @State private var requestInitialFilter: EmployeeRequestStatus?

    var body: some View {
        systemPortalTabs
            .accentColor(AppTheme.red)
            .onChange(of: selectedTab) { _, tab in
                if tab == 3 { session.clearNotificationBadge() }
            }
            .onChange(of: notificationRouter.pendingRoute) { _, route in
                if route != nil { selectedTab = 3 }
            }
    }

    private var systemPortalTabs: some View {
        // Keep every tab item structurally stable: never swap tab-label view types.
        TabView(selection: $selectedTab) {
            DashboardView(isActive: selectedTab == 0)
                .tabItem { Label("Trang chủ", systemImage: "house.fill") }
                .tag(0)
            RequestsView(initialFilter: requestInitialFilter)
                .tabItem { Label("Đơn từ", systemImage: "doc.text.fill") }
            .tag(1)
            MeetingRoomsView(isActive: selectedTab == 2)
                .tabItem { Label("Phòng họp", systemImage: "building.2.fill") }
                .tag(2)
            NotificationsView()
                .tabItem { Label("Thông báo", systemImage: "bell.fill") }
                .badge(badge.count)
                .tag(3)
            ProfileView()
                .tabItem { Label("Tài khoản", systemImage: "person.crop.circle.fill") }
            .tag(4)
        }
        .adaptivePortalTabBarBackground()
    }
}

/// A concrete view keeps the calendar's `ForEach` closure small enough for
/// Release builds on current Xcode toolchains to type-check reliably.
struct PreloadedAttendanceDayCell: View {
    private static let absentColor = Color(red: 211.0 / 255.0, green: 47.0 / 255.0, blue: 47.0 / 255.0)
    private static let lateColor = Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 6.0 / 255.0)
    private static let forgottenPunchColor = Color(red: 8.0 / 255.0, green: 145.0 / 255.0, blue: 178.0 / 255.0)
    private static let earlyColor = Color(red: 219.0 / 255.0, green: 39.0 / 255.0, blue: 119.0 / 255.0)
    private static let leaveColor = Color(red: 37.0 / 255.0, green: 99.0 / 255.0, blue: 235.0 / 255.0)
    private static let overtimeColor = Color(red: 124.0 / 255.0, green: 58.0 / 255.0, blue: 237.0 / 255.0)
    @Environment(\.colorScheme) private var colorScheme
    // Holiday is lime (distinct from purple overtime, blue leave and green present).
    private var holidayColor: Color {
        colorScheme == .dark
            ? Color(red: 183.0 / 255.0, green: 219.0 / 255.0, blue: 78.0 / 255.0)
            : Color(red: 85.0 / 255.0, green: 124.0 / 255.0, blue: 15.0 / 255.0)
    }

    let day: AttendanceDay
    let month: AttendanceMonth
    let showWorkMetrics: Bool
    let cellHeight: CGFloat

    var body: some View {
        let statuses = AttendanceMetrics.displayStatuses(day)
        let isHoliday = statuses.contains("holiday")
        let note = AttendanceMetrics.calendarDisplayNote(day, showWorkMetrics: showWorkMetrics)
        let hasCompletePunchPair = AttendanceMetrics.hasCompletePunchPair(day)
        let hasForgottenPunch = statuses.contains { ["missing_checkin", "missing_checkout", "incomplete"].contains($0) }
        let dayNumber = Int(day.date.suffix(2)) ?? 0
        // Once per cell: detail, split shifts and the label all need it.
        let metrics = AttendanceMetrics.workMetrics(day, month: month)

        return VStack(spacing: 6) {
            // Keep the date/detail blocks stable while distributing the spare
            // cell height evenly above and below them.
            Spacer(minLength: 0)
            Text(String(dayNumber))
                .font(.subheadline.weight(.medium))
                .frame(height: 20)
            shifts(
                note: note,
                isHoliday: isHoliday,
                hasCompletePunchPair: hasCompletePunchPair,
                hasForgottenPunch: hasForgottenPunch,
                metrics: metrics
            )
            Spacer(minLength: 0)
        }
        .foregroundStyle(note == nil && statuses.contains("absent") ? Self.absentColor : Color.primary)
        .frame(maxWidth: .infinity, minHeight: cellHeight)
        .background(background(for: statuses, note: note))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: dayNumber, note: note, statuses: statuses, hasCompletePunchPair: hasCompletePunchPair, hasForgottenPunch: hasForgottenPunch, metrics: metrics))
    }

    private func detail(
        note: String?,
        isHoliday: Bool,
        hasCompletePunchPair: Bool,
        hasForgottenPunch: Bool,
        metrics: AttendanceWorkMetrics
    ) -> AnyView {
        if let note {
            return AnyView(VStack(spacing: 0) {
                Text(note)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(noteColor(note))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(height: 18, alignment: .top)
                if isHoliday && showWorkMetrics && hasCompletePunchPair && metrics.overtimeHours > 0 {
                    Text(AttendanceMetrics.hourText(metrics.overtimeHours))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AppTheme.text(holidayColor))
                        .frame(height: 18, alignment: .top)
                } else {
                    Color.clear.frame(height: 18)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top))
        }
        if showWorkMetrics && hasCompletePunchPair {
            return AnyView(VStack(spacing: 0) {
                Text(AttendanceMetrics.workFactorText(metrics.coefficient))
                    .frame(height: 18, alignment: .top)
                Text(AttendanceMetrics.hourText(metrics.overtimeHours))
                    .frame(height: 18, alignment: .top)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.primary.opacity(0.72))
            .lineLimit(1)
            .minimumScaleFactor(0.7))
        }
        if showWorkMetrics && hasForgottenPunch {
            return AnyView(VStack(spacing: 0) {
                Text(AttendanceMetrics.workFactorText(0))
                    .frame(height: 18, alignment: .top)
                Text("0")
                    .frame(height: 18, alignment: .top)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.primary.opacity(0.72)))
        }
        if !showWorkMetrics {
            return AnyView(VStack(spacing: 0) {
                Text(time(day.checkIn))
                    .frame(height: 18, alignment: .top)
                Text(time(day.checkOut))
                    .frame(height: 18, alignment: .top)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.primary.opacity(0.72))
            .lineLimit(1)
            .minimumScaleFactor(0.7))
        }
        return AnyView(Color.clear)
    }

    /// The day shift, split vertically with ca đêm (right half) when the date has one.
    private func shifts(
        note: String?,
        isHoliday: Bool,
        hasCompletePunchPair: Bool,
        hasForgottenPunch: Bool,
        metrics: AttendanceWorkMetrics
    ) -> AnyView {
        let dayShift = detail(
            note: note,
            isHoliday: isHoliday,
            hasCompletePunchPair: hasCompletePunchPair,
            hasForgottenPunch: hasForgottenPunch,
            metrics: metrics
        )
        .frame(maxWidth: .infinity, minHeight: 37, maxHeight: 37, alignment: .top)
        guard let night = day.nightShift else { return AnyView(dayShift) }
        // Nothing to show for the day shift: the night shift alone is centred in
        // the cell like any other code, not squeezed into a half.
        if note == nil, day.checkIn == nil, day.checkOut == nil {
            return AnyView(nightShiftColumn(night, whole: true))
        }
        return splitShifts(
            night: night,
            note: note,
            isHoliday: isHoliday,
            hasCompletePunchPair: hasCompletePunchPair,
            hasForgottenPunch: hasForgottenPunch,
            metrics: metrics
        )
    }

    private struct SplitLine {
        let text: String
        let color: Color
        var size: CGFloat = 11.5
        var bold = false
    }

    /// A day with both shifts: two columns on the same 18 pt rows as every other
    /// cell, centred together with an even gap. In the metrics calendar ca đêm
    /// shows its workdays and overtime level with the day shift's; in the normal
    /// calendar "CĐ" sits on the first row, level with the check-in beside it.
    private func splitShifts(
        night: AttendanceNightShift,
        note: String?,
        isHoliday: Bool,
        hasCompletePunchPair: Bool,
        hasForgottenPunch: Bool,
        metrics: AttendanceWorkMetrics
    ) -> AnyView {
        let muted = Color.primary.opacity(0.72)
        let compact = !showWorkMetrics && note == nil
        var dayLines: [SplitLine] = []
        if let note {
            dayLines.append(SplitLine(text: note, color: noteColor(note), size: 11, bold: true))
            if isHoliday && showWorkMetrics && hasCompletePunchPair && metrics.overtimeHours > 0 {
                dayLines.append(SplitLine(text: AttendanceMetrics.hourText(metrics.overtimeHours), color: AppTheme.text(holidayColor)))
            }
        } else if showWorkMetrics && hasCompletePunchPair {
            dayLines = [
                SplitLine(text: AttendanceMetrics.workFactorText(metrics.coefficient), color: muted),
                SplitLine(text: AttendanceMetrics.hourText(metrics.overtimeHours), color: muted),
            ]
        } else if showWorkMetrics && hasForgottenPunch {
            dayLines = [
                SplitLine(text: AttendanceMetrics.workFactorText(0), color: muted),
                SplitLine(text: "0", color: muted),
            ]
        } else if !showWorkMetrics {
            // Times need the room: a slightly smaller size keeps "07:05 CĐ" inside the cell.
            dayLines = [
                SplitLine(text: time(day.checkIn), color: muted, size: 9.5),
                SplitLine(text: time(day.checkOut), color: muted, size: 9.5),
            ]
        }
        let nightColor = nightShiftColor()
        let nightLines: [SplitLine] = showWorkMetrics
            ? [
                SplitLine(text: AttendanceMetrics.workFactorText(night.workdays), color: nightColor),
                SplitLine(text: AttendanceMetrics.hourText(night.overtimeHours), color: nightColor),
            ]
            : [SplitLine(text: "CĐ", color: nightColor, size: compact ? 9.5 : 10.5, bold: true)]
        return AnyView(HStack(alignment: .top, spacing: compact ? 3 : 6) {
            splitColumn(dayLines, offset: 0)
            // "CĐ" on the first row, level with the check-in beside it.
            splitColumn(nightLines, offset: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 37, maxHeight: 37, alignment: .top))
    }

    private func splitColumn(_ lines: [SplitLine], offset: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(.system(size: line.size, weight: line.bold ? .heavy : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(line.color)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: 18, alignment: .top)
            }
        }
        .padding(.top, offset)
    }

    private func nightShiftColor() -> Color {
        colorScheme == .dark
            ? Color(red: 165.0 / 255.0, green: 180.0 / 255.0, blue: 252.0 / 255.0)
            : Color(red: 67.0 / 255.0, green: 56.0 / 255.0, blue: 202.0 / 255.0)
    }

    /// Ca đêm as the whole day, centred like any other code: "CĐ" on the first row
    /// in the normal calendar, its workdays and overtime in the metrics one.
    private func nightShiftColumn(_ night: AttendanceNightShift, whole: Bool) -> AnyView {
        let color = nightShiftColor()
        if showWorkMetrics {
            return AnyView(VStack(spacing: 0) {
                Text(AttendanceMetrics.workFactorText(night.workdays))
                    .frame(height: 18, alignment: .top)
                Text(AttendanceMetrics.hourText(night.overtimeHours))
                    .frame(height: 18, alignment: .top)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 37, maxHeight: 37, alignment: .top))
        }
        return AnyView(Text("CĐ")
            .font(.system(size: whole ? 11 : 10.5, weight: .heavy))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(color)
            .frame(height: whole ? 18 : nil, alignment: .top)
            .frame(maxWidth: .infinity, minHeight: 37, maxHeight: 37, alignment: whole ? .top : .center))
    }

    private func background(for statuses: [String], note: String?) -> AnyView {
        let coloredStatuses: Set<String> = [
            "present", "late", "early", "missing_checkin", "missing_checkout",
            "incomplete", "leave", "absent", "overtime"
        ]
        // Notes are distinguished by text accent, so every note keeps the
        // neutral cell surface, including the KCC absence code.
        guard note == nil else {
            return AnyView(AppTheme.muted.opacity(0.1))
        }
        if statuses.contains("late") && statuses.contains("early") {
            return AnyView(HStack(spacing: 0) {
                EmployeeRequestKind.late.color.opacity(0.34)
                EmployeeRequestKind.early.color.opacity(0.36)
            })
        }
        return AnyView(dayColor(statuses.first(where: { coloredStatuses.contains($0) })))
    }

    private func dayColor(_ status: String?) -> Color {
        switch status {
        case "present": return Color(red: 22.0 / 255.0, green: 163.0 / 255.0, blue: 74.0 / 255.0).opacity(0.32)
        case "missing_checkin", "missing_checkout", "incomplete": return Self.forgottenPunchColor.opacity(0.34)
        case "late": return Self.lateColor.opacity(0.34)
        case "early": return Self.earlyColor.opacity(0.36)
        case "leave": return Self.leaveColor.opacity(0.32)
        case "absent": return Self.absentColor.opacity(0.46)
        case "overtime": return Self.overtimeColor.opacity(0.36)
        default: return AppTheme.muted.opacity(0.1)
        }
    }

    private func noteColor(_ note: String) -> Color {
        switch note {
        case "NL": return holidayColor
        case "NVP": return Color(red: 15.0 / 255.0, green: 118.0 / 255.0, blue: 110.0 / 255.0)
        // V is the HR-confirmed form of an unexcused absence (KCC).
        case "KCC", "V": return Self.absentColor
        case "NTL": return Color(red: 194.0 / 255.0, green: 65.0 / 255.0, blue: 12.0 / 255.0)
        case "RO", "RO/2", "NP", "NP/2", "P/2": return Self.leaveColor
        case "CT": return Color(red: 3.0 / 255.0, green: 105.0 / 255.0, blue: 161.0 / 255.0)
        // CĐ (ca đêm): indigo, distinct from the sky-blue business trip CT.
        case "CĐ": return Color(red: 67.0 / 255.0, green: 56.0 / 255.0, blue: 202.0 / 255.0)
        // NN is vivid raspberry pink, distinct from purple overtime and green holiday.
        case "NN": return colorScheme == .dark
            ? Color(red: 244.0 / 255.0, green: 114.0 / 255.0, blue: 182.0 / 255.0)
            : Color(red: 190.0 / 255.0, green: 24.0 / 255.0, blue: 93.0 / 255.0)
        case "B": return Color(red: 161.0 / 255.0, green: 98.0 / 255.0, blue: 7.0 / 255.0)
        default: return Color(red: 71.0 / 255.0, green: 85.0 / 255.0, blue: 105.0 / 255.0)
        }
    }

    private func accessibilityLabel(
        for dayNumber: Int,
        note: String?,
        statuses: [String],
        hasCompletePunchPair: Bool,
        hasForgottenPunch: Bool,
        metrics: AttendanceWorkMetrics
    ) -> String {
        let dayLabel = dayAccessibilityLabel(
            for: dayNumber, note: note, statuses: statuses,
            hasCompletePunchPair: hasCompletePunchPair, hasForgottenPunch: hasForgottenPunch,
            metrics: metrics
        )
        guard let night = day.nightShift else { return dayLabel }
        return dayLabel + ". Ca đêm \(AttendanceMetrics.workFactorText(night.workdays)) công, "
            + "\(AttendanceMetrics.hourText(night.overtimeHours)) giờ tăng ca"
    }

    private func dayAccessibilityLabel(
        for dayNumber: Int,
        note: String?,
        statuses: [String],
        hasCompletePunchPair: Bool,
        hasForgottenPunch: Bool,
        metrics: AttendanceWorkMetrics
    ) -> String {
        if let note {
            let overtime = hasCompletePunchPair && statuses.contains("holiday") && showWorkMetrics
                ? metrics.overtimeHours : 0
            return "Ngày \(dayNumber). Mã công \(note)" + (overtime > 0
                ? ". Tăng ca \(AttendanceMetrics.hourText(overtime)) giờ" : "")
        }
        if !showWorkMetrics {
            return "Ngày \(dayNumber). Giờ vào \(time(day.checkIn)), giờ ra \(time(day.checkOut))"
        }
        if hasCompletePunchPair {
            return "Ngày \(dayNumber). Hệ số công \(AttendanceMetrics.workFactorText(metrics.coefficient)), tăng ca \(AttendanceMetrics.hourText(metrics.overtimeHours)) giờ"
        }
        if hasForgottenPunch {
            return "Ngày \(dayNumber). Hệ số công 0, tăng ca 0 giờ"
        }
        return "Ngày \(dayNumber). Không đủ cặp chấm công để tính giờ làm hoặc tăng ca"
    }

    private func time(_ value: String?) -> String {
        guard let value, let date = VietnamTime.date(fromISO8601: value) else { return "--:--" }
        return VietnamTime.clock.string(from: date)
    }
}

struct DashboardView: View {
    // Observes HomeState (today's punches, AI setting) and the menu only;
    // observing the whole session redrew Home on every unrelated change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @EnvironmentObject private var home: HomeState
    @EnvironmentObject private var menuStore: MenuStore
    @State private var showTodayMenu = false
    @State private var showAttendanceHistory = false
    @State private var showAttendanceStatement = false
    @State private var showAiAssistant = false
    @State private var showAiAssistantLaunchLabel = true
    @State private var hasScheduledAiAssistantLaunchLabel = false
    let isActive: Bool

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    PortalPageTitle("Trang chủ")

                    // A "Bảng lương" tile sat here with no destination. Placeholder
                    // features read as broken and App Review 2.1 rejects them, so
                    // it returns with the payslip feature itself.
                    Button {
                        showAttendanceStatement = true
                    } label: {
                        AttendanceStatementShortcut()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Xem bảng công")

                    NavigationLink(
                        destination: ModernAttendanceHistoryView()
                            .onAppear { showAttendanceHistory = true }
                            .onDisappear { showAttendanceHistory = false }
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Chấm công hôm nay").font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(AppTheme.red)
                            }
                            Divider().overlay(AppTheme.cardBorder)
                            HStack(spacing: 0) {
                                attendanceMetric(title: "Giờ vào", value: checkInTime, color: .green)
                                Divider().frame(height: 38).overlay(AppTheme.cardBorder)
                                attendanceMetric(title: "Giờ ra", value: checkOutTime, color: AppTheme.red)
                            }
                        }
                        .padding(16)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        // After a failed load the card retries instead of
                        // opening an empty menu.
                        if menuStore.todayMenu == nil, menuStore.loadError != nil {
                            Task { await session.refreshTodayMenu(force: true) }
                        } else {
                            showTodayMenu = true
                        }
                    } label: {
                        todayMenuCard
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Xem thực đơn hôm nay")

                }
                .padding(20)
                .padding(.bottom, 92)
            }
            .hidesPortalBottomScrollEdgeEffect()
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .task { await session.refreshTodayMenu() }
            // Realtime events and app activation keep the dashboard current.
            // Do not poll while the user scrolls: replacing card data during a
            // pull gesture makes SwiftUI's List visibly jump.
            .task(id: isActive) {
                guard isActive else { return }
                // Realtime events deliver changes; selecting the tab only
                // needs data that is recent enough.
                await session.ensureDashboardFresh()
            }
                .scrollIndicators(.hidden)
            .refreshable {
                await session.refreshDashboard()
                await session.refreshTodayMenu(force: true)
            }
            .overlay(alignment: .bottomTrailing) {
                if isActive &&
                    !showAttendanceHistory &&
                    !showAttendanceStatement &&
                    !showTodayMenu &&
                    home.aiAssistantEnabled {
                    Button {
                        showAiAssistant = true
                    } label: {
                        Group {
                            if showAiAssistantLaunchLabel {
                                HStack(spacing: 9) {
                                    AiAssistantOrbView(size: 34)
                                    Text("Trợ lý AI")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 54)
                                .background(
                                    Color(red: 32 / 255, green: 36 / 255, blue: 49 / 255),
                                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                                )
                                .transition(
                                    .scale(scale: 0.92)
                                    .combined(with: .opacity)
                                )
                            } else {
                                AiAssistantOrbView(size: 66)
                                    .contentShape(Circle())
                                    .transition(
                                        .scale(scale: 0.90)
                                        .combined(with: .opacity)
                                    )
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .padding(.bottom, 82)
                    .accessibilityLabel("Mở Trợ lý AI")
                }
            }
            .animation(.easeInOut(duration: 0.24), value: showAiAssistantLaunchLabel)
            .animation(.easeInOut(duration: 0.20), value: home.aiAssistantEnabled)
            .sheet(isPresented: $showTodayMenu) {
                TodayMenuView()
                    .sessionEnvironment(session)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .navigationDestination(isPresented: $showAttendanceStatement) {
                AttendanceStatementListView()
            }
        }
        .sheet(isPresented: $showAiAssistant) {
            AiAssistantChatView()
                .sessionEnvironment(session)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .task(id: isActive) {
            guard isActive, !hasScheduledAiAssistantLaunchLabel else { return }
            hasScheduledAiAssistantLaunchLabel = true
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation(.easeInOut(duration: 0.24)) {
                showAiAssistantLaunchLabel = false
            }
        }
        .onChange(of: home.aiAssistantEnabled) { _, enabled in
            if !enabled { showAiAssistant = false }
        }
    }

    @ViewBuilder
    private func attendanceMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(AppTheme.muted)
            Text(value).font(.title3.bold()).foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private var todayMenuCard: some View {
        let menu = menuStore.todayMenu
        let mainDishes = [menu?.day.savoryMain, menu?.day.savorySide, menu?.day.vegetable, menu?.day.soup]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let vegetarianDishes = [menu?.day.vegetarianMain, menu?.day.vegetarianSide]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 38, height: 38)
                    .background(Color.orange.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Thực đơn hôm nay")
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.muted)
            }

            Divider().overlay(Color.primary.opacity(0.07))

            if menu == nil, menuStore.loadError != nil {
                HStack(spacing: 9) {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(AppTheme.muted)
                    Text("Không tải được thực đơn.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                    Spacer(minLength: 0)
                    Text("Thử lại")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.redText)
                }
            } else if menu == nil {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Đang tải thực đơn hôm nay…")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                }
            } else {
                menuSummaryLine("Món chính", detail: mainDishes.isEmpty ? "Đang cập nhật" : mainDishes, color: .orange)
                if !vegetarianDishes.isEmpty {
                    menuSummaryLine("Món chay", detail: vegetarianDishes, color: .green)
                }
                if let featured = menu?.day.featured, !featured.isEmpty {
                    menuSummaryLine("Món nước", detail: featured, color: .cyan)
                }
                if let overtime = menu?.day.overtime, !overtime.isEmpty {
                    menuSummaryLine("Tăng ca", detail: overtime, color: .purple)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func menuSummaryLine(_ title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.muted)
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
            }
        }
    }

    private func attendanceTime(_ value: String) -> String {
        guard let date = VietnamTime.date(fromISO8601: value) else { return value }
        return VietnamTime.clockWithSeconds.string(from: date)
    }

    private var checkInTime: String {
        guard let value = home.summary.checkIn else { return "--:--" }
        return attendanceTime(value)
    }

    private var checkOutTime: String {
        guard let value = home.summary.checkOut else { return "--:--" }
        return attendanceTime(value)
    }
}

/// Home shortcut to the monthly attendance statement. Mirrors Android.
struct AttendanceStatementShortcut: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.red)
                .frame(width: 40, height: 40)
                .background(AppTheme.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Bảng công")
                .font(.headline)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.muted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
