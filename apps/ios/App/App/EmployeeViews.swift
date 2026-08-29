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

/// Applies the tab-label preference to the already visible UIKit tab bar.
/// This avoids recreating SwiftUI's `TabView`, which would otherwise briefly
/// reset the screen when the switch is changed in the profile screen.
private struct TabBarLabelVisibilityUpdater: UIViewRepresentable {
    let showsLabels: Bool
    private static let tabTitles = ["Trang chủ", "Đơn từ", "Thông báo", "Tài khoản"]

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let window = uiView.window,
                  let tabBar = findTabBar(from: window) else { return }
            for (index, item) in (tabBar.items ?? []).enumerated() {
                guard Self.tabTitles.indices.contains(index) else { continue }
                let title = Self.tabTitles[index]
                item.title = showsLabels ? title : nil
                item.accessibilityLabel = title
                item.titlePositionAdjustment = .zero
                item.imageInsets = showsLabels
                    ? .zero
                    : UIEdgeInsets(top: 6, left: 0, bottom: -6, right: 0)
            }
            tabBar.items?.forEach { $0.setTitleTextAttributes(nil, for: .normal) }
            tabBar.setNeedsLayout()
        }
    }

    private func findTabBar(from window: UIWindow) -> UITabBar? {
        if let root = window.rootViewController,
           let tabBar = findTabBar(in: root) {
            return tabBar
        }
        return findTabBar(in: window)
    }

    private func findTabBar(in controller: UIViewController) -> UITabBar? {
        if let tabController = controller as? UITabBarController {
            return tabController.tabBar
        }
        for child in controller.children {
            if let tabBar = findTabBar(in: child) { return tabBar }
        }
        if let presented = controller.presentedViewController {
            return findTabBar(in: presented)
        }
        return nil
    }

    private func findTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar { return tabBar }
        for child in view.subviews {
            if let tabBar = findTabBar(in: child) { return tabBar }
        }
        return nil
    }
}








@available(iOS 17.0, *)
struct EmployeePortalView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sukavina.appearanceMode") private var appearanceMode = AppAppearanceMode.system.rawValue
    @AppStorage("sukavina.showTabLabels") private var showTabLabels = true
    @State private var selectedTab = 0
    @State private var requestInitialFilter: EmployeeRequestStatus?








    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView {
                requestInitialFilter = .pending
                selectedTab = 1
            }
                .adaptivePortalTabBarBackground()
                .tabItem {
                    Label("Trang chủ", systemImage: "house.fill")
                }
                .tag(0)
            RequestsView(initialFilter: requestInitialFilter)
                .adaptivePortalTabBarBackground()
                .tabItem {
                    Label("Đơn từ", systemImage: "doc.text.fill")
                }
                .tag(1)
            NotificationsView()
                .adaptivePortalTabBarBackground()
                .tabItem {
                    Label("Thông báo", systemImage: "bell.fill")
                }
                .badge(session.unreadCount + session.requestUnreadCount)
                .tag(3)
            ProfileView()
                .adaptivePortalTabBarBackground()
                .tabItem {
                    Label("Tài khoản", systemImage: "person.crop.circle.fill")
                }
                .tag(4)
        }
        .background(TabBarLabelVisibilityUpdater(showsLabels: showTabLabels))
        .accentColor(AppTheme.red)
        .adaptivePortalTabBarBackground()
        .preferredColorScheme(AppAppearanceMode(rawValue: appearanceMode)?.colorScheme)
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task {
                    await session.refreshDashboard()
                }
            }
        }
    }








}








@available(iOS 17.0, *)
struct TodayMenuView: View {
    // Keep the demo QR action clear of the floating tab bar on iPhone and iPad.
    @EnvironmentObject private var session: SessionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pendingChoice: String?
    @State private var showDemoScanner = false
    @State private var mealSheetHeight: CGFloat = 420








    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        PortalPageTitle("Thực đơn")
                        Text("BẾP ĂN SUKAVINA")
                            .font(.caption.bold())
                            .tracking(1.5)
                            .foregroundColor(AppTheme.red)
                        Text("Thực đơn hôm nay")
                            .font(.headline)
                        Text(session.todayMenu?.day.dayName ?? "Đang cập nhật")
                            .foregroundColor(AppTheme.muted)
                    }








                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 11) {
                        menuGroup("Món nước", icon: "takeoutbag.and.cup.and.straw.fill", color: .cyan, lines: [session.todayMenu?.day.featured])
                        menuGroup("Món thường", icon: "fork.knife", color: .orange, lines: [
                            session.todayMenu?.day.savoryMain,
                            session.todayMenu?.day.savorySide,
                            session.todayMenu?.day.vegetable,
                            session.todayMenu?.day.soup
                        ])
                        menuGroup("Món chay", icon: "leaf.fill", color: .green, lines: [
                            session.todayMenu?.day.vegetarianMain,
                            session.todayMenu?.day.vegetarianSide
                        ])
                        menuGroup("Tăng ca", icon: "moon.stars.fill", color: .purple, lines: [session.todayMenu?.day.overtime])
                    }








                    VStack(alignment: .leading, spacing: 12) {
                        if let selection = session.todayMenu?.selection {
                            let isWater = selection == "water"
                            Text("MÓN ĂN ĐÃ ĐẶT").font(.caption.bold()).tracking(1.2).foregroundColor(AppTheme.muted)
                            HStack(spacing: 14) {
                                Image(systemName: isWater ? "takeoutbag.and.cup.and.straw.fill" : "leaf.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(isWater ? .cyan : .green)
                                    .frame(width: 50, height: 50)
                                    .background((isWater ? Color.cyan : Color.green).opacity(0.14))
                                    .clipShape(RoundedRectangle(cornerRadius: 15))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(isWater ? "Món nước" : "Món chay").font(.title3.bold())
                                    Text(selectedMealDetail(selection))
                                        .font(.subheadline).foregroundColor(AppTheme.muted).lineLimit(2)
                                }
                            }
                            if session.todayMenu?.receivedAt == nil {
                                MealQRCodeAccessCard()
                            } else {
                                Label("Đã nhận món", systemImage: "checkmark.seal.fill")
                                    .font(.headline).foregroundColor(.green)
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background(Color.green.opacity(0.11))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            if session.todayMenu?.receivedAt == nil {
                                Button {
                                    pendingChoice = "cancel"
                                } label: {
                                    Label("Hủy lựa chọn hôm nay", systemImage: "xmark.circle.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.red.opacity(0.86))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                                .disabled(session.todayMenu?.orderingOpen == false)
                            }
                        } else {
                            Text("LỰA CHỌN HÔM NAY").font(.caption.bold()).tracking(1.2).foregroundColor(AppTheme.muted)
                            Text("Bạn muốn dùng món nào?").font(.title3.bold())
                            if session.todayMenu?.orderingOpen == false {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.badge.exclamationmark.fill")
                                        .font(.title3.bold())
                                        .foregroundColor(.orange)
                                        .frame(width: 42, height: 42)
                                        .background(Color.orange.opacity(0.13))
                                        .clipShape(RoundedRectangle(cornerRadius: 13))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Đã khóa đặt món").font(.headline).foregroundColor(.orange)
                                        Text("Vui lòng đặt món trước \(session.todayMenu?.orderingCutoff ?? "09:00").")
                                            .font(.caption).foregroundColor(AppTheme.muted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color.orange.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            } else {
                                mealButton("Món nước", detail: session.todayMenu?.day.featured, icon: "takeoutbag.and.cup.and.straw.fill", color: .cyan, choice: "water")
                                mealButton("Món chay", detail: [session.todayMenu?.day.vegetarianMain, session.todayMenu?.day.vegetarianSide].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), icon: "leaf.fill", color: .green, choice: "vegetarian")
                            }
                        }
                    }
                    .padding(18)
                    .background(AppTheme.card.opacity(0.86))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .frame(maxWidth: horizontalSizeClass == .regular ? 760 : .infinity)
                .frame(maxWidth: .infinity)
                .padding(20)
                .padding(.bottom, 94)
            }
            .hidesPortalBottomScrollEdgeEffect()
            .background(AppTheme.ink.ignoresSafeArea())
            .overlay(alignment: .bottomTrailing) {
                if session.profile?.employeeCode == "DEMO" {
                    Button {
                        showDemoScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 23, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 58, height: 58)
                            .background(Color.green)
                            .clipShape(Circle())
                            .shadow(color: Color.green.opacity(0.3), radius: 12, y: 6)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 18)
                }
            }
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await session.refreshTodayMenu()
                while !Task.isCancelled {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
                    let now = Date()
                    let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
                    let delay = max(1, nextDay.timeIntervalSince(now) + 0.5)
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    await session.refreshTodayMenu()
                }
            }
            .refreshable { await session.refreshTodayMenu() }
            .sheet(isPresented: $showDemoScanner) {
                CanteenScannerView()
                    .environmentObject(session)
            }
            .mealConfirmationSheet(isPresented: Binding(get: { pendingChoice != nil }, set: { if !$0 { pendingChoice = nil } })) {
                let choice = pendingChoice ?? "water"
                let cancelling = choice == "cancel"
                let receiving = choice == "received"
                let title = choice == "water" ? "Món nước" : "Món chay"
                let detail = choice == "water"
                    ? (session.todayMenu?.day.featured ?? "...")
                    : [session.todayMenu?.day.vegetarianMain, session.todayMenu?.day.vegetarianSide].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                VStack(spacing: 18) {
                    Capsule().fill(AppTheme.muted.opacity(0.35)).frame(width: 42, height: 5)
                    Image(systemName: cancelling ? "xmark.circle.fill" : (receiving ? "checkmark.circle.fill" : (choice == "water" ? "takeoutbag.and.cup.and.straw.fill" : "leaf.fill")))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(cancelling ? .red : (receiving ? .green : (choice == "water" ? .cyan : .green)))
                        .frame(width: 64, height: 64)
                        .background((cancelling ? Color.red : (choice == "water" ? Color.cyan : Color.green)).opacity(0.13))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    VStack(spacing: 7) {
                        Text(cancelling ? "Hủy lựa chọn hôm nay?" : (receiving ? "Bạn đã nhận món?" : "Xác nhận \(title)"))
                            .font(.title2.bold())
                        Text(cancelling ? "Bạn có thể chọn lại món khác bất cứ lúc nào trong ngày." : (receiving ? "Xác nhận sau khi bạn đã nhận đúng phần ăn đã đặt." : "Kiểm tra món trước khi xác nhận đặt."))
                            .font(.subheadline).foregroundColor(AppTheme.muted).multilineTextAlignment(.center)
                    }
                    if !cancelling && !receiving {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title.uppercased()).font(.caption.bold()).tracking(1).foregroundColor(AppTheme.muted)
                            Text(detail.isEmpty ? "..." : detail).font(.headline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Button {
                        pendingChoice = nil
                        Task {
                            if cancelling { await session.cancelMealSelection() }
                            else if receiving { await session.receiveMealSelection() }
                            else { await session.selectMeal(choice) }
                        }
                    } label: {
                        Text(cancelling ? "Xác nhận hủy" : (receiving ? "Xác nhận đã nhận" : "Xác nhận đặt món"))
                            .font(.headline).foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(cancelling ? Color.red : (receiving ? Color.green : AppTheme.red)).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Button("Quay lại") { pendingChoice = nil }
                        .font(.headline).foregroundColor(AppTheme.muted).padding(.vertical, 5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: MealSheetHeightPreferenceKey.self, value: proxy.size.height)
                    }
                }
                .onPreferenceChange(MealSheetHeightPreferenceKey.self) { height in
                    guard height > 0 else { return }
                    mealSheetHeight = min(max(height + 8, 300), UIScreen.main.bounds.height * 0.82)
                }
                .fittedMealSheetSizing(fallbackHeight: mealSheetHeight)
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.hidden)
                .attachedMealSheetCorners()
                .solidMealSheetBackground()
            }
        }
    }








    private func selectedMealDetail(_ selection: String) -> String {
        if selection == "water" {
            return session.todayMenu?.day.featured ?? "..."
        }
        let detail = [session.todayMenu?.day.vegetarianMain, session.todayMenu?.day.vegetarianSide]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? "..." : detail
    }








    private func menuGroup(_ title: String, icon: String, color: Color, lines: [String?]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.headline).foregroundColor(color).frame(width: 42, height: 42).background(color.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 13))
            Text(title.uppercased()).font(.caption2.bold()).tracking(1).foregroundColor(AppTheme.muted)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, value in
                Text(value?.isEmpty == false ? value! : "...")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(15)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 5, y: 2)
    }








    private func mealButton(_ title: String, detail: String?, icon: String, color: Color, choice: String) -> some View {
        let selected = session.todayMenu?.selection == choice
        let fallbackAvailable = !(detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let available = choice == "water"
            ? (session.todayMenu?.availableChoices?.water ?? fallbackAvailable)
            : (session.todayMenu?.availableChoices?.vegetarian ?? fallbackAvailable)
        return Button {
            if available { pendingChoice = choice }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.title3).foregroundColor(color).frame(width: 44, height: 44).background(color.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(available ? (detail?.isEmpty == false ? detail! : "...") : "Đang trống").font(.caption).foregroundColor(AppTheme.muted).lineLimit(1)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundColor(selected ? .green : AppTheme.muted)
            }
            .padding(13)
            .background(selected ? Color.green.opacity(0.11) : Color.white.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(color: Color.black.opacity(selected ? 0.05 : 0.03), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(session.isWorking || !available)
        .opacity(available ? 1 : 0.58)
    }
}








private struct MealSheetHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


private extension View {
    @ViewBuilder
    func mealConfirmationSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        sheet(isPresented: isPresented, content: content)
    }

    @ViewBuilder
    func attachedMealSheetCorners() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else if #available(iOS 16.4, *) {
            presentationCornerRadius(28)
        } else {
            self
        }
    }

    @ViewBuilder
    func solidMealSheetBackground() -> some View {
        self
    }

    @ViewBuilder
    func fittedMealSheetSizing(fallbackHeight: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents([.height(fallbackHeight)])
        } else {
            self
        }
    }
}








@available(iOS 17.0, *)
struct DashboardView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var requestStore = EmployeeRequestStore()
    let openPendingRequests: () -> Void








    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PortalPageTitle("Trang chủ")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Xin chào,")
                            .foregroundColor(AppTheme.muted)
                        Text(session.dashboard?.name ?? session.profile?.name ?? "Nhân viên")
                            .font(.title2.bold())
                        Text(session.dashboard?.employeeCode ?? session.profile?.employeeCode ?? "")
                            .font(.subheadline.monospaced())
                            .foregroundColor(AppTheme.red)
                    }








                    HStack(spacing: 12) {
                        MetricCard(value: "\(session.dashboard?.remainingLeaveDays ?? 0)", label: "Ngày phép còn lại", icon: "calendar.badge.clock")
                        Button(action: openPendingRequests) {
                            MetricCard(
                                value: "\(requestStore.requests.filter { $0.status == .pending }.count)",
                                label: "Đơn đang chờ",
                                icon: "doc.text.fill"
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Xem đơn từ đang chờ")
                    }








                    NavigationLink(destination: ModernAttendanceHistoryView()) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Chấm công hôm nay").font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(AppTheme.red)
                            }
                            Divider().overlay(Color.white.opacity(0.08))
                            HStack(spacing: 0) {
                                attendanceMetric(title: "Giờ vào", value: checkInTime, color: .green)
                                Divider().frame(height: 38).overlay(Color.white.opacity(0.08))
                                attendanceMetric(title: "Giờ ra", value: checkOutTime, color: AppTheme.red)
                            }
                        }
                        .padding(16)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)








                }
                .padding(20)
                .padding(.bottom, 92)
            }
            .hidesPortalBottomScrollEdgeEffect()
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .task { await requestStore.load(session.token) }
            .task(id: session.requestRevision) {
                guard session.requestRevision > 0 else { return }
                await requestStore.load(session.token)
            }
            .refreshable {
                await session.refreshDashboard()
                await requestStore.load(session.token)
            }
        }
        .navigationViewStyle(.stack)
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








    private func attendanceTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            return value
        }
        return date.formatted(date: .omitted, time: .standard)
    }








    private var checkInTime: String {
        guard let record = session.dashboard?.attendanceRecords?.last else { return "--:--" }
        return attendanceTime(record.punchedAt)
    }








    private var checkOutTime: String {
        guard let records = session.dashboard?.attendanceRecords, records.count > 1,
              let record = records.first else { return "--:--" }
        return attendanceTime(record.punchedAt)
    }
}








@available(iOS 17.0, *)
struct ModernAttendanceHistoryView: View {
    private static let absentColor = Color(red: 0.78, green: 0.07, blue: 0.11)








    @EnvironmentObject private var session: SessionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("sukavina.attendanceMonthDisplayMode") private var attendanceMonthDisplayMode = AttendanceMonthDisplayMode.compact.rawValue
    @State private var selectedMonth = Self.monthValue(Date())
    @State private var cache: [String: AttendanceMonth] = [:]
    @State private var errors: [String: String] = [:]
    @State private var selectedDates: [String: String] = [:]
    @State private var monthIndex = 1








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
                    .background(AttendanceScrollInsetNeutralizer())
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        }
        .background(AppTheme.ink.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle("Bảng chấm công")
        .navigationBarTitleDisplayMode(.inline)
        .adaptivePortalTabBarBackground()
        .onChange(of: monthIndex) { _, newIndex in
            guard options.indices.contains(newIndex) else { return }
            selectedMonth = options[newIndex]
            UISelectionFeedbackGenerator().selectionChanged()
        }
        .task { await preloadAdjacentMonths() }
        .task(id: session.attendanceRevision) {
            guard session.attendanceRevision > 0 else { return }
            cache.removeAll()
            errors.removeAll()
            await preloadAdjacentMonths()
        }
    }








    private func preloadedMonthPage(_ index: Int) -> some View {
        let month = options[index]
        let data = cache[month]
        return ScrollView {
            VStack(spacing: 14) {
                if let data {
                    preloadedSummaryCards(data)
                    preloadedCalendarCard(data, month: month)
                    if !showsFullMonthAttendance, let day = selectedDay(in: data, month: month) {
                        preloadedDayDetail(day, data: data)
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
            .background(AttendanceScrollInsetNeutralizer())
        }
        .hidesPortalBottomScrollEdgeEffect()
        .task(id: month) { await preloadMonth(month) }
    }








    private func preloadedSummaryCards(_ data: AttendanceMonth) -> some View {
        let values: [(String, Int, Color)] = [
            ("Ngày công", preloadedCount("present", in: data), .green),
            ("Đi trễ", preloadedCount("late", in: data), EmployeeRequestKind.late.color),
            ("Về sớm", preloadedCount("early", in: data), EmployeeRequestKind.early.color),
            ("Nghỉ phép", preloadedCount("leave", in: data), EmployeeRequestKind.leave.color),
            ("Vắng", preloadedCount("absent", in: data), Self.absentColor),
            ("Làm thêm", preloadedCount("overtime", in: data), EmployeeRequestKind.overtime.color),
        ].filter { $0.1 > 0 }
        return HStack(spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                summary(item.1, item.0, item.2)
            }
        }
        // Keep the complete overview on one row, even when the system uses a
        // larger accessibility text size. Individual cards scale their text
        // down instead of wrapping to a second line or overflowing the screen.
        .dynamicTypeSize(.xSmall ... .accessibility1)
    }








    private func preloadedCalendarCard(_ data: AttendanceMonth, month: String) -> some View {
        let cellHeight: CGFloat = showsFullMonthAttendance ? 78 : 50
        return VStack(alignment: .leading, spacing: 14) {
            Text("Lịch chấm công").font(.headline).foregroundStyle(Color.primary)
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
                ForEach(data.days) { day in
                    let selected = selectedDay(in: data, month: month)?.date == day.date
                    Button {
                        selectedDates[month] = day.date
                    } label: {
                        VStack(spacing: showsFullMonthAttendance ? 3 : 0) {
                            Text(String(Int(day.date.suffix(2)) ?? 0))
                                .font(.subheadline.weight(selected ? .bold : .medium))
                                .foregroundStyle(dayStatuses(day).contains("absent") ? Self.absentColor : Color.primary)
                            if showsFullMonthAttendance {
                                VStack(spacing: 1) {
                                    Text(time(day.checkIn))
                                    Text(time(day.checkOut))
                                }
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.primary.opacity(0.72))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            }
                        }
                            .frame(maxWidth: .infinity, minHeight: cellHeight)
                            .background(dayBackground(day))
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(selected ? Color(red: 0.05, green: 0.25, blue: 0.5) : .clear, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var showsFullMonthAttendance: Bool {
        attendanceMonthDisplayMode == AttendanceMonthDisplayMode.full.rawValue
    }








    private func preloadedCount(_ status: String, in data: AttendanceMonth) -> Int {
        data.days.filter { dayStatuses($0).contains(status) }.count
    }








    private func preloadedLeadingEmptyDays(_ data: AttendanceMonth) -> Int {
        guard let value = data.days.first?.date, let date = Self.dayParser.date(from: value) else { return 0 }
        return (Calendar(identifier: .gregorian).component(.weekday, from: date) + 5) % 7
    }








    private func selectedDay(in data: AttendanceMonth, month: String) -> AttendanceDay? {
        if let selected = selectedDates[month], let day = data.days.first(where: { $0.date == selected }) {
            return day
        }
        return data.days.first(where: { $0.date == Self.dayValue(Date()) }) ?? data.days.last
    }








    private func preloadedDayDetail(_ day: AttendanceDay, data: AttendanceMonth) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Chi tiết ngày \(displayDate(day.date))", systemImage: "calendar")
                .font(.headline).foregroundStyle(Color.primary)
            Divider()
            detailRow("Giờ vào", time(day.checkIn))
            detailRow("Giờ ra", time(day.checkOut))
            detailRow("Trạng thái", dayStatuses(day).map(statusTitle).joined(separator: " · "))
            detailRow(
                "Khung giờ \(data.department ?? "phòng ban")",
                "\(day.startTime ?? data.startTime ?? "--:--") - \(day.endTime ?? data.endTime ?? "--:--")"
            )
        }
        .padding(18)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }








    private func preloadMonth(_ month: String) async {
        guard cache[month] == nil, let token = session.token else { return }
        do {
            let loaded: AttendanceMonth = try await APIClient.shared.request(
                "me/attendance?month=\(month)", token: token
            )
            cache[month] = loaded
            errors.removeValue(forKey: month)
            if selectedDates[month] == nil {
                selectedDates[month] = loaded.days.first(where: { $0.date == Self.dayValue(Date()) })?.date
                    ?? loaded.days.last?.date
            }
        } catch {
            errors[month] = error.localizedDescription
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
        VStack(spacing: 3) {
            Text("\(value)").font(.title3.bold()).foregroundStyle(color)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 15))
    }








    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(AppTheme.muted); Spacer(); Text(value).bold() }
    }








    private var options: [String] {
        Array(
            (0..<2).compactMap { Calendar.current.date(byAdding: .month, value: -$0, to: Date()) }
                .map(Self.monthValue)
                .reversed()
        )
    }
    private var monthTitle: String { monthTitle(for: selectedMonth) }








    private func monthTitle(for month: String) -> String {
        guard let date = Self.monthParser.date(from: month) else { return month }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "'Tháng' M / yyyy"; return formatter.string(from: date)
    }
    private func dayStatuses(_ day: AttendanceDay) -> [String] {
        day.statuses ?? day.status.map { [$0] } ?? []
    }
    @ViewBuilder private func dayBackground(_ day: AttendanceDay) -> some View {
        let statuses = dayStatuses(day)
        if statuses.contains("late") && statuses.contains("early") {
            HStack(spacing: 0) {
                EmployeeRequestKind.late.color.opacity(0.34)
                EmployeeRequestKind.early.color.opacity(0.36)
            }
        } else {
            dayColor(statuses.first)
        }
    }
    private func dayColor(_ status: String?) -> Color {
        switch status {
        case "present": return .green.opacity(0.32)
        case "late": return .orange.opacity(0.34)
        case "early": return EmployeeRequestKind.early.color.opacity(0.36)
        case "leave": return EmployeeRequestKind.leave.color.opacity(0.32)
        case "absent": return Self.absentColor.opacity(0.46)
        case "overtime": return EmployeeRequestKind.overtime.color.opacity(0.36)
        case "weekend": return .gray.opacity(0.13)
        case "not-started": return .gray.opacity(0.18)
        case "upcoming": return AppTheme.muted.opacity(0.1)
        default: return AppTheme.muted.opacity(0.1)
        }
    }
    private func statusTitle(_ status: String?) -> String {
        switch status {
        case "present": return "Đủ công"
        case "late": return "Đi trễ"
        case "early": return "Về sớm"
        case "leave": return "Nghỉ phép"
        case "absent": return "Vắng"
        case "overtime": return "Làm thêm giờ"
        case "weekend": return "Cuối tuần"
        case "not-started": return "Chưa vào làm"
        case "upcoming": return "Chưa tới"
        default: return "Chưa xác định"
        }
    }
    private func time(_ value: String?) -> String {
        guard let value else { return "--:--" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return "--:--" }
        return date.formatted(date: .omitted, time: .shortened)
    }
    private func displayDate(_ value: String) -> String {
        guard let date = Self.dayParser.date(from: value) else { return value }
        let formatter = DateFormatter(); formatter.dateFormat = "dd/MM/yyyy"; return formatter.string(from: date)
    }
    private func preloadAdjacentMonths() async {
        for month in options where cache[month] == nil {
            await preloadMonth(month)
        }
    }
    private static func monthValue(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"; return formatter.string(from: date)
    }
    private static func dayValue(_ date: Date) -> String { dayParser.string(from: date) }
    private static let monthParser: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"; return formatter
    }()
    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = "yyyy-MM-dd"; return formatter
    }()
}








@available(iOS 17.0, *)
struct MetricCard: View {
    let value: String
    let label: String
    let icon: String








    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).foregroundColor(AppTheme.red)
            Text(value).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.65)
            Text(label).font(.caption).foregroundColor(AppTheme.muted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
