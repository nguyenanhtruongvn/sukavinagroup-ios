import UIKit
import SwiftUI
import Security
import UserNotifications
import Network
import LocalAuthentication
import WidgetKit
import AVFoundation
import CoreImage.CIFilterBuiltins

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
    /// A notifications load younger than this is reused when the tab appears.
    private static let notificationsFreshness: TimeInterval = 30
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
    /// A tapped request that is still missing after a reload.
    @State private var requestNotFound = false
    /// A tapped birthday / Christmas / New Year greeting: its card and effect.
    @State private var celebration: CelebrationItem?
    @State private var hiddenArticleIDs = Set<String>()
    @State private var reloadAgain = false
    @State private var reloadAgainWithDashboard = false
    @State private var isReloadingNotifications = false
    private var items: [ContentItem] { inbox.articles.filter { !hiddenArticleIDs.contains($0.id) } }
    /// Every source (cache, InboxState, loads) is already
    /// `mergedRequestNotifications`, which drops attendance types; filtering
    /// again on each access ran 3+ times per redraw.
    private var inboxRequestNotifications: [RequestNotification] { requestNotifications }
    private var totalUnread: Int { inbox.unreadCount + inboxRequestNotifications.filter { !$0.read }.count }
    // UIKit's semantic label color is white in Dark Mode and black in
    // Light Mode, including when the in-app appearance overrides the system.
    // Keep notification category/status/accent colors unchanged.
    private var readableNotificationText: Color { Color(uiColor: .label) }
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
                        requestNotificationRow(item)
                    }
                    ForEach(items) { item in
                        articleNotificationRow(item, isUnread: inbox.unreadArticleIDs.contains(item.id))
                    }
                    if items.isEmpty && inboxRequestNotifications.isEmpty {
                        UnavailableContent("Chưa có thông báo", systemImage: "bell.slash")
                            .foregroundStyle(readableNotificationText)
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
            .scrollContentMargin(.top, 4)
            // Title, unread count and "Xóa tất cả" stay put; only the
            // notifications scroll.
            .safeAreaInset(edge: .top, spacing: 0) {
                notificationHeader
            }
            .hidesPortalBottomScrollEdgeEffect()
            .scrollContentBackground(.hidden)
            .background(notificationPageBackground.ignoresSafeArea()).navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
                .refreshable { await reloadNotifications(refreshDashboard: true) }
                .task {
                    hiddenArticleIDs = session.hiddenArticleIDs()
                    // SessionStore already holds the current list (badge,
                    // realtime); decode the disk cache only before its first load.
                    if !inbox.requestNotifications.isEmpty {
                        // Also catches a change missed while off-window.
                        if requestNotifications != inbox.requestNotifications {
                            requestNotifications = inbox.requestNotifications
                        }
                    } else if requestNotifications.isEmpty {
                        requestNotifications = session.cachedRequestNotifications()
                    }
                    requestStore.restoreCache(employeeCode: session.profile?.employeeCode ?? session.dashboard?.employeeCode)
                    // A route set by a push before this view appeared opens
                    // now, not after the network reload below.
                    await openPendingAPNsRouteIfNeeded()
                    // Showing the tab used to force a fetch every time; a
                    // recent load is kept current by realtime events and APNs.
                    if session.requestNotificationsAreFresh(maxAge: Self.notificationsFreshness) {
                        if let token = session.token { await requestStore.load(token) }
                    } else {
                        await reloadNotifications()
                    }
                    // .task runs on every appearance, so no separate onAppear.
                    await openPendingAPNsRouteIfNeeded()
                }
                .onValueChange(of: revisions.attendance) { _, _ in Task { await reloadNotifications() } }
                // Request, meeting and inbox events (a decision, an invitation,
                // a read on another device) are fetched once by SessionStore,
                // for the badge; this list mirrors that result instead of
                // requesting the same notifications a second time.
                .onValueChange(of: inbox.requestNotifications) { _, values in
                    if requestNotifications != values { requestNotifications = values }
                    // A pending tap whose notification only arrived now.
                    if notificationRouter.pendingRoute != nil {
                        Task { await openPendingAPNsRouteIfNeeded(allowReload: false) }
                    }
                }
                .onValueChange(of: notificationRouter.pendingRoute) { _, _ in
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
                    // iOS 17: the UIKit form (the SwiftUI composer crashed there).
                    PlatformRequestComposer(template: request) {
                        kind,
                        from,
                        to,
                        reason,
                        destination,
                        transport,
                        distance,
                        expense,
                        lunchMeal,
                        dinnerMeal,
                        employeeIds in
                        await requestStore.submit(
                            token: session.token,
                            kind: kind,
                            from: from,
                            to: to,
                            reason: reason,
                            destination: destination,
                            transport: transport,
                            distanceKm: distance,
                            expense: expense,
                            lunchMeal: lunchMeal,
                            dinnerMeal: dinnerMeal,
                            employeeIds: employeeIds
                        )
                    }
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
        .fullScreenCover(item: $celebration) { item in
            CelebrationOverlay(item: item) { showCelebration(nil) }
                .presentationBackgroundIfAvailable(.clear)
        }
        .alert("Không mở được đơn", isPresented: $requestNotFound) {
            Button("Đóng", role: .cancel) {}
        } message: {
            Text("Đơn này không còn trong danh sách. Hãy kéo xuống để tải lại hoặc xem trong tab Đơn từ.")
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

    private var unreadSummary: String {
        totalUnread == 0 ? "Bạn đã đọc tất cả thông báo" : "\(totalUnread) thông báo chưa đọc"
    }

    private var notificationHeader: some View {
        PortalPinnedHeader("Thông báo", background: notificationPageBackground) {
            HStack {
                Text(unreadSummary).font(.subheadline.bold())
                Spacer()
                if !inboxRequestNotifications.isEmpty || !items.isEmpty {
                    Button("Xóa tất cả", role: .destructive) { confirmClear = true }
                        .font(.subheadline.bold())
                }
            }
        }
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

    /// Shows (or closes) the greeting card without the sheet slide: the card
    /// fades and pops in by itself.
    private func showCelebration(_ item: CelebrationItem?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { celebration = item }
    }

    private func open(_ item: RequestNotification) async {
        if let key = Celebration.key(forNotificationType: item.type) {
            showCelebration(CelebrationItem(key: key, title: item.title, message: item.message))
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
            if !opened, viewing == nil, reviewing == nil, meetingNotification == nil,
               !presentRequest(for: item, allowViewingPending: true), let id = item.requestId {
                // Still missing (an old notification): fetch that request
                // alone; say so instead of leaving the tap without a response.
                let fetched: EmployeeRequest? = try? await APIClient.shared.request("me/requests/\(id)", token: token)
                if viewing != nil || reviewing != nil || meetingNotification != nil {
                    // Something else opened meanwhile: leave it.
                } else if let fetched {
                    // A pending approval notification goes to its approver.
                    if item.type == "request_pending" && fetched.status == .pending {
                        reviewing = fetched
                    } else {
                        viewing = fetched
                    }
                } else {
                    requestNotFound = true
                }
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

    private func openPendingAPNsRouteIfNeeded(allowReload: Bool = true) async {
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
        func matchingItem() -> RequestNotification? {
            requestNotifications.first {
                guard $0.type == route.type else { return false }
                return route.referenceID == nil || $0.requestId == route.referenceID
            }
        }
        var item = matchingItem()
        // A notification that just arrived is not in a list loaded earlier:
        // reload it once instead of leaving the tap unanswered (the list used
        // to reload only when empty).
        if item == nil, allowReload {
            await reloadNotifications()
            item = matchingItem()
        }
        // A greeting no longer in the inbox (deleted, or older than the
        // list): show today's words for it instead.
        if item == nil, allowReload, let key = Celebration.key(forNotificationType: route.type) {
            notificationRouter.consume(route)
            guard let token = session.token else { return }
            let today: CelebrationResponse? = try? await APIClient.shared.request("me/celebration?preview=\(key)", token: token)
            if let found = today?.items.first(where: { $0.key == key }) { showCelebration(found) }
            return
        }
        // Still missing (e.g. a reload already running): the route stays
        // pending and is retried when the list changes.
        guard let item else { return }
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
        // "Nhận thông báo đặt món": an order or a cancellation.
        if type == "meal_ordered" || type == "meal_cancelled" { return "fork.knife" }
        if type == "request_pending", let request = linkedRequest(item) { return request.kind.icon }
        if type == "request_pending" { return "clock.badge.exclamationmark.fill" }
        if type.contains("rejected") { return "xmark.circle.fill" }
        if type.contains("cancelled") { return "minus.circle.fill" }
        if type.contains("auto_approved") { return "timer.circle.fill" }
        return "checkmark.seal.fill"
    }
    private func notificationColor(_ item: RequestNotification) -> Color {
        let type = item.type
        if let key = Celebration.key(forNotificationType: type) { return Celebration.color(key) }
        if type == "meeting_room_booking" { return .teal }
        if type == "meeting_invite" { return .blue }
        if type == "meeting_reminder" { return .orange }
        if type == "attendance_check_in" { return .green }
        if type == "attendance_check_out" { return .blue }
        if type == "attendance_monthly_report" { return .green }
        if type == "meal_ordered" { return .orange }
        if type == "meal_cancelled" { return .gray }
        if type == "request_pending", let request = linkedRequest(item) { return request.kind.color }
        if type == "request_pending" { return .orange }
        if type.contains("rejected") { return AppTheme.red }
        if type.contains("cancelled") { return .gray }
        return .green
    }

    @ViewBuilder
    private func unreadBadge(for item: RequestNotification) -> some View {
        if !item.read {
            let color = notificationColor(item)
            Text("Mới")
                .font(.caption2.bold())
                .foregroundStyle(color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(color.opacity(0.18))
                .clipShape(Capsule())
        }
    }

    /// Once read, an approver's request notification shows the request's
    /// status at the end of the kind row ("Chờ duyệt" / "Đã duyệt" /
    /// "Từ chối"), so it can be told apart without opening it.
    @ViewBuilder
    private func statusBadge(for item: RequestNotification, request: EmployeeRequest?) -> some View {
        if item.read, item.type == "request_pending", let request,
           [EmployeeRequestStatus.pending, .approved, .rejected].contains(request.status) {
            Text(request.status.title)
                .font(.caption2.bold())
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(request.status.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(request.status.color.opacity(0.14))
                .clipShape(Capsule())
        }
    }

    private func requestNotificationRow(_ item: RequestNotification) -> some View {
        Button { Task { await open(item) } } label: {
            requestNotificationContent(item)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { Task { await deleteNotification(item) } } label: {
                Image(systemName: "trash.fill").accessibilityLabel("Xóa")
            }
        }
        .listRowBackground(notificationPageBackground)
        .listRowSeparator(.hidden)
        .listRowInsets(notificationRowInsets)
    }

    private func requestNotificationContent(_ item: RequestNotification) -> some View {
        let request = linkedRequest(item)
        let startsAt = request?.from ?? item.startsAt
        let endsAt = request?.to ?? item.endsAt
        let color = notificationColor(item)
        return HStack(alignment: .top, spacing: 14) {
            Group {
                // Greetings show their day: cake, Christmas tree, fireworks.
                if let key = Celebration.key(forNotificationType: item.type) {
                    Text(Celebration.emoji(key)).font(.system(size: 22))
                } else {
                    Image(systemName: notificationIcon(item))
                }
            }
                .frame(width: 44, height: 44)
                .background(color.opacity(0.16))
                .foregroundStyle(color)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline)
                if let request {
                    HStack(spacing: 8) {
                        Text(request.kind.title)
                            .font(.caption.bold())
                            .foregroundStyle(request.kind.color)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(request.kind.color.opacity(0.13))
                            .clipShape(Capsule())
                        Spacer(minLength: 0)
                        // "Mới" while unread, then the approver's status.
                        if item.read {
                            statusBadge(for: item, request: request)
                        } else {
                            unreadBadge(for: item)
                        }
                    }
                }
                if item.type.hasPrefix("request_") && (startsAt != nil || endsAt != nil) {
                    requestDateRange(startsAt: startsAt, endsAt: endsAt)
                }
                Text(item.message).font(.subheadline).foregroundStyle(readableNotificationText)
                Text(VietnamTime.dateTime.string(from: item.createdAt)).font(.caption).foregroundStyle(AppTheme.redText)
            }
            Spacer(minLength: 0)
            // Without a kind row the "Mới" badge stays in the corner.
            if request == nil {
                unreadBadge(for: item)
            }
        }
        .padding(16)
        .background { requestNotificationBackground(item) }
        // No shadow: applied before this clip it was cut off (invisible) but
        // still cost an offscreen pass per scrolling row.
        .clipShape(RoundedRectangle(cornerRadius: notificationCornerRadius, style: .continuous))
        .overlay(alignment: .bottom) { legacyNotificationSeparator }
    }

    @ViewBuilder
    private func requestDateRange(startsAt: Date?, endsAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let startsAt { Text("Từ: \(startsAt.requestDateTimeText)") }
            if let endsAt { Text("Đến: \(endsAt.requestDateTimeText)") }
        }
        .font(.caption)
        .foregroundStyle(readableNotificationText)
    }

    private func articleNotificationRow(_ item: ContentItem, isUnread: Bool) -> some View {
        NavigationLink(destination: ArticleDetailView(item: item)) {
            articleNotificationContent(item, isUnread: isUnread)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { session.markArticleRead(item.id) })
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { hideArticle(item) } label: {
                Image(systemName: "trash.fill").accessibilityLabel("Xóa")
            }
        }
        .listRowBackground(notificationPageBackground)
        .listRowSeparator(.hidden)
        .listRowInsets(notificationRowInsets)
    }

    private func articleNotificationContent(_ item: ContentItem, isUnread: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "megaphone.fill")
                .frame(width: 44, height: 44)
                .background(AppTheme.red.opacity(0.16))
                .foregroundStyle(AppTheme.red)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline).multilineTextAlignment(.leading)
                articlePreview(item.preview)
                Text(VietnamTime.dateTime.string(from: item.createdAt)).font(.caption).foregroundStyle(AppTheme.redText)
            }
            Spacer(minLength: 0)
            articleUnreadBadge(isUnread: isUnread)
        }
        .padding(16)
        .background { articleNotificationBackground(isUnread: isUnread) }
        // No shadow: applied before this clip it was cut off (invisible) but
        // still cost an offscreen pass per scrolling row.
        .clipShape(RoundedRectangle(cornerRadius: notificationCornerRadius, style: .continuous))
        .overlay(alignment: .bottom) { legacyNotificationSeparator }
    }

    private func articlePreview(_ preview: String) -> some View {
        Text(preview)
            .font(.subheadline)
            .foregroundStyle(readableNotificationText)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func articleUnreadBadge(isUnread: Bool) -> some View {
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
                            .foregroundStyle(Color(uiColor: .label))
                            Label("Người tổ chức: \(details.employee.fullName)", systemImage: "person.crop.circle").font(.subheadline).foregroundStyle(Color(uiColor: .label))
                            if details.isLimitedViewer != true {
                                if !details.room.location.isEmpty { Label(details.room.location, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(Color(uiColor: .label)) }
                                if !details.participants.isEmpty { Text("Người tham gia: \(details.participants.map { $0.employee.fullName }.joined(separator: ", "))").font(.subheadline).foregroundStyle(Color(uiColor: .label)) }
                            }
                        } else {
                            if let room = messageParts.first, !room.isEmpty { Label(room, systemImage: "building.2.fill").font(.headline) }
                            if messageParts.count > 1 { Label(messageParts[1], systemImage: "clock.fill").font(.subheadline).foregroundStyle(Color(uiColor: .label)) }
                            else { Text(notification.message).font(.subheadline).foregroundStyle(Color(uiColor: .label)) }
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
                            .font(.subheadline).foregroundStyle(Color(uiColor: .label))
                        Label("Nhận lúc \(deliveryDate)", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.medium)).foregroundStyle(Color(uiColor: .label))
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
                        .font(.caption).foregroundStyle(Color(uiColor: .label)).frame(maxWidth: .infinity, alignment: .center)
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
                RequestCard(request: request, canCancel: false, resubmittable: true, readableNotificationText: true, cancel: {})
            }
            .buttonStyle(.plain)
        } else {
            RequestCard(request: request, canCancel: false, readableNotificationText: true, cancel: {})
        }
    }
    var body: some View { NavigationStack { ScrollView(showsIndicators: false) { VStack(alignment: .leading, spacing: 18) { card; if request.autoApproved { Label("Tự động duyệt", systemImage: "checkmark.seal.fill").foregroundStyle(.green) } }.padding(20) }.background(AppTheme.ink.ignoresSafeArea()).navigationTitle("Chi tiết đơn").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } } } } }
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
                    ArticleImageView(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !alt.isEmpty {
                    Text(alt)
                        .font(.caption)
                        .foregroundColor(Color(uiColor: .label))
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

/// Decoded article images, kept in memory and limited to a display-sized
/// width. AsyncImage decoded the full-size file again (on each appearance)
/// whenever a block scrolled back into the LazyVStack; the bytes themselves
/// already come from the enlarged `URLCache.shared`.
enum ArticleImages {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 30
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    /// Wider than any iPhone screen and most iPad article columns, in pixels.
    private static let maxPixelWidth: CGFloat = 2048

    static func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = UIImage(data: data) else { return nil }
        let pixels = CGSize(width: decoded.size.width * decoded.scale, height: decoded.size.height * decoded.scale)
        let factor = maxPixelWidth / max(pixels.width, 1)
        let prepared: UIImage?
        if factor < 1 {
            prepared = await decoded.byPreparingThumbnail(
                ofSize: CGSize(width: (pixels.width * factor).rounded(.up), height: (pixels.height * factor).rounded(.up))
            )
        } else {
            prepared = await decoded.byPreparingForDisplay()
        }
        let image = prepared ?? decoded
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }
}

/// AsyncImage's three states (loading, image, failure) backed by `ArticleImages`.
private struct ArticleImageView: View {
    let url: URL
    @State private var loaded: (url: URL, image: UIImage)?
    @State private var failedURL: URL?

    var body: some View {
        // A decoded image shows at once, without a loading frame.
        let image = (loaded?.url == url ? loaded?.image : nil) ?? ArticleImages.cached(url)
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failedURL == url {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundColor(AppTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ProgressView()
                    .tint(AppTheme.red)
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .task(id: url) {
            if let image = await ArticleImages.load(url) {
                loaded = (url, image)
            } else if !Task.isCancelled {
                failedURL = url
            }
        }
    }
}

// MARK: - Greeting card (birthday / Christmas / New Year)

/// One greeting to show on the card: "birthday", "christmas", "newyear" (1/1) or "tet" (mùng 1 Tết).
struct CelebrationItem: Decodable, Identifiable, Equatable {
    let key: String
    let title: String
    let message: String
    var id: String { "\(key)|\(title)|\(message)" }
}

/// `GET me/celebration?preview=<key>`: today's words for a greeting, used
/// when a tapped greeting is no longer in the inbox.
struct CelebrationResponse: Decodable {
    let items: [CelebrationItem]
}

enum Celebration {
    /// The greeting notification types the server sends, and their card.
    static func key(forNotificationType type: String) -> String? {
        switch type {
        case "birthday_greeting": return "birthday"
        case "christmas_greeting": return "christmas"
        case "newyear_greeting": return "newyear"
        case "tet_greeting": return "tet"
        default: return nil
        }
    }

    static func emoji(_ key: String) -> String {
        switch key {
        case "christmas": return "🎄"
        case "newyear": return "🎆"
        case "tet": return "🧧"
        default: return "🎂"
        }
    }

    static func color(_ key: String) -> Color {
        switch key {
        case "christmas": return Color(red: 0.18, green: 0.66, blue: 0.40)
        case "newyear": return Color(red: 0.95, green: 0.66, blue: 0.23)
        case "tet": return Color(red: 0.86, green: 0.15, blue: 0.18)
        default: return Color(red: 1.0, green: 0.30, blue: 0.43)
        }
    }

    static func buttonTitle(_ key: String) -> String {
        switch key {
        case "christmas": return "Giáng sinh an lành!"
        case "newyear": return "An khang thịnh vượng!"
        case "tet": return "Vạn sự như ý!"
        default: return "Sinh nhật vui vẻ!"
        }
    }
}

/// Full-screen greeting opened by tapping its notification: an animated
/// background (balloons and confetti for a birthday, snow for Christmas,
/// fireworks for New Year) under a card with the message. A tap outside the
/// card or on its button closes it. Still when Reduce Motion is on.
struct CelebrationOverlay: View {
    let item: CelebrationItem
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var shown = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var music = CelebrationMusic()

    // Smoothness: the dimmed background, the effects and the card fade on
    // their own (no group opacity, which would composite the whole screen
    // offscreen every frame); the card pops gently from 92 %; the music
    // starts once the card has opened, with its audio set up off the main
    // thread.
    var body: some View {
        let accent = Celebration.color(item.key)
        ZStack {
            Color(red: 0.035, green: 0.043, blue: 0.063).opacity(shown ? 0.9 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Đóng")
            if !reduceMotion {
                TimelineView(.animation) { timeline in
                    let t = Float(timeline.date.timeIntervalSince(start))
                    Canvas { context, size in
                        CelebrationEffects.draw(item.key, t: t, in: &context, size: size)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .opacity(shown ? 1 : 0)
            }
            card(accent: accent)
                .padding(.horizontal, 24)
                .frame(maxWidth: 440)
                .scaleEffect(shown || reduceMotion ? 1 : 0.92)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            start = Date()
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.82)) { shown = true }
            music.start(item.key)
        }
        .onDisappear { music.stop() }
        // Quiet while the app is in the background.
        .onValueChange(of: scenePhase) { _, phase in
            if phase == .active { music.resume() } else if phase == .background { music.pause() }
        }
    }

    private func close() {
        music.stop()
        onDismiss()
    }

    private func card(accent: Color) -> some View {
        let lines = item.message.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return VStack(spacing: 14) {
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let bob = reduceMotion ? 0 : sin(timeline.date.timeIntervalSince(start) * 2.4) * 4
                Text(Celebration.emoji(item.key))
                    .font(.system(size: 52))
                    .offset(y: bob)
            }
            .frame(width: 88, height: 88)
            .background(RadialGradient(colors: [accent.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 44))
            .accessibilityHidden(true)
            Text(item.title)
                .font(.title2.weight(.heavy))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(index == 0 ? .body.weight(.medium) : .subheadline)
                            .foregroundStyle(index == 0 ? Color(white: 0.92) : Color(white: 0.78))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            Button(action: close) {
                Text(Celebration.buttonTitle(item.key))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(AppTheme.red, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .background(
            LinearGradient(colors: [Color(red: 0.165, green: 0.173, blue: 0.212), Color(red: 0.106, green: 0.11, blue: 0.137)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(accent.opacity(0.45), lineWidth: 1))
        // Taps on the card do not close it.
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture {}
    }
}

/// The animated backgrounds, drawn from the time since the card opened.
/// Each particle's random numbers are made once; pieces of one colour are
/// drawn as a single path, so a frame is a handful of fills, not hundreds.
enum CelebrationEffects {
    static func draw(_ key: String, t: Float, in context: inout GraphicsContext, size: CGSize) {
        switch key {
        case "christmas":
            snow(t, &context, size)
        case "newyear", "tet":
            fireworks(t, &context, size)
            confetti(t, &context, size, colors: newYearColors, field: newYearField)
        default:
            balloons(t, &context, size)
            confetti(t, &context, size, colors: birthdayColors, field: birthdayField)
        }
    }

    private static let birthdayColors: [Color] = [
        Color(red: 1, green: 0.30, blue: 0.43), Color(red: 1, green: 0.76, blue: 0.27), Color(red: 0.30, green: 0.79, blue: 0.94),
        Color(red: 0.50, green: 0.93, blue: 0.60), Color(red: 0.72, green: 0.58, blue: 0.96), Color(red: 1, green: 0.56, blue: 0.67),
    ]
    private static let newYearColors: [Color] = [
        Color(red: 1, green: 0.82, blue: 0.40), Color(red: 1, green: 0.91, blue: 0.64), Color(red: 0.91, green: 0.12, blue: 0.16),
        .white, Color(red: 0.96, green: 0.64, blue: 0.35),
    ]

    /// Small deterministic random numbers (same sequence for the same seed).
    private struct Seeded {
        private var state: UInt64
        init(_ seed: Int) { state = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1_013_904_223) | 1 }
        mutating func next() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(state % 1_000_000) / 1_000_000
        }
    }

    /// `count` particles × `per` random numbers, made once.
    private struct Field {
        let count: Int
        let per: Int
        let values: [Float]
        init(count: Int, per: Int, seed: Int) {
            var r = Seeded(seed)
            self.count = count
            self.per = per
            values = (0..<(count * per)).map { _ in r.next() }
        }
        subscript(i: Int, k: Int) -> Float { values[i * per + k] }
    }

    private static let birthdayField = Field(count: 80, per: 8, seed: 7_919)
    private static let newYearField = Field(count: 50, per: 8, seed: 7_919)
    private static let snowField = Field(count: 110, per: 4, seed: 31_337)
    private static let balloonField = Field(count: 9, per: 4, seed: 104_729)

    private static func confetti(_ t: Float, _ context: inout GraphicsContext, _ size: CGSize, colors: [Color], field: Field) {
        let w = Float(size.width), h = Float(size.height)
        var paths = Array(repeating: Path(), count: colors.count)
        for i in 0..<field.count {
            let speed = h * (0.16 + field[i, 0] * 0.22)
            let local = t - field[i, 1] * 2.5
            if local < 0 { continue }
            let life = (h * 1.15) / speed
            let phase = local.truncatingRemainder(dividingBy: life)
            let x = field[i, 2] * w + sin(phase * (1.2 + field[i, 3] * 1.6) + Float(i)) * 28
            let y = -40 + phase * speed
            let halfW = (4 + field[i, 4] * 5) / 2
            let halfH = max((2.5 + field[i, 5] * 3.5) * abs(cos(phase * (3 + field[i, 7] * 4))), 0.4) / 2
            let angle = phase * (1.6 + field[i, 6] * 4.5) * (i % 2 == 0 ? 1 : -1)
            let c = cos(angle), s = sin(angle)
            // The rotated strip's four corners.
            func corner(_ dx: Float, _ dy: Float) -> CGPoint {
                CGPoint(x: CGFloat(x + dx * c - dy * s), y: CGFloat(y + dx * s + dy * c))
            }
            paths[i % colors.count].addLines([corner(-halfW, -halfH), corner(halfW, -halfH), corner(halfW, halfH), corner(-halfW, halfH)])
            paths[i % colors.count].closeSubpath()
        }
        for (index, path) in paths.enumerated() { context.fill(path, with: .color(colors[index])) }
    }

    private static func balloons(_ t: Float, _ context: inout GraphicsContext, _ size: CGSize) {
        let w = Float(size.width), h = Float(size.height)
        for i in 0..<balloonField.count {
            let radius = 18 + balloonField[i, 0] * 12
            let speed = h * (0.07 + balloonField[i, 1] * 0.06)
            let life = (h + radius * 6) / speed
            let phase = (t + balloonField[i, 2] * life).truncatingRemainder(dividingBy: life)
            let baseX = (Float(i) + 0.5) / 9 * w + (balloonField[i, 3] - 0.5) * 40
            let x = baseX + sin(phase * 0.9 + Float(i)) * 16
            let y = h + radius * 2 - phase * speed
            let color = birthdayColors[i % birthdayColors.count]
            var string = Path()
            string.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y + radius * 1.15)))
            string.addLine(to: CGPoint(x: CGFloat(x + sin(phase * 2) * 6), y: CGFloat(y + radius * 3.2)))
            context.stroke(string, with: .color(.white.opacity(0.35)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: CGFloat(x - radius), y: CGFloat(y - radius * 1.2), width: CGFloat(radius * 2), height: CGFloat(radius * 2.4))), with: .color(color.opacity(0.9)))
            context.fill(Path(ellipseIn: CGRect(x: CGFloat(x - radius * 0.55), y: CGFloat(y - radius * 0.85), width: CGFloat(radius * 0.5), height: CGFloat(radius * 0.7))), with: .color(.white.opacity(0.35)))
        }
    }

    private static func snow(_ t: Float, _ context: inout GraphicsContext, _ size: CGSize) {
        let w = Float(size.width), h = Float(size.height)
        // Four depth layers, one path each (nearer flakes are bigger and brighter).
        var layers = Array(repeating: Path(), count: 4)
        for i in 0..<snowField.count {
            let depth = snowField[i, 0]
            let radius = 1 + depth * 3
            let speed = h * (0.04 + depth * 0.09)
            let life = (h + 20) / speed
            let phase = (t + snowField[i, 1] * life).truncatingRemainder(dividingBy: life)
            let x = snowField[i, 2] * w + sin(phase * (0.6 + depth) + Float(i)) * (10 + depth * 18)
            let y = -10 + phase * speed
            layers[min(3, Int(depth * 4))].addEllipse(in: CGRect(x: CGFloat(x - radius), y: CGFloat(y - radius), width: CGFloat(radius * 2), height: CGFloat(radius * 2)))
        }
        for (layer, path) in layers.enumerated() {
            context.fill(path, with: .color(.white.opacity(0.4 + Double(layer) * 0.17)))
        }
        var stars = Path()
        var bright = Path()
        for i in 0..<14 {
            let x = snowField[i, 3] * w, y = snowField[i + 14, 3] * h * 0.45
            let twinkle = (sin(t * (1.5 + snowField[i + 28, 3] * 2) + Float(i)) + 1) / 2
            let s = 3 + twinkle * 4
            var star = Path()
            star.move(to: CGPoint(x: CGFloat(x - s), y: CGFloat(y))); star.addLine(to: CGPoint(x: CGFloat(x + s), y: CGFloat(y)))
            star.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y - s))); star.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y + s)))
            if twinkle > 0.5 { bright.addPath(star) } else { stars.addPath(star) }
        }
        let gold = Color(red: 1, green: 0.88, blue: 0.54)
        context.stroke(stars, with: .color(gold.opacity(0.45)), lineWidth: 1.3)
        context.stroke(bright, with: .color(gold.opacity(0.9)), lineWidth: 1.3)
    }

    private static func fireworks(_ t: Float, _ context: inout GraphicsContext, _ size: CGSize) {
        let w = Float(size.width), h = Float(size.height)
        let every: Float = 0.75, burstLife: Float = 1.9
        let newest = Int(t / every)
        for n in max(0, newest - 3)...max(0, newest) {
            let age = t - Float(n) * every
            if age < 0 || age > burstLife { continue }
            var r = Seeded(n * 6151 + 11)
            let cx = w * (0.15 + r.next() * 0.7)
            let cy = h * (0.12 + r.next() * 0.35)
            let base = newYearColors[n % newYearColors.count]
            let color = base == .white ? Color(red: 0.5, green: 0.86, blue: 1) : base
            let progress = age / burstLife
            let reach = min(w, h) * (0.16 + r.next() * 0.08)
            let alpha = Double(max(0, 1 - progress))
            if age < 0.25 {
                let flash = 12 + age * 60
                context.fill(Path(ellipseIn: CGRect(x: CGFloat(cx - flash), y: CGFloat(cy - flash), width: CGFloat(flash * 2), height: CGFloat(flash * 2))), with: .color(.white.opacity(Double(0.6 * (1 - age / 0.25)))))
            }
            let dist = reach * (1 - (1 - progress) * (1 - progress))
            let drop = age * age * 20
            // All tails of a burst in one path, all spark heads in another.
            var tails = Path()
            var heads = Path()
            for s in 0..<36 {
                let angle = 2 * Float.pi * Float(s) / 36 + r.next() * 0.08
                let px = cx + cos(angle) * dist, py = cy + sin(angle) * dist + drop
                tails.move(to: CGPoint(x: CGFloat(cx + cos(angle) * dist * 0.82), y: CGFloat(cy + sin(angle) * dist * 0.82 + drop)))
                tails.addLine(to: CGPoint(x: CGFloat(px), y: CGFloat(py)))
                heads.addEllipse(in: CGRect(x: CGFloat(px - 1.6), y: CGFloat(py - 1.6), width: 3.2, height: 3.2))
            }
            context.stroke(tails, with: .color(color.opacity(alpha * 0.55)), lineWidth: 1.4)
            context.fill(heads, with: .color(color.opacity(alpha)))
        }
    }
}

/// Soft background music for the greeting card (arrangements made for the
/// app: "Jingle Bells" and "Happy Birthday" are public-domain melodies; the
/// New Year tune "Năm mới bên nhau" and the Tết tune are original). Each MP3 holds one loop plus its first 0.25 s, so a
/// window of exactly one loop taken just after the decoder's start-up delay
/// repeats without a gap.
///
/// Plays while the card is open, at the media volume, also with the
/// ring/silent switch on silent (the person opened the card themselves). It
/// pauses music the person was listening to and lets it resume on close.
/// Audio session and engine work runs on its own queue, never the main thread.
@MainActor
final class CelebrationMusic {
    /// Frames skipped at the start: past any MP3 decoder delay.
    private static let startFrame: AVAudioFramePosition = 4_410
    private static let level: Float = 0.55
    /// The last decoded loop (a few MB), kept so reopening a card is instant.
    private static var cache: (key: String, buffer: AVAudioPCMBuffer)?

    private static func resource(_ key: String) -> (name: String, frames: AVAudioFrameCount) {
        switch key {
        case "christmas": return ("celebration_christmas", 1_568_000)
        case "newyear": return ("celebration_newyear", 1_840_695)
        case "tet": return ("celebration_tet", 1_840_695)
        default: return ("celebration_birthday", 1_323_000)
        }
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "net.sukavinagroup.celebration-music", qos: .userInitiated)
    private var fadeTask: Task<Void, Never>?
    private var stopped = false
    private var playing = false

    nonisolated init() {}

    func start(_ key: String) {
        Task { @MainActor [weak self] in
            // Let the card finish opening before any audio work.
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard let buffer = await Self.loop(for: key), let self, !self.stopped else { return }
            self.play(buffer)
        }
    }

    private static func loop(for key: String) async -> AVAudioPCMBuffer? {
        if let cache, cache.key == key { return cache.buffer }
        let track = Self.resource(key)
        guard let url = Bundle.main.url(forResource: track.name, withExtension: "mp3") else { return nil }
        let start = startFrame
        let buffer = await Task.detached(priority: .userInitiated) { () -> AVAudioPCMBuffer? in
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            let format = file.processingFormat
            guard format.sampleRate == 44_100,
                  let all = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: all)) != nil,
                  AVAudioFramePosition(all.frameLength) >= start + AVAudioFramePosition(track.frames),
                  let loop = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: track.frames),
                  let source = all.floatChannelData,
                  let target = loop.floatChannelData
            else { return nil }
            loop.frameLength = track.frames
            for channel in 0..<Int(format.channelCount) {
                memcpy(target[channel], source[channel] + Int(start), Int(track.frames) * MemoryLayout<Float>.size)
            }
            return loop
        }.value
        if let buffer { cache = (key, buffer) }
        return buffer
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        let engine = engine, node = node
        queue.async { [weak self] in
            let session = AVAudioSession.sharedInstance()
            do {
                // Playback: plays whatever the silent switch, and takes over
                // the sound (other music pauses).
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
                node.volume = 0
                try engine.start()
            } catch {
                return
            }
            node.scheduleBuffer(buffer, at: nil, options: .loops)
            node.play()
            Task { @MainActor in
                guard let self, !self.stopped else {
                    // Closed while the audio was being set up.
                    node.stop()
                    engine.stop()
                    return
                }
                self.playing = true
                self.fade(to: Self.level, seconds: 1.0)
            }
        }
    }

    private func fade(to target: Float, seconds: Double, then: (() -> Void)? = nil) {
        fadeTask?.cancel()
        let from = node.volume
        fadeTask = Task { @MainActor [node] in
            let steps = max(1, Int(seconds / 0.05))
            for step in 1...steps {
                if Task.isCancelled { return }
                node.volume = from + (target - from) * Float(step) / Float(steps)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            then?()
        }
    }

    func pause() {
        guard playing else { return }
        let engine = engine
        queue.async { engine.pause() }
    }

    func resume() {
        guard playing, !stopped else { return }
        let engine = engine, node = node
        queue.async {
            try? engine.start()
            node.play()
        }
    }

    /// Stops at once, with a fade too short to hear (avoids a click).
    func stop() {
        stopped = true
        guard playing else { return }
        playing = false
        let engine = engine, node = node, queue = queue
        fade(to: 0, seconds: 0.08) {
            queue.async {
                node.stop()
                engine.stop()
                // Let the music that was paused carry on.
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}
