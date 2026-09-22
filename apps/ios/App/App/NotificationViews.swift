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
}
struct UpdateCount: Decodable { let count: Int }

@available(iOS 17.0, *)
struct NotificationsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var notificationRouter: APNsNotificationRouter
    @StateObject private var requestStore = EmployeeRequestStore()
    @State private var requestNotifications: [RequestNotification] = []
    @State private var reviewing: EmployeeRequest?
    @State private var viewing: EmployeeRequest?
    @State private var meetingNotification: RequestNotification?
    @State private var confirmClear = false
    @State private var hiddenArticleIDs = Set<String>()
    @State private var isReloadingNotifications = false
    private var items: [ContentItem] { (session.dashboard?.contentItems ?? []).filter { !hiddenArticleIDs.contains($0.id) } }
    private var inboxRequestNotifications: [RequestNotification] {
        requestNotifications.filter { !session.isAttendanceNotificationType($0.type) }
    }
    private var totalUnread: Int { session.unreadCount + inboxRequestNotifications.filter { !$0.read }.count }
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
    private var notificationTitleInsets: EdgeInsets {
        if #available(iOS 26.0, *) {
            return EdgeInsets(top: 20, leading: 20, bottom: 2, trailing: 20)
        }
        return EdgeInsets(top: 32, leading: 20, bottom: 2, trailing: 20)
    }

    @ViewBuilder
    private var legacyTopSafeAreaSpacer: some View {
        if #unavailable(iOS 26.0) {
            // With the navigation bar hidden, older List implementations may
            // place a zero-margin first row under the status-area clipping
            // boundary. This inset is relative to the real safe area, unlike
            // a device-specific top padding.
            Color.clear
                .frame(height: 8)
                .background(notificationPageBackground)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                    PortalPageTitle("Thông báo")
                        .listRowBackground(notificationPageBackground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(notificationTitleInsets)
                    HStack {
                        Text(totalUnread == 0 ? "Bạn đã đọc tất cả thông báo" : "\(totalUnread) thông báo chưa đọc").font(.subheadline.bold())
                        Spacer()
                        if !inboxRequestNotifications.isEmpty || !items.isEmpty { Button("Xóa tất cả", role: .destructive) { confirmClear = true }.font(.subheadline.bold()) }
                    }
                    .listRowBackground(notificationPageBackground)
                    .listRowSeparator(.hidden)
                    ForEach(inboxRequestNotifications) { item in
                        Button { Task { await open(item) } } label: {
                          HStack(alignment: .top, spacing: 14) {
                            Image(systemName: notificationIcon(item)).frame(width: 44, height: 44).background(notificationColor(item).opacity(0.16)).foregroundStyle(notificationColor(item)).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.headline)
                                if let request = linkedRequest(item) {
                                    Text(request.kind.title).font(.caption.bold()).foregroundStyle(request.kind.color).padding(.horizontal, 9).padding(.vertical, 4).background(request.kind.color.opacity(0.13)).clipShape(Capsule())
                                }
                                Text(item.message).font(.subheadline).foregroundStyle(AppTheme.muted)
                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(AppTheme.red)
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
                        let isUnread = index < session.unreadCount
                        NavigationLink(destination: ArticleDetailView(item: item)) {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "megaphone.fill").frame(width: 44, height: 44).background(AppTheme.red.opacity(0.16)).foregroundStyle(AppTheme.red).clipShape(RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title).font(.headline).multilineTextAlignment(.leading)
                                    Text(item.preview).font(.subheadline).foregroundStyle(AppTheme.muted).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(AppTheme.red)
                                }
                                Spacer(minLength: 0)
                                if isUnread {
                                    Text("Mới")
                                        .font(.caption2.bold())
                                        .foregroundStyle(AppTheme.red)
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
                        }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { session.markArticlesRead() })
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
            .contentMargins(.top, 0, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) {
                legacyTopSafeAreaSpacer
            }
            .hidesPortalBottomScrollEdgeEffect()
            .scrollContentBackground(.hidden)
            .background(notificationPageBackground.ignoresSafeArea()).navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
                .refreshable { await reloadNotifications(refreshDashboard: true) }
                .task {
                    hiddenArticleIDs = Set(UserDefaults.standard.stringArray(forKey: "hidden-notification-articles") ?? [])
                    requestNotifications = session.cachedRequestNotifications()
                    requestStore.restoreCache(employeeCode: session.profile?.employeeCode ?? session.dashboard?.employeeCode)
                    await reloadNotifications()
                    await openPendingAPNsRouteIfNeeded()
                }
                .onAppear { Task { await openPendingAPNsRouteIfNeeded() } }
                .onChange(of: session.attendanceRevision) { _, _ in Task { await reloadNotifications() } }
                .onChange(of: notificationRouter.pendingRoute) { _, _ in
                    Task { await openPendingAPNsRouteIfNeeded() }
                }
                .sheet(item: $reviewing) { request in RequestDecisionView(request: request) { approved, note in await requestStore.decide(token: session.token, id: request.id, approved: approved, note: note) } }
                .sheet(item: $viewing) { request in RequestNotificationDetail(request: request) }
                .sheet(item: $meetingNotification) { notification in MeetingNotificationDetail(notification: notification) }
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
        if let values: [RequestNotification] = try? await APIClient.shared.request("me/requests/notifications", token: token) {
            let merged = session.mergedRequestNotifications(values)
            if requestNotifications != merged {
                requestNotifications = merged
            }
            session.updateRequestUnreadCount(merged)
            await requestStore.load(token)
        }
    }

    /// A List refresh keeps its scroll position stable only while its backing
    /// data is replaced once. Dashboard updates used to trigger this method
    /// again through two independent observers during the same pull gesture.
    private func reloadNotifications(refreshDashboard: Bool = false) async {
        guard !isReloadingNotifications else { return }
        isReloadingNotifications = true
        defer { isReloadingNotifications = false }
        if refreshDashboard {
            await session.refreshDashboard(shouldRefreshRequestNotificationCount: false)
        }
        await loadRequestNotifications()
    }

    private func open(_ item: RequestNotification) async {
        if session.isLocalAttendanceNotification(item) {
            session.markLocalAttendanceNotificationRead(item.id)
            await reloadNotifications()
            return
        }

        let isMeetingNotification = item.type.hasPrefix("meeting_") || item.title.hasPrefix("Còn 10 phút")

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

        guard let token = session.token else { return }
        let _: UpdateCount? = try? await APIClient.shared.request(
            "me/requests/notifications/\(item.id)/read",
            method: "PATCH",
            token: token
        )
        await requestStore.load(token, force: true)
        if let id = item.requestId {
            if item.type == "request_pending",
               let request = requestStore.approvals.first(where: { $0.id == id && $0.status == .pending }) {
                reviewing = request
            } else {
                viewing = (requestStore.requests + requestStore.approvals).first(where: { $0.id == id })
            }
        }
        await reloadNotifications()
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
        session.clearLocalAttendanceNotifications()
        let _: UpdateCount? = try? await APIClient.shared.request("me/requests/notifications", method: "DELETE", token: token)
        hiddenArticleIDs.formUnion(items.map(\.id)); UserDefaults.standard.set(Array(hiddenArticleIDs), forKey: "hidden-notification-articles")
        session.markArticlesRead(); await reloadNotifications()
    }

    private func deleteNotification(_ item: RequestNotification) async {
        if session.isLocalAttendanceNotification(item) {
            session.deleteLocalAttendanceNotification(item.id)
            requestNotifications.removeAll { $0.id == item.id }
            return
        }
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
        UserDefaults.standard.set(Array(hiddenArticleIDs), forKey: "hidden-notification-articles")
    }

    private func linkedRequest(_ item: RequestNotification) -> EmployeeRequest? {
        guard let id = item.requestId else { return nil }
        return (requestStore.requests + requestStore.approvals).first { $0.id == id }
    }
    private func notificationIcon(_ item: RequestNotification) -> String {
        let type = item.type
        if type == "meeting_room_booking" { return "building.2.badge.plus" }
        if type == "meeting_invite" { return "calendar.badge.clock" }
        if type == "meeting_reminder" { return "bell.badge.fill" }
        if type == "attendance_check_in" { return "arrow.right.to.line.circle.fill" }
        if type == "attendance_check_out" { return "arrow.left.to.line.circle.fill" }
        if type == "request_pending", let request = linkedRequest(item) { return request.kind.icon }
        if type == "request_pending" { return "clock.badge.exclamationmark.fill" }
        if type == "meeting_invite" { return "person.2.fill" }
        if type == "meeting_reminder" { return "clock.badge.fill" }
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
        if type == "request_pending", let request = linkedRequest(item) { return request.kind.color }
        if type == "request_pending" { return .orange }
        if type == "meeting_invite" { return .blue }
        if type == "meeting_reminder" { return .orange }
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


@available(iOS 17.0, *)
private struct MeetingNotificationDetail: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    let notification: RequestNotification
    @State private var details: MeetingBookingDetails?
    @State private var isLoading = false
    @State private var extensionMinutes = 5
    @State private var isSubmitting = false
    @State private var submittingAction: String?
    @State private var actionError: String?

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
        notification.createdAt.formatted(.dateTime.locale(Locale(identifier: "vi_VN")).weekday(.wide).day().month(.wide).year().hour().minute())
    }
    private var isEndingSoonReminder: Bool {
        notification.type == "meeting_ending_soon" || notification.title.hasPrefix("Còn 10 phút")
    }
    private var currentScheduleBooking: MeetingBooking? {
        guard let id = details?.id else { return nil }
        return session.meetingBookings.first(where: { $0.id == id })
    }
    private var effectiveEndsAt: String? {
        currentScheduleBooking?.endsAt ?? details?.endsAt
    }
    private var endDate: Date? {
        effectiveEndsAt.flatMap { MeetingPresentation.date(from: $0) }
    }
    private var meetingEnded: Bool { endDate.map { $0 <= Date() } ?? false }
    private var isOrganizer: Bool {
        guard let details, let employeeCode = session.profile?.employeeCode else { return false }
        return details.employee.employeeCode.caseInsensitiveCompare(employeeCode) == .orderedSame
    }
    private var nextBooking: MeetingBooking? {
        guard let details, let endDate else { return nil }
        return session.meetingBookings
            .filter { $0.roomId == details.roomId && $0.id != details.id }
            .filter { booking in
                guard let start = MeetingPresentation.date(from: booking.startsAt) else { return false }
                return start > endDate
            }
            .sorted { left, right in
                (MeetingPresentation.date(from: left.startsAt) ?? .distantFuture)
                    < (MeetingPresentation.date(from: right.startsAt) ?? .distantFuture)
            }
            .first
    }
    private var maximumExtensionMinutes: Int {
        guard let endDate else { return 0 }
        guard let nextStart = nextBooking.flatMap({ MeetingPresentation.date(from: $0.startsAt) }) else { return 120 }
        return min(120, max(0, Int(nextStart.timeIntervalSince(endDate) / 60) - 5))
    }
    private var extensionBlockMessage: String {
        guard let nextBooking else {
            return "Không thể gia hạn vì lịch phòng đang được cập nhật."
        }
        let title = nextBooking.title.isEmpty ? "cuộc họp tiếp theo" : "“\(nextBooking.title)”"
        return "Không thể gia hạn vì \(details?.room.name ?? "phòng họp") có \(title) lúc \(MeetingPresentation.time(nextBooking.startsAt))."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
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
                            .font(.system(size: 27, weight: .bold, design: .rounded))
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
                            Label(details.room.name, systemImage: "building.2.fill").font(.headline)
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
                                        isOwner: isOrganizer
                                    )
                                ),
                                systemImage: "clock.fill"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            if !details.room.location.isEmpty { Label(details.room.location, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(.secondary) }
                            Label("Người tổ chức: \(details.employee.fullName)", systemImage: "person.crop.circle").font(.subheadline).foregroundStyle(.secondary)
                            if !details.participants.isEmpty { Text("Người tham gia: \(details.participants.map { $0.employee.fullName }.joined(separator: ", "))").font(.subheadline).foregroundStyle(.secondary) }
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
                        meetingControlCard(details)
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
                    if let meetingDate = MeetingPresentation.date(from: loadedDetails.startsAt) {
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

    @ViewBuilder
    private func meetingControlCard(_ details: MeetingBookingDetails) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(meetingEnded ? "Cuộc họp đã kết thúc" : "Điều khiển cuộc họp", systemImage: meetingEnded ? "checkmark.circle.fill" : "slider.horizontal.3")
                .font(.headline.weight(.bold))
                .foregroundStyle(meetingEnded ? .green : accent)
            if meetingEnded {
                Text("Cuộc họp đã kết thúc. Bạn không thể gia hạn hoặc kết thúc lại.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                if let actionError {
                    Text(actionError).font(.caption.weight(.semibold)).foregroundStyle(.red)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if maximumExtensionMinutes >= 5 {
                    Text("Gia hạn thêm \(extensionMinutes) phút")
                        .font(.subheadline.weight(.bold)).foregroundStyle(.green)
                    HStack(spacing: 10) {
                        Button("− 5 phút") { extensionMinutes = max(5, extensionMinutes - 5); actionError = nil }
                            .buttonStyle(.bordered).disabled(isSubmitting)
                        Button("+ 5 phút") { extensionMinutes = min(maximumExtensionMinutes, extensionMinutes + 5); actionError = nil }
                            .buttonStyle(.bordered).disabled(isSubmitting || extensionMinutes >= maximumExtensionMinutes)
                    }
                    Button {
                        Task { await submit(details, action: "extend") }
                    } label: {
                        HStack(spacing: 8) {
                            if isSubmitting && submittingAction == "extend" {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark")
                            }
                            Text(isSubmitting && submittingAction == "extend" ? "Đang gia hạn…" : "Xác nhận gia hạn")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green).disabled(isSubmitting)
                } else {
                    Button {
                        // Keep the unavailable action visible so the organiser
                        // understands why it cannot be used for this meeting.
                    } label: {
                        Label("Gia hạn không khả dụng", systemImage: "clock.badge.exclamationmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .disabled(true)
                    Text(extensionBlockMessage)
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                }
                Button(role: .destructive) {
                    Task { await submit(details, action: "end") }
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting && submittingAction == "end" {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "stop.fill")
                        }
                        Text(isSubmitting && submittingAction == "end" ? "Đang kết thúc…" : "Kết thúc cuộc họp")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).disabled(isSubmitting)
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @MainActor
    private func submit(_ details: MeetingBookingDetails, action: String) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        submittingAction = action
        actionError = nil

        actionError = await session.performMeetingControl(
            bookingID: details.id,
            action: action,
            extensionMinutes: extensionMinutes
        )

        if actionError == nil {
            extensionMinutes = 5
        }
        submittingAction = nil
        isSubmitting = false
    }
}

@available(iOS 17.0, *)
struct RequestNotificationDetail: View {
    let request: EmployeeRequest
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 18) { RequestCard(request: request, canCancel: false, cancel: {}); if request.autoApproved { Label("Tự động duyệt sau 4 giờ", systemImage: "timer").foregroundStyle(.green) } }.padding(20) }.background(AppTheme.ink.ignoresSafeArea()).navigationTitle("Chi tiết đơn").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } } } } }
}

@available(iOS 17.0, *)
struct NewsView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var query = ""

    private var items: [ContentItem] {
        let all = session.dashboard?.contentItems ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.plainBody.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(destination: ArticleDetailView(item: item)) {
                            ArticleRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                    if items.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "newspaper").font(.largeTitle).foregroundColor(AppTheme.muted)
                            Text("Chưa có bài viết phù hợp").foregroundColor(AppTheme.muted)
                        }.padding(.top, 80)
                    }
                }
                .padding(18)
                .padding(.bottom, 94)
            }
            .hidesPortalBottomScrollEdgeEffect()
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("Bài viết nội bộ")
            .searchable(text: $query, prompt: "Tìm bài viết")
            .refreshable { await session.refreshDashboard() }
            .onAppear { session.markArticlesRead() }
        }
        .navigationViewStyle(.stack)
    }
}

@available(iOS 17.0, *)
struct ArticleRow: View {
    let item: ContentItem
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(item.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.red)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(AppTheme.muted)
            }
            Text(item.title).font(.headline).multilineTextAlignment(.leading)
            Text(item.preview)
                .font(.subheadline)
                .foregroundColor(AppTheme.muted)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

@available(iOS 17.0, *)
struct ArticleDetailView: View {
    let item: ContentItem
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text(item.createdAt.formatted(date: .long, time: .shortened))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.red)
                Text(item.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Divider().overlay(Color.white.opacity(0.12))
                ForEach(item.articleBlocks) { block in
                    ArticleBlockView(block: block)
                }
            }
            .padding(22)
            .padding(.bottom, 90)
        }
        .hidesPortalBottomScrollEdgeEffect()
        .background(AppTheme.ink.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

@available(iOS 17.0, *)
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
                    .foregroundColor(level <= 1 ? .white : Color(red: 0.52, green: 0.86, blue: 0.68))
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
                    .font(.system(.subheadline, design: .rounded))
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .question:
            HStack(alignment: .top, spacing: 12) {
                Text("Q")
                    .font(.caption.bold())
                    .frame(width: 28, height: 28)
                    .background(Color(red: 0.18, green: 0.54, blue: 0.35))
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
        case 1: return .system(size: 27, weight: .bold, design: .rounded)
        case 2: return .system(size: 23, weight: .bold, design: .rounded)
        default: return .system(size: 19, weight: .bold, design: .rounded)
        }
    }
}
