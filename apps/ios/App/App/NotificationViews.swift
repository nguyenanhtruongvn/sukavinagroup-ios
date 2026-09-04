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

struct RequestNotification: Decodable, Identifiable {
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
    @StateObject private var requestStore = EmployeeRequestStore()
    @State private var requestNotifications: [RequestNotification] = []
    @State private var reviewing: EmployeeRequest?
    @State private var viewing: EmployeeRequest?
    @State private var meetingNotification: RequestNotification?
    @State private var confirmClear = false
    @State private var hiddenArticleIDs = Set<String>()
    private var items: [ContentItem] { (session.dashboard?.contentItems ?? []).filter { !hiddenArticleIDs.contains($0.id) } }
    private var totalUnread: Int { session.unreadCount + requestNotifications.filter { !$0.read }.count }
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
                        if !requestNotifications.isEmpty || !items.isEmpty { Button("Xóa tất cả", role: .destructive) { confirmClear = true }.font(.subheadline.bold()) }
                    }
                    .listRowBackground(notificationPageBackground)
                    .listRowSeparator(.hidden)
                    ForEach(requestNotifications) { item in
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
                          .shadow(color: isLegacyNotificationStyle ? .clear : Color.black.opacity(0.035), radius: 5, y: 2)
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
                            .shadow(color: isLegacyNotificationStyle ? .clear : Color.black.opacity(0.035), radius: 5, y: 2)
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
                    if items.isEmpty && requestNotifications.isEmpty {
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
            .hidesPortalBottomScrollEdgeEffect()
            .scrollContentBackground(.hidden)
            .background(notificationPageBackground.ignoresSafeArea()).navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
                .refreshable { await session.refreshDashboard(); await loadRequestNotifications() }
                .task { hiddenArticleIDs = Set(UserDefaults.standard.stringArray(forKey: "hidden-notification-articles") ?? []); await loadRequestNotifications() }
                .onAppear { Task { await loadRequestNotifications() } }
                .onChange(of: session.requestUnreadCount) { _, _ in Task { await loadRequestNotifications() } }
                .confirmationDialog("Xóa tất cả thông báo?", isPresented: $confirmClear, titleVisibility: .visible) { Button("Xóa tất cả", role: .destructive) { Task { await clearAll() } }; Button("Hủy", role: .cancel) {} }
                .sheet(item: $reviewing) { request in RequestDecisionView(request: request) { approved, note in await requestStore.decide(token: session.token, id: request.id, approved: approved, note: note) } }
                .sheet(item: $viewing) { request in RequestNotificationDetail(request: request) }
                .sheet(item: $meetingNotification) { notification in MeetingNotificationDetail(notification: notification) }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func loadRequestNotifications() async {
        guard let token = session.token else { return }
        if let values: [RequestNotification] = try? await APIClient.shared.request("me/requests/notifications", token: token) {
            requestNotifications = values
            session.requestUnreadCount = values.filter { !$0.read }.count
            await requestStore.load(token)
        }
    }

    private func open(_ item: RequestNotification) async {
        guard let token = session.token else { return }
        let _: UpdateCount? = try? await APIClient.shared.request("me/requests/notifications/\(item.id)/read", method: "PATCH", token: token)
        if item.type == "meeting_invite" || item.type == "meeting_reminder" {
            meetingNotification = item
        } else {
            await requestStore.load(token)
            if let id = item.requestId {
                if item.type == "request_pending", let request = requestStore.approvals.first(where: { $0.id == id && $0.status == .pending }) { reviewing = request }
                else { viewing = (requestStore.requests + requestStore.approvals).first(where: { $0.id == id }) }
            }
        }
        await loadRequestNotifications()
    }

    private func clearAll() async {
        guard let token = session.token else { return }
        let _: UpdateCount? = try? await APIClient.shared.request("me/requests/notifications", method: "DELETE", token: token)
        hiddenArticleIDs.formUnion(items.map(\.id)); UserDefaults.standard.set(Array(hiddenArticleIDs), forKey: "hidden-notification-articles")
        session.markArticlesRead(); await loadRequestNotifications()
    }

    private func deleteNotification(_ item: RequestNotification) async {
        guard let token = session.token else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            requestNotifications.removeAll { $0.id == item.id }
        }
        session.requestUnreadCount = requestNotifications.filter { !$0.read }.count
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
        if type == "meeting_invite" { return "calendar.badge.clock" }
        if type == "meeting_reminder" { return "bell.badge.fill" }
        if type == "request_pending", let request = linkedRequest(item) { return request.kind.icon }
        if type == "request_pending" { return "clock.badge.exclamationmark.fill" }
        if type.contains("rejected") { return "xmark.circle.fill" }
        if type.contains("cancelled") { return "minus.circle.fill" }
        if type.contains("auto_approved") { return "timer.circle.fill" }
        return "checkmark.seal.fill"
    }
    private func notificationColor(_ item: RequestNotification) -> Color {
        let type = item.type
        if type == "meeting_invite" || type == "meeting_reminder" { return AppTheme.red }
        if type == "request_pending", let request = linkedRequest(item) { return request.kind.color }
        if type == "request_pending" { return .orange }
        if type.contains("rejected") { return AppTheme.red }
        if type.contains("cancelled") { return .gray }
        return .green
    }
    private var isLegacyNotificationStyle: Bool {
        if #available(iOS 26.0, *) { return false }
        return true
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
        if isLegacyNotificationStyle {
            legacyNotificationSurface
        } else {
            LinearGradient(
                colors: item.read ? [AppTheme.card, AppTheme.card] : [notificationColor(item).opacity(0.24), AppTheme.card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    @ViewBuilder
    private func articleNotificationBackground(isUnread: Bool) -> some View {
        if isLegacyNotificationStyle {
            legacyNotificationSurface
        } else {
            LinearGradient(
                colors: isUnread ? [AppTheme.red.opacity(0.24), AppTheme.card] : [AppTheme.card, AppTheme.card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    @ViewBuilder
    private var legacyNotificationSeparator: some View {
        if isLegacyNotificationStyle {
            Rectangle().fill(Color.gray.opacity(0.24)).frame(height: 0.5)
        }
    }
}


@available(iOS 17.0, *)
private struct MeetingNotificationDetail: View {
    @Environment(.dismiss) private var dismiss
    let notification: RequestNotification

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: notification.type == "meeting_reminder" ? "bell.badge.fill" : "calendar.badge.clock")
                        .font(.title.bold())
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text(notification.title).font(.title2.bold())
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Nội dung cuộc họp", systemImage: "text.bubble.fill")
                            .font(.headline)
                        Text(notification.message).font(.body).foregroundStyle(.secondary)
                        Divider()
                        Label(notification.createdAt.formatted(date: .long, time: .shortened), systemImage: "clock.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Chi tiết cuộc họp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Đóng") { dismiss() } }
        }
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
