import UIKit
import SwiftUI
import Security
import UserNotifications
import Network
import LocalAuthentication
import WidgetKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import WebKit

struct RequestNotification: Codable, Identifiable, Equatable {
    let id: String
    let type: String
    let title: String
    let message: String
    let requestId: String?
    let read: Bool
    let createdAt: Date
    let startsAt: Date? = nil
    let endsAt: Date? = nil
}

extension RequestNotification {
    /// The organiser's "ending in 10 minutes" reminder. One rule for the list
    /// and the detail (each had its own copy); the title check is kept for
    /// reminders that do not carry the meeting_ending_soon type.
    var isMeetingEndingSoon: Bool {
        type == "meeting_ending_soon" || title.hasPrefix("Còn 10 phút")
    }

    /// Opens the meeting detail rather than a request.
    var isMeeting: Bool { type.hasPrefix("meeting_") || isMeetingEndingSoon }
}
struct UpdateCount: Decodable { let count: Int }

struct NotificationsView: View {
    // Observes InboxState (news, unread state, request notifications), not
    // the whole session, which redrew this list on every unrelated change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @EnvironmentObject private var inbox: InboxState
    @EnvironmentObject private var notificationRouter: APNsNotificationRouter
    // Shared with the Requests tab: one cache decode and one request per refresh.
    @EnvironmentObject private var requestStore: EmployeeRequestStore
    @EnvironmentObject private var revisions: DataRevisions
    @State private var requestNotifications: [RequestNotification] = []
    @State private var reviewing: EmployeeRequest?
    @State private var viewing: EmployeeRequest?
    /// Chosen in the request detail; the composer opens once that sheet closes.
    @State private var pendingResubmit: EmployeeRequest?
    @State private var resubmitting: EmployeeRequest?
    @State private var meetingNotification: RequestNotification?
    @State private var attendanceReportMonth: String?
    @State private var confirmClear = false
    @State private var hiddenArticleIDs = Set<String>()
    @State private var reloadAgain = false
    @State private var reloadAgainWithDashboard = false
    @State private var isReloadingNotifications = false
    private var items: [ContentItem] { inbox.articles.filter { !hiddenArticleIDs.contains($0.id) } }
    private var inboxRequestNotifications: [RequestNotification] {
        requestNotifications.filter { !session.isAttendanceNotificationType($0.type) }
    }
    private var totalUnread: Int { inbox.unreadCount + inboxRequestNotifications.filter { !$0.read }.count }
    private var notificationCornerRadius: CGFloat {
        if #available(iOS 26.0, *) { return 20 }
        return 0
    }
    private var notificationRowInsets: EdgeInsets {
        if #available(iOS 26.0, *) {
            return EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        }
        return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    }
    var body: some View {
        NavigationStack {
            List {
                    ForEach(inboxRequestNotifications) { item in
                        Button { Task { await open(item) } } label: {
                          HStack(alignment: .top, spacing: 14) {
                            Image(systemName: notificationIcon(item)).frame(width: 44, height: 44).background(notificationColor(item).opacity(0.16)).foregroundStyle(notificationColor(item)).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.headline)
                                if let request = linkedRequest(item) {
                                    Text(request.kind.title).font(.caption.bold()).foregroundStyle(request.kind.color).padding(.horizontal, 9).padding(.vertical, 4).background(request.kind.color.opacity(0.13)).clipShape(Capsule())
                                }
                                let startsAt = linkedRequest(item)?.from ?? item.startsAt
                                let endsAt = linkedRequest(item)?.to ?? item.endsAt
                                if item.type.hasPrefix("request_") && (startsAt != nil || endsAt != nil) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        if let startsAt { Text("Từ: \(startsAt.requestDateTimeText)") }
                                        if let endsAt { Text("Đến: \(endsAt.requestDateTimeText)") }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                                }
                                Text(item.message).font(.subheadline).foregroundStyle(AppTheme.muted)
                                Text(VietnamTime.dateTime.string(from: item.createdAt)).font(.caption).foregroundStyle(AppTheme.redText)
                            }
                            Spacer()
                            if !item.read {
                                Text("Mới")
                                    .font(.caption2.bold())
                                    .foregroundStyle(notificationColor(item))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(notificationColor(item).opacity(0.18))
                                    .clipShape(Capsule())
                            }
                          }
                          .padding(16)
                          .background { requestNotificationBackground(item) }
                          .shadow(color: Color.black.opacity(0.035), radius: 5, y: 2)
                          .clipShape(RoundedRectangle(cornerRadius: notificationCornerRadius, style: .continuous))
                          .overlay(alignment: .bottom) { legacyNotificationSeparator }
                        }.buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await deleteNotification(item) }
                            } label: {
                                Image(systemName: "trash.fill")
                                    .accessibilityLabel("Xóa")
                            }
                        }
                        .listRowBackground(notificationPageBackground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(notificationRowInsets)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let isUnread = inbox.unreadArticleIDs.contains(item.id)
                        NavigationLink(destination: ArticleDetailView(item: item)) {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "megaphone.fill").frame(width: 44, height: 44).background(AppTheme.red.opacity(0.16)).foregroundStyle(AppTheme.red).clipShape(RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title).font(.headline).multilineTextAlignment(.leading)
                                    Text(item.preview).font(.subheadline).foregroundStyle(AppTheme.muted).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(VietnamTime.dateTime.string(from: item.createdAt)).font(.caption).foregroundStyle(AppTheme.redText)
                                }
                                Spacer(minLength: 0)
                                if isUnread {
                                    Text("Mới")
                                        .font(.caption2.bold())
                                        .foregroundStyle(AppTheme.redText)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(AppTheme.red.opacity(0.18))
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(16)
                            .background { articleNotificationBackground(isUnread: isUnread) }
                            .shadow(color: Color.black.opacity(0.035), radius: 5, y: 2)
                            .clipShape(RoundedRectangle(cornerRadius: notificationCornerRadius, style: .continuous))
                            .overlay(alignment: .bottom) { legacyNotificationSeparator }
                        }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { session.markArticleRead(item.id) })
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                hideArticle(item)
                            } label: {
                                Image(systemName: "trash.fill")
                                    .accessibilityLabel("Xóa")
                            }
                        }
                        .listRowBackground(notificationPageBackground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(notificationRowInsets)
                    }
                    if items.isEmpty && inboxRequestNotifications.isEmpty {
                        ContentUnavailableView("Chưa có thông báo", systemImage: "bell.slash")
                            .listRowBackground(notificationPageBackground)
                            .listRowSeparator(.hidden)
                    }
                    Color.clear
                        .frame(height: 112)
                        .listRowBackground(notificationPageBackground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .accessibilityHidden(true)
            }
            .listStyle(.plain)
            .contentMargins(.top, 4, for: .scrollContent)
            // Title, unread count and "Xóa tất cả" stay put; only the
            // notifications scroll.
            .safeAreaInset(edge: .top, spacing: 0) {
                PortalPinnedHeader("Thông báo", background: notificationPageBackground) {
                    HStack {
                        Text(totalUnread == 0 ? "Bạn đã đọc tất cả thông báo" : "\(totalUnread) thông báo chưa đọc").font(.subheadline.bold())
                        Spacer()
                        if !inboxRequestNotifications.isEmpty || !items.isEmpty { Button("Xóa tất cả", role: .destructive) { confirmClear = true }.font(.subheadline.bold()) }
                    }
                }
            }
            .hidesPortalBottomScrollEdgeEffect()
            .scrollContentBackground(.hidden)
            .background(notificationPageBackground.ignoresSafeArea()).navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
                .refreshable { await reloadNotifications(refreshDashboard: true) }
                .task {
                    hiddenArticleIDs = session.hiddenArticleIDs()
                    requestNotifications = session.cachedRequestNotifications()
                    requestStore.restoreCache(employeeCode: session.profile?.employeeCode ?? session.dashboard?.employeeCode)
                    await reloadNotifications()
                    await openPendingAPNsRouteIfNeeded()
                }
                .onAppear { Task { await openPendingAPNsRouteIfNeeded() } }
                .onChange(of: revisions.attendance) { _, _ in Task { await reloadNotifications() } }
                // Request, meeting and inbox events (a decision, an invitation,
                // a read on another device) are fetched once by SessionStore,
                // for the badge; this list mirrors that result instead of
                // requesting the same notifications a second time.
                .onChange(of: inbox.requestNotifications) { _, values in
                    if requestNotifications != values { requestNotifications = values }
                }
                .onChange(of: notificationRouter.pendingRoute) { _, _ in
                    Task { await openPendingAPNsRouteIfNeeded() }
                }
                .sheet(item: $reviewing) { request in RequestDecisionView(request: request) { approved, note in await requestStore.decide(token: session.token, id: request.id, approved: approved, note: note) } }
                .sheet(item: $viewing, onDismiss: {
                    resubmitting = pendingResubmit
                    pendingResubmit = nil
                }) { request in
                    RequestNotificationDetail(
                        request: request,
                        onResubmit: requestStore.canResubmit(request) ? { pendingResubmit = request } : nil
                    )
                }
                .sheet(item: $resubmitting) { request in
                    RequestComposer(template: request) { kind, from, to, reason, destination, transport, distance, expense in
                        await requestStore.submit(token: session.token, kind: kind, from: from, to: to, reason: reason, destination: destination, transport: transport, distanceKm: distance, expense: expense)
                    }
                    .presentationDetents([.large])
                    .presentationContentInteraction(.resizes)
                    .presentationDragIndicator(.hidden)
                }
                .sheet(item: $meetingNotification) { notification in MeetingNotificationDetail(notification: notification) }
                .sheet(
                    isPresented: Binding(
                        get: { attendanceReportMonth != nil },
                        set: { if !$0 { attendanceReportMonth = nil } }
                    )
                ) {
                    if let month = attendanceReportMonth {
                        NavigationStack {
                            // The notification selects its month, but the statement pager
                            // can also browse other published months from cache/API.
                            ModernAttendanceHistoryView(initialMonth: month, releasedStatementMonths: [month])
                                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { attendanceReportMonth = nil } } }
                        }
                    }
                }
        }
        // Use the system confirmation UI: the iOS 26+ action sheet and the
        // compatible alert presentation on earlier iOS releases.
        .confirmationDialog(
            "Xóa tất cả thông báo?",
            isPresented: Binding(
                get: { isIOS26OrLater && confirmClear },
                set: { confirmClear = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("Xóa tất cả", role: .destructive) { Task { await clearAll() } }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Tất cả thông báo trong danh sách sẽ bị xóa.")
        }
        .alert(
            "Xóa tất cả thông báo?",
            isPresented: Binding(
                get: { !isIOS26OrLater && confirmClear },
                set: { confirmClear = $0 }
            )
        ) {
            Button("Hủy", role: .cancel) {}
            Button("Xóa tất cả", role: .destructive) { Task { await clearAll() } }
        } message: {
            Text("Tất cả thông báo trong danh sách sẽ bị xóa.")
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func loadRequestNotifications() async {
        guard let token = session.token else { return }
        if let merged = await session.loadRequestNotifications(force: true) {
            if requestNotifications != merged {
                requestNotifications = merged
            }
            await requestStore.load(token)
        }
    }

    /// A List refresh keeps its scroll position stable only while its backing
    /// data is replaced once, so overlapping reloads are not run in parallel.
    /// They are not dropped either (a change announced meanwhile would be
    /// lost): one more pass runs when the current one ends.
    private func reloadNotifications(refreshDashboard: Bool = false) async {
        if isReloadingNotifications {
            reloadAgain = true
            reloadAgainWithDashboard = reloadAgainWithDashboard || refreshDashboard
            return
        }
        isReloadingNotifications = true
        defer { isReloadingNotifications = false }
        var withDashboard = refreshDashboard
        repeat {
            reloadAgain = false
            if withDashboard {
                await session.refreshDashboard(shouldRefreshRequestNotificationCount: false)
            }
            await loadRequestNotifications()
            withDashboard = reloadAgainWithDashboard
            reloadAgainWithDashboard = false
        } while reloadAgain
    }

    private func open(_ item: RequestNotification) async {
        if item.type == "attendance_monthly_report",
           let month = item.requestId,
           month.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil {
            attendanceReportMonth = month
            markReadOptimistically(item)
            Task {
                guard let token = session.token else { return }
                let _: UpdateCount? = try? await APIClient.shared.request(
                    "me/requests/notifications/\(item.id)/read",
                    method: "PATCH",
                    token: token
                )
                await reloadNotifications()
            }
            return
        }

        let isMeetingNotification = item.isMeeting

        // Meeting notifications should open immediately. Previously the sheet
        // waited for the read PATCH round-trip before appearing, which made a
        // cached notification still feel slow.
        if isMeetingNotification {
            meetingNotification = item
            markReadOptimistically(item)

            Task {
                guard let token = session.token else { return }
                let _: UpdateCount? = try? await APIClient.shared.request(
                    "me/requests/notifications/\(item.id)/read",
                    method: "PATCH",
                    token: token
                )
                await reloadNotifications()
            }
            return
        }

        // Requests open at once from the cached list, like meetings; the read
        // mark and a fresh load run behind the sheet. It used to wait for
        // both round trips first. A request that is not cached yet (or an
        // approval not yet in the cached approvals) opens once loaded.
        markReadOptimistically(item)
        let opened = presentRequest(for: item, allowViewingPending: false)
        Task {
            guard let token = session.token else { return }
            let _: UpdateCount? = try? await APIClient.shared.request(
                "me/requests/notifications/\(item.id)/read",
                method: "PATCH",
                token: token
            )
            await requestStore.load(token, force: true)
            if !opened, viewing == nil, reviewing == nil, meetingNotification == nil {
                presentRequest(for: item, allowViewingPending: true)
            }
            await reloadNotifications()
        }
    }

    /// Opens the review sheet for a pending approval, otherwise the request's
    /// detail. `allowViewingPending` false keeps an approval notification
    /// from opening as a plain detail before the approvals are loaded.
    @discardableResult
    private func presentRequest(for item: RequestNotification, allowViewingPending: Bool) -> Bool {
        guard let id = item.requestId else { return false }
        if item.type == "request_pending" {
            if let request = requestStore.approvals.first(where: { $0.id == id && $0.status == .pending }) {
                reviewing = request
                return true
            }
            guard allowViewingPending else { return false }
        }
        guard let request = requestStore.request(id: id) else { return false }
        viewing = request
        return true
    }

    private func markReadOptimistically(_ item: RequestNotification) {
        guard !item.read else { return }
        requestNotifications = requestNotifications.map { current in
            guard current.id == item.id else { return current }
            return RequestNotification(
                id: current.id,
                type: current.type,
                title: current.title,
                message: current.message,
                requestId: current.requestId,
                read: true,
                createdAt: current.createdAt
            )
        }
        session.updateRequestUnreadCount(requestNotifications)
    }

    private func openPendingAPNsRouteIfNeeded() async {
        guard let route = notificationRouter.pendingRoute, session.token != nil else { return }
        if route.type == "attendance_monthly_report",
           let month = route.referenceID,
           month.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil {
            attendanceReportMonth = month
            notificationRouter.consume(route)
            return
        }
        if session.isAttendanceNotificationType(route.type) {
            notificationRouter.consume(route)
            return
        }
        if requestNotifications.isEmpty { await reloadNotifications() }
        guard let item = requestNotifications.first(where: {
            guard $0.type == route.type else { return false }
            return route.referenceID == nil || $0.requestId == route.referenceID
        }) else { return }
        notificationRouter.consume(route)
        await open(item)
    }

    private var isIOS26OrLater: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private func clearAll() async {
        guard let token = session.token else { return }
        let _: UpdateCount? = try? await APIClient.shared.request("me/requests/notifications", method: "DELETE", token: token)
        hiddenArticleIDs.formUnion(items.map(\.id)); session.saveHiddenArticleIDs(hiddenArticleIDs)
        session.markArticlesRead(); await reloadNotifications()
    }

    private func deleteNotification(_ item: RequestNotification) async {
        guard let token = session.token else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            requestNotifications.removeAll { $0.id == item.id }
        }
        session.updateRequestUnreadCount(requestNotifications)
        let _: UpdateCount? = try? await APIClient.shared.request(
            "me/requests/notifications/\(item.id)", method: "DELETE", token: token
        )
    }

    private func hideArticle(_ item: ContentItem) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.28)) {
            _ = hiddenArticleIDs.insert(item.id)
        }
        session.saveHiddenArticleIDs(hiddenArticleIDs)
    }

    private func linkedRequest(_ item: RequestNotification) -> EmployeeRequest? {
        guard let id = item.requestId else { return nil }
        return requestStore.request(id: id)
    }
    private func notificationIcon(_ item: RequestNotification) -> String {
        let type = item.type
        if type == "meeting_room_booking" { return "building.2.badge.plus" }
        if type == "meeting_invite" { return "calendar.badge.clock" }
        if type == "meeting_reminder" { return "bell.badge.fill" }
        if type == "attendance_check_in" { return "arrow.right.to.line.circle.fill" }
        if type == "attendance_check_out" { return "arrow.left.to.line.circle.fill" }
        if type == "attendance_monthly_report" { return "calendar.badge.checkmark" }
        if type == "request_pending", let request = linkedRequest(item) { return request.kind.icon }
        if type == "request_pending" { return "clock.badge.exclamationmark.fill" }
        if type.contains("rejected") { return "xmark.circle.fill" }
        if type.contains("cancelled") { return "minus.circle.fill" }
        if type.contains("auto_approved") { return "timer.circle.fill" }
        return "checkmark.seal.fill"
    }
    private func notificationColor(_ item: RequestNotification) -> Color {
        let type = item.type
        if type == "meeting_room_booking" { return .teal }
        if type == "meeting_invite" { return .blue }
        if type == "meeting_reminder" { return .orange }
        if type == "attendance_check_in" { return .green }
        if type == "attendance_check_out" { return .blue }
        if type == "attendance_monthly_report" { return .green }
        if type == "request_pending", let request = linkedRequest(item) { return request.kind.color }
        if type == "request_pending" { return .orange }
        if type.contains("rejected") { return AppTheme.red }
        if type.contains("cancelled") { return .gray }
        return .green
    }
    private var notificationPageBackground: Color {
        if #available(iOS 26.0, *) { return AppTheme.ink }
        return legacyNotificationSurface
    }
    private var legacyNotificationSurface: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
                : .white
        })
    }
    @ViewBuilder
    private func requestNotificationBackground(_ item: RequestNotification) -> some View {
        LinearGradient(
            colors: item.read ? [AppTheme.card, AppTheme.card] : [notificationColor(item).opacity(0.24), AppTheme.card],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    @ViewBuilder
    private func articleNotificationBackground(isUnread: Bool) -> some View {
        LinearGradient(
            colors: isUnread ? [AppTheme.red.opacity(0.24), AppTheme.card] : [AppTheme.card, AppTheme.card],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    @ViewBuilder
    private var legacyNotificationSeparator: some View {
        if #available(iOS 26.0, *) {
            EmptyView()
        } else {
            Rectangle().fill(Color.gray.opacity(0.24)).frame(height: 0.5)
        }
    }
}

private struct MeetingNotificationDetail: View {
    // Only calls session methods: must not redraw on every session change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @EnvironmentObject private var meetingStore: MeetingStore
    @Environment(\.dismiss) private var dismiss
    let notification: RequestNotification
    @State private var details: MeetingBookingDetails?
    @State private var isLoading = false

    private var accent: Color {
        // The ten-minute warning is sent to the meeting organiser. Use green
        // consistently so ownership is immediately recognizable and matches
        // the meeting timeline semantics.
        if isEndingSoonReminder { return .green }
        if notification.type == "meeting_room_booking" { return .teal }
        if notification.type == "meeting_reminder" { return .orange }
        if notification.type == "meeting_cancelled" { return .gray }
        return .blue
    }
    private var title: String {
        notification.title
            .replacingOccurrences(of: "Lịch phòng mới: ", with: "")
            .replacingOccurrences(of: "Bạn được mời: ", with: "")
            .replacingOccurrences(of: "Sắp bắt đầu: ", with: "")
    }
    private var messageParts: [String] {
        notification.message.split(separator: "·", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    private var deliveryDate: String {
        // In Vietnam time (AGENTS.md), as every other date: the style used the
        // device's time zone.
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()
        style.locale = VietnamTime.locale
        style.calendar = VietnamTime.calendar
        style.timeZone = VietnamTime.timeZone
        return notification.createdAt.formatted(style)
    }
    private var isEndingSoonReminder: Bool {
        notification.isMeetingEndingSoon
    }
    private var currentScheduleBooking: MeetingBooking? {
        guard let id = details?.id else { return nil }
        return meetingStore.bookings.first(where: { $0.id == id })
    }
    private var effectiveEndsAt: String? {
        currentScheduleBooking?.endsAt ?? details?.endsAt
    }
    private var endDate: Date? {
        effectiveEndsAt.flatMap { MeetingPresentation.date(from: $0) }
    }
    private var isOrganizer: Bool {
        guard let details, let employeeCode = session.profile?.employeeCode else { return false }
        return details.employee.employeeCode.caseInsensitiveCompare(employeeCode) == .orderedSame
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            Image(systemName: notification.type == "meeting_reminder" ? "bell.badge.fill" : "calendar.badge.clock")
                                .font(.title2.bold()).foregroundStyle(.white)
                                .frame(width: 56, height: 56).background(accent.gradient)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            Spacer()
                            Text(
                                isEndingSoonReminder
                                    ? "Sắp kết thúc"
                                : notification.type == "meeting_reminder"
                                    ? "Sắp bắt đầu"
                                    : notification.type == "meeting_room_booking"
                                        ? "Lịch phòng mới"
                                    : notification.type == "meeting_cancelled"
                                            ? "Đã hủy"
                                            : "Lời mời"
                            )
                                .font(.caption.weight(.bold)).foregroundStyle(accent)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(accent.opacity(0.12)).clipShape(Capsule())
                        }
                        Text(title.isEmpty ? "Cuộc họp" : title)
                            .font(.title.bold())
                        Label(
                            notification.type == "meeting_reminder"
                                ? "Hãy chuẩn bị tham gia đúng giờ"
                                : notification.type == "meeting_cancelled"
                                    ? "Lịch họp này đã được hủy"
                                    : notification.type == "meeting_room_booking"
                                        ? "Phòng Nhân sự có quyền xem chi tiết cuộc họp"
                                    : isOrganizer
                                        ? "Bạn là người tổ chức cuộc họp"
                                        : "Bạn được mời tham dự cuộc họp",
                            systemImage: isOrganizer ? "person.badge.key.fill" : "person.2.fill"
                        )
                            .font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [accent.opacity(0.18), Color(uiColor: .secondarySystemBackground)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                    notificationCard(title: "Thông tin cuộc họp", icon: "calendar") {
                        if let details {
                            if details.isLimitedViewer == true {
                                Label("Loại cuộc họp: \(details.title)", systemImage: "tag.fill")
                                    .font(.headline)
                            } else {
                                Label(details.room.name, systemImage: "building.2.fill").font(.headline)
                            }
                            Label(
                                MeetingPresentation.range(
                                    MeetingBooking(
                                        id: details.id,
                                        roomId: details.roomId,
                                        startsAt: details.startsAt,
                                        endsAt: effectiveEndsAt ?? details.endsAt,
                                        title: details.title,
                                        attendeeCount: details.attendeeCount,
                                        status: currentScheduleBooking?.status ?? details.status,
                                        isMine: true,
                                        isOwner: isOrganizer,
                                        organizerName: nil
                                    )
                                ),
                                systemImage: "clock.fill"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            Label("Người tổ chức: \(details.employee.fullName)", systemImage: "person.crop.circle").font(.subheadline).foregroundStyle(.secondary)
                            if details.isLimitedViewer != true {
                                if !details.room.location.isEmpty { Label(details.room.location, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(.secondary) }
                                if !details.participants.isEmpty { Text("Người tham gia: \(details.participants.map { $0.employee.fullName }.joined(separator: ", "))").font(.subheadline).foregroundStyle(.secondary) }
                            }
                        } else {
                            if let room = messageParts.first, !room.isEmpty { Label(room, systemImage: "building.2.fill").font(.headline) }
                            if messageParts.count > 1 { Label(messageParts[1], systemImage: "clock.fill").font(.subheadline).foregroundStyle(.secondary) }
                            else { Text(notification.message).font(.subheadline).foregroundStyle(.secondary) }
                            if isLoading { ProgressView().controlSize(.small) }
                        }
                    }

                    notificationCard(title: "Trạng thái thông báo", icon: "bell.badge.fill") {
                        Text(
                            isEndingSoonReminder
                                ? "Cuộc họp bạn tổ chức còn khoảng 10 phút."
                                : notification.type == "meeting_reminder"
                                    ? "Đây là lời nhắc trước giờ họp."
                                    : notification.type == "meeting_room_booking"
                                        ? "Một lịch phòng họp mới vừa được tạo."
                                    : "Lời mời đã được gửi đến bạn."
                        )
                            .font(.subheadline).foregroundStyle(.secondary)
                        Label("Nhận lúc \(deliveryDate)", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }

                    if isEndingSoonReminder, let details, isOrganizer {
                        MeetingControlCard(
                            bookingID: details.id,
                            roomId: details.roomId,
                            roomName: details.room.name,
                            endDate: endDate
                        )
                    }

                    Text("Mở Lịch của tôi để xem thời gian và thông tin phòng họp mới nhất.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Chi tiết cuộc họp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Đóng") { dismiss() } }
            .task(id: notification.requestId) {
                guard let id = notification.requestId else { return }

                // Stale-while-revalidate: render the RAM cache synchronously,
                // then refresh only when its short TTL has expired.
                if let cached = session.cachedMeetingBookingDetails(id: id) {
                    details = cached
                }
                isLoading = details == nil

                if let loadedDetails = await session.meetingBookingDetails(id: id) {
                    details = loadedDetails
                    if let meetingDate = loadedDetails.startDate {
                        Task {
                            await session.refreshMeetingSchedule(date: meetingDate)
                        }
                    }
                }
                isLoading = false
            }
        }
    }

    private func notificationCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon).font(.subheadline.weight(.bold)).foregroundStyle(accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct RequestNotificationDetail: View {
    let request: EmployeeRequest
    /// Set for the user's own rejected request: tapping the card sends it again.
    var onResubmit: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder private var card: some View {
        if let onResubmit {
            Button {
                onResubmit()
                dismiss()
            } label: {
                RequestCard(request: request, canCancel: false, resubmittable: true, cancel: {})
            }
            .buttonStyle(.plain)
        } else {
            RequestCard(request: request, canCancel: false, cancel: {})
        }
    }
    var body: some View { NavigationStack { ScrollView(showsIndicators: false) { VStack(alignment: .leading, spacing: 18) { card; if request.autoApproved { Label("Tự động duyệt sau 4 giờ", systemImage: "timer").foregroundStyle(.green) } }.padding(20) }.background(AppTheme.ink.ignoresSafeArea()).navigationTitle("Chi tiết đơn").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } } } } }
}

struct ArticleDetailView: View {
    let item: ContentItem
    /// Parsed once when the article opens, not on every redraw.
    @State private var blocks: [ArticleBlock] = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text(VietnamTime.dateTime.string(from: item.createdAt))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.redText)
                Text(item.title)
                    .font(.largeTitle.bold())
                Divider().overlay(Color.white.opacity(0.12))
                ForEach(blocks) { block in
                    ArticleBlockView(block: block)
                }
            }
            .padding(22)
            .padding(.bottom, 90)
        }
        .task(id: item.id) {
            // Up to 750k characters of HTML through regular expressions: off
            // the main thread, so opening a long article does not stall.
            let html = item.body
            let parsed = await Task.detached(priority: .userInitiated) {
                HTMLArticleParser.parse(html)
            }.value
            guard !Task.isCancelled else { return }
            blocks = parsed
        }
        .hidesPortalBottomScrollEdgeEffect()
        .background(AppTheme.ink.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ArticleBlockView: View {
    let block: ArticleBlock

    @ViewBuilder
    var body: some View {
        switch block.kind {
        case .heading(let level):
            VStack(alignment: .leading, spacing: 10) {
                Text(block.text)
                    .font(headingFont(level))
                    .fontWeight(.bold)
                    .foregroundColor(level <= 1 ? .white : AppTheme.text(Color(red: 0.52, green: 0.86, blue: 0.68)))
                    .frame(maxWidth: .infinity, alignment: level == 1 ? .center : .leading)
                if level == 2 {
                    Rectangle()
                        .fill(Color(red: 0.18, green: 0.54, blue: 0.35))
                        .frame(height: 2)
                }
            }
            .padding(level == 1 ? 22 : 0)
            .background(level == 1 ? Color(red: 0.08, green: 0.27, blue: 0.19) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        case .paragraph:
            Text(block.text)
                .font(.body)
                .lineSpacing(7)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .listItem:
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color(red: 0.18, green: 0.54, blue: 0.35))
                    .frame(width: 7, height: 7)
                    .padding(.top, 8)
                Text(block.text)
                    .lineSpacing(6)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)

        case .image(let url, let alt):
            VStack(spacing: 10) {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure:
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(AppTheme.muted)
                                .frame(maxWidth: .infinity, minHeight: 140)
                        default:
                            ProgressView()
                                .tint(AppTheme.red)
                                .frame(maxWidth: .infinity, minHeight: 180)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !alt.isEmpty {
                    Text(alt)
                        .font(.caption)
                        .foregroundColor(AppTheme.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(12)
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        case .tableRow:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text.replacingOccurrences(of: "\n", with: "  |  "))
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .question:
            HStack(alignment: .top, spacing: 12) {
                Text("Q")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color(red: 0.13, green: 0.45, blue: 0.29))
                    .clipShape(Circle())
                Text(block.text).font(.headline)
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        default: return .title3.bold()
        }
    }
}
