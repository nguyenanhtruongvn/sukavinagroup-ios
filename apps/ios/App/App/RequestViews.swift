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

private struct GrowingRequestReasonEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool

    let minimumHeight: CGFloat
    let maximumHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 13, left: 12, bottom: 13, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.alwaysBounceVertical = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            textView.text = text
        }
        if isFocused && !textView.isFirstResponder {
            textView.becomeFirstResponder()
        } else if !isFocused && textView.isFirstResponder {
            textView.resignFirstResponder()
        }
        DispatchQueue.main.async {
            updateHeight(for: textView)
        }
    }

    private func updateHeight(for textView: UITextView) {
        let width = max(textView.bounds.width, 1)
        let fittedHeight = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let resolvedHeight = min(max(fittedHeight, minimumHeight), maximumHeight)
        textView.isScrollEnabled = fittedHeight > maximumHeight
        guard abs(height - resolvedHeight) > 0.5 else { return }
        height = resolvedHeight
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingRequestReasonEditor

        init(parent: GrowingRequestReasonEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.updateHeight(for: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
    }
}

enum EmployeeRequestStatus: String, Codable, CaseIterable {
    case pending, approved, rejected, cancelled
    var title: String {
        switch self { case .pending: return "Chờ duyệt"; case .approved: return "Đã duyệt"; case .rejected: return "Từ chối"; case .cancelled: return "Đã hủy" }
    }
    var color: Color {
        switch self { case .pending: return .orange; case .approved: return .green; case .rejected: return AppTheme.red; case .cancelled: return .gray }
    }
}

enum EmployeeRequestKind: String, Codable, CaseIterable, Identifiable {
    // "sunday" (Làm chủ nhật) only ever comes from EmployeeRequest.kind below:
    // the API stores it as "overtime" with sundayWork, so released apps can
    // still decode the request list.
    case leave, late, early, overtime, business, attendance, gate, sunday
    var id: String { rawValue }
    var title: String {
        switch self { case .leave: return "Xin nghỉ"; case .late: return "Đi trễ"; case .early: return "Về sớm"; case .overtime: return "Làm thêm giờ"; case .business: return "Công tác"; case .attendance: return "Xác nhận giờ công"; case .gate: return "Ra cổng"; case .sunday: return "Làm chủ nhật" }
    }
    var icon: String {
        switch self {
        case .leave: return "calendar.badge.minus"
        case .late: return "clock.badge.exclamationmark"
        case .early: return "figure.walk.departure"
        case .overtime: return "moon.stars.fill"
        case .business: return "airplane"; case .attendance: return "checkmark.circle"; case .gate: return "rectangle.portrait.and.arrow.right"
        case .sunday: return "calendar"
        }
    }
    var color: Color {
        switch self {
        case .leave: return .blue
        case .late: return .orange
        case .early: return Color(red: 0.9, green: 0.22, blue: 0.52)
        case .overtime: return Color(red: 124.0 / 255.0, green: 58.0 / 255.0, blue: 237.0 / 255.0)
        case .business: return Color(red: 0.0, green: 0.5, blue: 0.5); case .attendance: return .green; case .gate: return .purple
        case .sunday: return Color(red: 249.0 / 255.0, green: 115.0 / 255.0, blue: 22.0 / 255.0)
        }
    }
}

struct EmployeeRequest: Codable, Identifiable {
    struct EmployeeSummary: Codable {
        let fullName: String
        let employeeCode: String
        let department: String?
    }
    let id: String
    private let storedKind: EmployeeRequestKind
    /// Set on "Làm chủ nhật" requests, which the API stores as "overtime".
    let sundayWork: Bool?
    /// The kind shown in the app.
    var kind: EmployeeRequestKind { sundayWork == true && storedKind == .overtime ? .sunday : storedKind }
    let from: Date
    let to: Date
    let reason: String
    let status: EmployeeRequestStatus
    let createdAt: Date
    let dueAt: Date
    let decisionNote: String?
    let autoApproved: Bool
    let employee: EmployeeSummary?
    // Business-trip details, used to prefill a resubmitted request.
    let businessDestination: String?
    let businessTransport: String?
    let businessDistanceKm: Double?
    let businessExpense: Double?

    enum CodingKeys: String, CodingKey {
        case id, reason, status, createdAt, dueAt, decisionNote, autoApproved, employee
        case storedKind = "kind"
        case sundayWork
        case businessDestination, businessTransport, businessDistanceKm, businessExpense
        case from = "startsAt"
        case to = "endsAt"
    }
}

struct RequestBody: Encodable { let kind: String; let startsAt: Date; let endsAt: Date; let reason: String; let businessDestination: String?; let businessTransport: String?; let businessDistanceKm: Double?; let businessExpense: Double? }
struct RequestDecisionBody: Encodable { let status: String; let note: String? }

@MainActor
final class EmployeeRequestStore: ObservableObject {
    private struct CachedRequests: Codable {
        let savedAt: Date
        let requests: [EmployeeRequest]
        let approvals: [EmployeeRequest]
    }

    @Published private(set) var requests: [EmployeeRequest] = [] { didSet { rebuildIndex() } }
    @Published private(set) var approvals: [EmployeeRequest] = [] { didSet { rebuildIndex() } }
    /// Derived once per change of the lists, not on every redraw of the
    /// screens that show them (they redraw far more often than data changes).
    private var byID: [String: EmployeeRequest] = [:]
    private var pendingApprovalIDs: Set<String> = []
    private var ownIDs: Set<String> = []
    /// Approvals and own requests, de-duplicated, newest first.
    private(set) var combined: [EmployeeRequest] = []
    private var combinedByStatus: [EmployeeRequestStatus: [EmployeeRequest]] = [:]

    func request(id: String) -> EmployeeRequest? { byID[id] }

    /// The combined list, optionally only one status.
    func list(status: EmployeeRequestStatus?) -> [EmployeeRequest] {
        guard let status else { return combined }
        return combinedByStatus[status] ?? []
    }

    /// An approval assigned to this user that still awaits a decision.
    func isPendingApproval(_ id: String) -> Bool { pendingApprovalIDs.contains(id) }

    /// The user's own rejected request, which can be sent again. A request this
    /// user rejected as an approver belongs to someone else.
    func canResubmit(_ request: EmployeeRequest) -> Bool {
        request.status == .rejected && ownIDs.contains(request.id)
    }

    private func rebuildIndex() {
        byID = Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .merging(approvals.map { ($0.id, $0) }, uniquingKeysWith: { mine, _ in mine })
        pendingApprovalIDs = Set(approvals.lazy.filter { $0.status == .pending }.map(\.id))
        ownIDs = Set(requests.lazy.map(\.id))
        var seen = Set<String>()
        combined = (approvals + requests)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt > $1.createdAt }
        combinedByStatus = Dictionary(grouping: combined, by: \.status)
    }
    @Published var message: String?
    /** A first load is running and nothing is known yet. */
    @Published private(set) var isLoading = false
    /** The first load failed and nothing is cached; the lists show a retry. */
    @Published private(set) var loadError: String?
    var hasLoaded: Bool { lastLoadedAt != nil }
    private let cachePrefix = "native-employee-requests-cache-"
    private var cacheEmployeeCode: String?
    private var lastLoadedAt: Date?
    private var loadTask: Task<Void, Never>?
    private var loadTaskID: UUID?
    /// A forced load arrived while one was running: run once more.
    private var rerunRequested = false
    private let refreshTTL: TimeInterval = 60

    /// Restore first so a previously loaded request list remains usable when
    /// the network is unavailable. Data is namespaced to the signed-in person.
    func restoreCache(employeeCode: String?) {
        guard let employeeCode = employeeCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !employeeCode.isEmpty else { return }
        // Shared by the Requests and Notifications tabs: once this account's
        // lists are in memory, the disk copy is never newer.
        if cacheEmployeeCode == employeeCode, lastLoadedAt != nil { return }
        cacheEmployeeCode = employeeCode
        guard let data = AccountDocumentStore.shared.data(forKey: cachePrefix + employeeCode),
              let cached = try? JSONDecoder().decode(CachedRequests.self, from: data) else { return }
        // Shown until replaced (offline included); lastLoadedAt = savedAt
        // makes an old copy revalidate at once.
        requests = cached.requests
        approvals = cached.approvals
        lastLoadedAt = cached.savedAt
    }

    /// Sign-out: the next account must not see these lists.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        loadTaskID = nil
        rerunRequested = false
        requests = []
        approvals = []
        message = nil
        cacheEmployeeCode = nil
        lastLoadedAt = nil
        isLoading = false
        loadError = nil
    }

    private func saveCache() {
        guard let employeeCode = cacheEmployeeCode,
              let data = try? JSONEncoder().encode(CachedRequests(savedAt: Date(), requests: requests, approvals: approvals)) else { return }
        AccountDocumentStore.shared.set(data, forKey: cachePrefix + employeeCode)
    }

    private static func actionMessage(_ error: Error, fallback: String) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    func load(_ token: String?, force: Bool = false) async {
        guard let token else { return }

        if !force,
           let lastLoadedAt,
           Date().timeIntervalSince(lastLoadedAt) < refreshTTL {
            return
        }

        if let existing = loadTask {
            // The running request may predate the change a forced load
            // reacts to; joining it could keep showing the old lists.
            if force { rerunRequested = true }
            await existing.value
            return
        }

        let taskID = UUID()
        if !hasLoaded { isLoading = true }
        loadError = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }
            do {
                var loadedRequests: [EmployeeRequest]
                var loadedApprovals: [EmployeeRequest]
                repeat {
                    self.rerunRequested = false
                    async let mine: [EmployeeRequest] = APIClient.shared.request("me/requests", token: token)
                    async let assigned: [EmployeeRequest] = APIClient.shared.request("me/requests/approvals", token: token)
                    loadedRequests = try await mine
                    loadedApprovals = try await assigned
                } while self.rerunRequested && !Task.isCancelled
                guard !Task.isCancelled else { return }
                self.requests = loadedRequests
                self.approvals = loadedApprovals
                self.lastLoadedAt = Date()
                self.saveCache()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // Lists already shown (cache or an earlier load) stay a valid
                // offline result; with nothing known the screens show a retry.
                if !self.hasLoaded {
                    self.loadError = Self.actionMessage(error, fallback: "Không tải được danh sách đơn.")
                }
            }
        }

        loadTask = task
        loadTaskID = taskID
        await task.value
        if loadTaskID == taskID {
            loadTask = nil
            loadTaskID = nil
        }
    }

    /// Nil on success, otherwise the message to show in the form (which stays open).
    func submit(token: String?, kind: EmployeeRequestKind, from: Date, to: Date, reason: String, destination: String? = nil, transport: String? = nil, distanceKm: Double? = nil, expense: Double? = nil) async -> String? {
        guard let token else { return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại." }
        do {
            loadTask?.cancel()
            loadTask = nil
            loadTaskID = nil
            let created: EmployeeRequest = try await APIClient.shared.request(
                "me/requests",
                method: "POST",
                token: token,
                body: RequestBody(
                    kind: kind.rawValue,
                    startsAt: from,
                    endsAt: to,
                    reason: reason,
                    businessDestination: destination,
                    businessTransport: transport,
                    businessDistanceKm: distanceKm,
                    businessExpense: expense
                )
            )
            requests.removeAll { $0.id == created.id }
            requests.insert(created, at: 0)
            lastLoadedAt = Date()
            saveCache()
            Task { [weak self] in await self?.load(token, force: true) }
            return nil
        } catch {
            return Self.actionMessage(error, fallback: "Không gửi được đơn. Vui lòng thử lại.")
        }
    }

    /// Nil on success, otherwise the message to show.
    func cancel(token: String?, id: String) async -> String? {
        guard let token else { return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại." }
        do {
            loadTask?.cancel()
            loadTask = nil
            loadTaskID = nil
            let cancelled: EmployeeRequest = try await APIClient.shared.request(
                "me/requests/\(id)",
                method: "DELETE",
                token: token
            )
            if let index = requests.firstIndex(where: { $0.id == id }) {
                requests[index] = cancelled
            } else {
                requests.insert(cancelled, at: 0)
            }
            approvals.removeAll { $0.id == id }
            lastLoadedAt = Date()
            saveCache()
            Task { [weak self] in await self?.load(token, force: true) }
            return nil
        } catch {
            return Self.actionMessage(error, fallback: "Không hủy được đơn. Vui lòng thử lại.")
        }
    }

    /// Nil on success, otherwise the message to show in the decision sheet.
    func decide(token: String?, id: String, approved: Bool, note: String) async -> String? {
        guard let token else { return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại." }
        do {
            loadTask?.cancel()
            loadTask = nil
            loadTaskID = nil
            let decided: EmployeeRequest = try await APIClient.shared.request(
                "me/requests/\(id)/decision",
                method: "PATCH",
                token: token,
                body: RequestDecisionBody(
                    status: approved ? "approved" : "rejected",
                    note: note.isEmpty ? nil : note
                )
            )
            if let index = approvals.firstIndex(where: { $0.id == id }) {
                approvals[index] = decided
            } else {
                approvals.insert(decided, at: 0)
            }
            lastLoadedAt = Date()
            saveCache()
            Task { [weak self] in await self?.load(token, force: true) }
            return nil
        } catch {
            return Self.actionMessage(error, fallback: "Không xử lý được đơn. Vui lòng thử lại.")
        }
    }
}

struct RequestsView: View {
    @Environment(\.sessionActions) private var actions
    /// Methods and non-published values only; observing the whole session
    /// redrew this screen on every unrelated session change.
    private var session: SessionStore { actions.store }
    @EnvironmentObject private var revisions: DataRevisions
    // One store per session, shared with the Notifications tab.
    @EnvironmentObject private var store: EmployeeRequestStore
    let initialFilter: EmployeeRequestStatus?
    @State private var filter: EmployeeRequestStatus?
    @State private var composing = false
    /// A rejected request being sent again.
    @State private var resubmitting: EmployeeRequest?
    @State private var reviewing: EmployeeRequest?
    @State private var cancelling: EmployeeRequest?
    @State private var filterIndex = 0

    var body: some View {
        NavigationStack {
            // Every version hosts this page in a native tab bar controller
            // (iOS 17 too, LegacyEmployeePortalController). The pager runs
            // under the translucent bar and the button floats above it. The
            // former iOS 17 branch reserved a bottom safe-area inset for an
            // app-drawn tab bar that no longer exists: it covered the list
            // with an empty strip above the tab bar.
            requestPages
                .overlay(alignment: .bottomTrailing) {
                    createRequestButton
                        .padding(.trailing, 20)
                        .padding(.bottom, 18)
                }
            .background(AppTheme.ink.ignoresSafeArea()).navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $composing) {
                RequestComposer { kind, from, to, reason, destination, transport, distance, expense in
                    await store.submit(token: session.token, kind: kind, from: from, to: to, reason: reason, destination: destination, transport: transport, distanceKm: distance, expense: expense)
                }
                    .presentationDetents([.large])
                    // Let a downward pull dismiss the composer sheet instead
                    // of being retained by its form scroll view.
                    .presentationContentInteraction(.resizes)
                    .presentationDragIndicator(.hidden)
                    .logsSheetFlow("requests.composing")
            }
            .sheet(item: $resubmitting) { request in
                RequestComposer(template: request) { kind, from, to, reason, destination, transport, distance, expense in
                    await store.submit(token: session.token, kind: kind, from: from, to: to, reason: reason, destination: destination, transport: transport, distanceKm: distance, expense: expense)
                }
                    .presentationDetents([.large])
                    .presentationContentInteraction(.resizes)
                    .presentationDragIndicator(.hidden)
                    .logsSheetFlow("requests.resubmitting")
            }
            .sheet(item: $reviewing) { request in
                RequestDecisionView(request: request) { approved, note in
                    await store.decide(token: session.token, id: request.id, approved: approved, note: note)
                }
                .logsSheetFlow("requests.reviewing")
            }
            .alert(item: $cancelling) { request in
                Alert(
                    title: Text("Hủy đơn này?"),
                    message: Text("Đơn \(request.kind.title) sẽ chuyển sang trạng thái đã hủy và người quản lý sẽ nhận được thông báo. Thao tác không thể hoàn tác."),
                    primaryButton: .destructive(Text("Xác nhận hủy")) {
                        Task {
                            if let error = await store.cancel(token: session.token, id: request.id) {
                                store.message = error
                            } else {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            }
                        }
                    },
                    secondaryButton: .cancel(Text("Giữ lại"))
                )
            }
            .task {
                store.restoreCache(employeeCode: session.profile?.employeeCode ?? session.dashboard?.employeeCode)
                await store.load(session.token)
            }
            // A realtime request_changed event (another device, a manager's
            // decision) reloads this shared store in SessionStore, once for
            // the Requests and Notifications screens alike.
            .alert("Đơn từ", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("Đóng") { store.message = nil } } message: { Text(store.message ?? "") }
        }
    }

    // Share the same pager, filters and state between iOS 17 and 18+.
    private var requestPages: some View {
        VStack(spacing: 10) {
            PortalPageTitle("Đơn từ")
                .padding(.horizontal, 20)
                .padding(.top, 12)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterButton("Tất cả", nil)
                        ForEach(EmployeeRequestStatus.allCases, id: \.self) { filterButton($0.title, $0) }
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: filterIndex) { _, newIndex in
                    guard filterOptions.indices.contains(newIndex) else { return }
                    withAnimation(.easeInOut(duration: 0.24)) {
                        proxy.scrollTo(filterID(filterOptions[newIndex]), anchor: .center)
                    }
                }
            }

            // Only the scrollable pager draws under the system tab bar; its
            // scroll views still inset their content by the safe area.
            requestPager
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .padding(.top, 8)
        .onChange(of: filterIndex) { _, newIndex in
            guard filterOptions.indices.contains(newIndex) else { return }
            filter = filterOptions[newIndex]
            UISelectionFeedbackGenerator().selectionChanged()
        }
        .onChange(of: initialFilter, initial: true) { _, value in
            selectFilter(value, animated: false)
        }
    }

    private var requestPager: some View {
        TabView(selection: $filterIndex) {
            ForEach(filterOptions.indices, id: \.self) { index in
                requestPage(filterOptions[index])
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeInOut(duration: 0.22), value: filterIndex)
    }

    /// Apple's prominent button in its circle shape, where the drawn red
    /// circle was. It stays over the list: the navigation bar is hidden on
    /// every tab, which draws its own title.
    private var createRequestButton: some View {
        Button { composing = true } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(AppTheme.red)
        .accessibilityLabel("Tạo đơn mới")
    }

    private func filterButton(_ title: String, _ value: EmployeeRequestStatus?) -> some View {
        Button(title) {
            selectFilter(value)
        }.font(.subheadline.bold()).padding(.horizontal, 14).padding(.vertical, 9)
            .background(filter == value ? AppTheme.red : AppTheme.card)
            .foregroundStyle(filter == value ? Color.white : Color.primary)
            .overlay(Capsule().stroke(filter == value ? Color.clear : Color.primary.opacity(0.12), lineWidth: 1))
            .clipShape(Capsule())
            .id(filterID(value))
    }

    private func selectFilter(_ value: EmployeeRequestStatus?, animated: Bool = true) {
        guard let index = filterOptions.firstIndex(where: { $0 == value }) else { return }
        let update = {
            filter = value
            filterIndex = index
        }
        if animated { withAnimation(.easeInOut(duration: 0.22), update) }
        else { update() }
    }

    private func filterID(_ value: EmployeeRequestStatus?) -> String {
        value?.rawValue ?? "all"
    }

    private var filterOptions: [EmployeeRequestStatus?] {
        [nil] + EmployeeRequestStatus.allCases.map(Optional.some)
    }

    @ViewBuilder private func requestPage(_ status: EmployeeRequestStatus?) -> some View {
        let requests = store.list(status: status)
        ScrollView(showsIndicators: false) {
            // "No requests" only once the lists are known; before that show
            // loading, or the failure with a retry.
            if requests.isEmpty, let loadError = store.loadError {
                ContentUnavailableView {
                    Label("Không tải được danh sách đơn", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Thử lại") { Task { await store.load(session.token, force: true) } }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.red)
                }
                .padding(.top, 70)
            } else if requests.isEmpty, !store.hasLoaded {
                ProgressView("Đang tải đơn từ…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 90)
            } else if requests.isEmpty {
                ContentUnavailableView(
                    "Chưa có đơn",
                    systemImage: "doc.text",
                    description: Text("Không có đơn trong trạng thái này.")
                )
                .padding(.top, 70)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(requests) { request in
                        if store.isPendingApproval(request.id) {
                            Button { reviewing = request } label: {
                                RequestCard(request: request, canCancel: false, cancel: {})
                            }
                            .buttonStyle(.plain)
                        } else if store.canResubmit(request) {
                            Button { resubmitting = request } label: {
                                RequestCard(request: request, canCancel: false, resubmittable: true, cancel: {})
                            }
                            .buttonStyle(.plain)
                        } else {
                            RequestCard(request: request) { cancelling = request }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.load(session.token, force: true) }
    }
}

struct RequestCard: View {
    let request: EmployeeRequest
    var canCancel = true
    /// The user's rejected request: tapping the card opens it to send again.
    var resubmittable = false
    let cancel: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesExpandedLayout: Bool { dynamicTypeSize > .large }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if usesExpandedLayout {
                expandedHeader
            } else {
                compactHeader
            }

            requestPeriod
            Text(request.reason)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let note = request.decisionNote, !note.isEmpty { Label(note, systemImage: "text.bubble").font(.caption).foregroundStyle(AppTheme.muted) }
            if canCancel && request.status == .pending { Button("Hủy đơn", role: .destructive, action: cancel).font(.subheadline.bold()).frame(maxWidth: .infinity, alignment: .trailing) }
            if resubmittable {
                Label("Tạo lại đơn", systemImage: "arrow.clockwise")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.redText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.padding(16).background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)).shadow(color: Color.black.opacity(0.035), radius: 5, y: 2)
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            requestIcon
            VStack(alignment: .leading, spacing: 6) {
                Text(creatorName)
                    .font(.headline)
                    .lineLimit(1)
                    .layoutPriority(1)
                HStack(spacing: 7) {
                    kindBadge
                    departmentLabel
                    Spacer(minLength: 4)
                    statusBadge
                }
            }
        }
    }

    private var expandedHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                requestIcon
                Text(creatorName)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                kindBadge
                departmentLabel
                Spacer(minLength: 8)
                statusBadge
            }
        }
    }

    private var creatorName: String {
        let name = request.employee?.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = request.employee?.employeeCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return "Đơn của tôi" }
        guard let code, !code.isEmpty else { return name }
        return "\(name) · \(code)"
    }

    private var departmentLabel: some View {
        Text(departmentName)
            .font(.caption)
            .foregroundStyle(AppTheme.muted)
            .lineLimit(1)
    }

    private var departmentName: String {
        let department = request.employee?.department?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return department.isEmpty ? "Chưa cập nhật bộ phận" : department
    }

    private var requestIcon: some View {
        Image(systemName: request.kind.icon)
            .frame(width: 42, height: 42)
            .background(request.kind.color.opacity(0.16))
            .foregroundStyle(request.kind.color)
            .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var kindBadge: some View {
        Text(request.kind.title)
            .font(.caption.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(request.kind.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(request.kind.color.opacity(0.14))
            .clipShape(Capsule())
    }

    private var statusBadge: some View {
        Text(request.status.title)
            .font(.caption.bold())
            .lineLimit(1)
            .foregroundStyle(request.status.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(request.status.color.opacity(0.14))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var requestPeriod: some View {
        // Two labelled rows remain unambiguous even when the dates span days.
        VStack(alignment: .leading, spacing: 6) {
            requestPeriodLine("Từ", request.from)
            requestPeriodLine("Đến", request.to)
        }
    }

    private func requestPeriodLine(_ title: String, _ date: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title + ":")
                .font(.subheadline.weight(.semibold))
            Text(date.requestDateTimeText)
                .font(.subheadline)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(AppTheme.muted)
    }
}

extension Date {
    var requestDateTimeText: String {
        VietnamTime.clockDate.string(from: self)
    }
}

struct RequestDecisionView: View {
    let request: EmployeeRequest
    /// Returns nil on success, otherwise the message to show here.
    let decide: (Bool, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var working = false
    @State private var rejecting = false
    @State private var error: String?

    private var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            // Scrolls so the note and the buttons stay reachable above the keyboard.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RequestCard(request: request, canCancel: false, cancel: {})
                    // A choice that can be changed back, instead of a one-way "Từ chối" button.
                    Picker("Quyết định", selection: $rejecting) {
                        Text("Duyệt").tag(false)
                        Text("Từ chối").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(working)
                    Text(rejecting ? "Lý do từ chối" : "Ghi chú cho nhân viên (tùy chọn)").font(.headline)
                    TextEditor(text: $note).scrollIndicators(.hidden).scrollContentBackground(.hidden).padding(12).frame(minHeight: 130)
                        .background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 18))
                    if rejecting && trimmedNote.count < 5 {
                        Text("Lý do từ chối là bắt buộc, tối thiểu 5 ký tự.").font(.caption).foregroundStyle(AppTheme.redText)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppTheme.redText)
                    }
                    Button {
                        working = true
                        error = nil
                        Task {
                            let failure = await decide(!rejecting, trimmedNote)
                            working = false
                            if let failure {
                                error = failure
                            } else {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                dismiss()
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if working { ProgressView().tint(.white) }
                            Text(working ? "Đang xử lý…" : rejecting ? "Xác nhận từ chối" : "Duyệt đơn")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(rejecting ? AppTheme.red : .green)
                    .disabled(working || (rejecting && trimmedNote.count < 5))
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.ink.ignoresSafeArea()).navigationTitle("Xử lý đơn")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() }.disabled(working) } }
        }
        .interactiveDismissDisabled(working)
    }
}

struct RequestComposer: View {
    private enum DurationUnit: String, CaseIterable, Identifiable {
        case minutes
        case hours

        var id: String { rawValue }
        var title: String { self == .minutes ? "Phút" : "Giờ" }
        var maximumValue: Int { self == .minutes ? 60 : 24 }
        /// Minutes in 5-minute steps: a system menu opens at its first item
        /// and cannot scroll to the selection, and 60 single minutes put the
        /// default 30 a long scroll away. Twelve steps fit on screen with the
        /// current amount in view, as the booking form's duration. Hours one
        /// by one.
        var choices: [Int] {
            self == .minutes ? Array(stride(from: 5, through: 60, by: 5)) : Array(1...24)
        }

        func nearestChoice(to value: Int) -> Int {
            choices.min { abs($0 - value) < abs($1 - value) } ?? value
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var kind = EmployeeRequestKind.leave
    @State private var from = Date()
    @State private var to = VietnamTime.calendar.date(byAdding: .hour, value: 8, to: Date()) ?? Date()
    @State private var reason = ""
    @State private var attendanceDate = VietnamTime.calendar.startOfDay(for: Date())
    @State private var attendanceDay: AttendanceDay?
    @State private var destination = ""
    @State private var transport = "personal_vehicle"
    @State private var distanceKm = ""
    @State private var expense = ""
    @State private var durationValue = 30
    @State private var durationUnit: DurationUnit = .minutes
    @State private var reasonEditorHeight: CGFloat = 150
    @State private var reasonFocused = false
    @State private var leaveScheduleWasInitialized = false
    @FocusState private var focusedInput: RequestInputFocus?

    private enum RequestInputFocus: Hashable {
        case destination
        case distance
        case expense
    }
    /// Returns nil on success, otherwise the reason the server rejected it.
    let submit: (EmployeeRequestKind, Date, Date, String, String?, String?, Double?, Double?) async -> String?
    @State private var isSubmitting = false
    @State private var submitError: String?
    /// Typed content when the form opened; once it changes, a swipe down no
    /// longer closes the form, so a stray drag cannot lose the text. Hủy is
    /// an explicit choice and always closes at once.
    @State private var initialInput: [String]?
    /// Set when the employee changes a date or time. The form also assigns
    /// `from`, `to` and `attendanceDate` itself, after it has appeared, from
    /// the attendance month and the shift schedule; those must not count as
    /// input, so only changes made through a picker binding set this.
    @State private var scheduleEdited = false
    /// A rejected request this form starts from; nil for a new request.
    let template: EmployeeRequest?
    /// The first attendance lookup must not replace the template's times.
    @State private var keepTemplateAttendanceTimes = false

    init(
        template: EmployeeRequest? = nil,
        submit: @escaping (EmployeeRequestKind, Date, Date, String, String?, String?, Double?, Double?) async -> String?
    ) {
        self.template = template
        self.submit = submit
        guard let template else { return }
        let prefill = RequestReasonPrefill(
            reason: template.reason,
            kindTitle: template.kind.title,
            usesDuration: [.late, .early, .overtime].contains(template.kind)
        )
        _kind = State(initialValue: template.kind)
        _from = State(initialValue: template.from)
        _to = State(initialValue: template.to)
        _reason = State(initialValue: prefill.reason)
        _attendanceDate = State(initialValue: VietnamTime.calendar.startOfDay(for: template.from))
        _destination = State(initialValue: template.businessDestination ?? "")
        _transport = State(initialValue: template.businessTransport.flatMap { $0.isEmpty ? nil : $0 } ?? "personal_vehicle")
        _distanceKm = State(initialValue: template.businessDistanceKm.map(Self.plainNumber) ?? "")
        _expense = State(initialValue: template.businessExpense.map(Self.plainNumber) ?? "")
        if let value = prefill.durationValue {
            _durationValue = State(initialValue: value)
            _durationUnit = State(initialValue: prefill.durationIsHours ? .hours : .minutes)
        }
        // Keep the template's own times on the first render.
        _leaveScheduleWasInitialized = State(initialValue: true)
        _keepTemplateAttendanceTimes = State(initialValue: template.kind == .attendance)
    }

    /// 12 -> "12", 12.5 -> "12.5" for the numeric text fields.
    private static func plainNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
    private var cleanReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// `.decimalPad` follows the device locale, so Vietnamese keyboards enter `,`.
    private func localizedDecimal(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
    private var usesCompactDateRows: Bool { dynamicTypeSize <= .large }
    private var usesDurationInput: Bool { [.late, .early, .overtime].contains(kind) }
    private var singleDayEventName: String { kind == .late ? "đi trễ" : "về sớm" }
    /// Pairs that belong together: whole-day absence (Xin nghỉ, Công tác),
    /// shift deviations (Đi trễ, Về sớm), extra work (Làm thêm giờ, Làm chủ
    /// nhật), then Ra cổng and Xác nhận giờ công. Same order on Android and web.
    private var compactRequestKinds: [EmployeeRequestKind] {
        [.leave, .business, .late, .early, .overtime, .sunday, .gate, .attendance]
    }
    private var durationMinutes: Int { durationUnit == .hours ? durationValue * 60 : durationValue }
    private var durationDescription: String { "\(durationValue) \(durationUnit.title.lowercased())" }
    private var workStartTime: String? { session.dashboard?.workStartTime }
    private var workEndTime: String? { session.dashboard?.workEndTime }

    /// The employee's usual shift on today's Sunday, or the next one.
    private func applySundaySchedule(now: Date) {
        let calendar = VietnamTime.calendar
        let today = calendar.startOfDay(for: now)
        let daysToSunday = (8 - calendar.component(.weekday, from: today)) % 7
        let sunday = calendar.date(byAdding: .day, value: daysToSunday, to: today) ?? today
        from = scheduledAttendanceTime(workStartTime, on: sunday, fallbackHour: 7, fallbackMinute: 30)
        to = scheduledAttendanceTime(workEndTime, on: sunday, fallbackHour: 16, fallbackMinute: 30)
    }

    private func applyInitialLeaveSchedule() {
        guard kind == .leave, !leaveScheduleWasInitialized else { return }
        let leaveDay = VietnamTime.calendar.startOfDay(for: from)
        from = scheduledAttendanceTime(workStartTime, on: leaveDay, fallbackHour: 7, fallbackMinute: 30)
        to = scheduledAttendanceTime(workEndTime, on: leaveDay, fallbackHour: 16, fallbackMinute: 30)
        leaveScheduleWasInitialized = true
    }

    private var scheduledRequestDates: (from: Date, to: Date) {
        let calendar = VietnamTime.calendar
        let requestDay = calendar.startOfDay(for: from)
        let shiftStart = scheduledAttendanceTime(workStartTime, on: requestDay, fallbackHour: 7, fallbackMinute: 30)
        let shiftEnd = scheduledAttendanceTime(workEndTime, on: requestDay, fallbackHour: 16, fallbackMinute: 30)
        switch kind {
        case .late:
            return (shiftStart, shiftStart.addingTimeInterval(TimeInterval(durationMinutes * 60)))
        case .early:
            return (shiftEnd.addingTimeInterval(TimeInterval(-durationMinutes * 60)), shiftEnd)
        case .overtime:
            return (shiftEnd, shiftEnd.addingTimeInterval(TimeInterval(durationMinutes * 60)))
        default:
            return (from, to)
        }
    }

    private var scheduledRequestPreview: String {
        let formatter = VietnamTime.clock
        let dates = scheduledRequestDates
        return "Khung giờ theo ca làm: \(formatter.string(from: dates.from)) – \(formatter.string(from: dates.to))."
    }

    private var submissionDates: (from: Date, to: Date) {
        let calendar = VietnamTime.calendar
        switch kind {
        case .late, .early, .overtime:
            return scheduledRequestDates
        default:
            return (from, to)
        }
    }

    private var submissionReason: String {
        guard usesDurationInput else { return cleanReason }
        return "\(kind.title): \(durationDescription). \(cleanReason)"
    }
    @ViewBuilder private func labeledNumberField(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        focus: RequestInputFocus,
        scrollID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.muted)
            TextField(placeholder, text: text).keyboardType(.decimalPad)
                .focused($focusedInput, equals: focus)
                .padding(.horizontal, 14).frame(height: 48)
                .background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .id(scrollID)
    }

    /// A missing time is chosen like the booking's Bắt đầu: Apple's time
    /// picker lies over the card, invisible, so a tap anywhere on it opens
    /// Apple's time bubble, not only a tap on the picker's small capsule.
    @ViewBuilder private func attendanceTimeCard(title: String, value: String?, missingPrompt: String, selection: Binding<Date>) -> some View {
        if value == nil {
            attendanceTimeCardFace(title: title, value: value, chosen: selection.wrappedValue)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .overlay(TileFillingTimePicker(selection: selection, accessibilityLabel: missingPrompt))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            attendanceTimeCardFace(title: title, value: value, chosen: nil)
        }
    }

    private func attendanceTimeCardFace(title: String, value: String?, chosen: Date?) -> some View {
        let compact = dynamicTypeSize <= .large
        return VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.muted)
                Spacer(minLength: 4)
                if chosen != nil {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.muted)
                }
            }
            Text(attendanceTime(value))
                .font(compact ? .headline.weight(.bold) : .title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? AppTheme.red : .green)
            if let chosen {
                Label(VietnamTime.clock.string(from: chosen), systemImage: "clock")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            } else {
                Text("Đã ghi nhận").font(.caption).foregroundStyle(Color.green.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? (value == nil ? 88 : 76) : 106, alignment: .topLeading)
        .padding(compact ? 10 : 12)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private func requestKindButton(_ item: EmployeeRequestKind, fullWidth: Bool = false) -> some View {
        Button { kind = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: fullWidth ? 56 : 52, alignment: .leading)
            .background(kind == item ? item.color.opacity(0.2) : AppTheme.card)
            .foregroundStyle(kind == item ? item.color : Color.primary)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(kind == item ? item.color.opacity(0.75) : Color.primary.opacity(0.12), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
    private func attendanceTime(_ value: String?) -> String {
        guard let value, let date = VietnamTime.date(fromISO8601: value) else { return "Thiếu" }
        return VietnamTime.clock.string(from: date)
    }

    private func scheduledAttendanceTime(_ time: String?, on date: Date, fallbackHour: Int, fallbackMinute: Int) -> Date {
        let parts = time?.split(separator: ":").compactMap { Int($0) } ?? []
        let hour = parts.count == 2 && (0...23).contains(parts[0]) ? parts[0] : fallbackHour
        let minute = parts.count == 2 && (0...59).contains(parts[1]) ? parts[1] : fallbackMinute
        return VietnamTime.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    /// What still blocks "Gửi đơn", so a disabled button is never a riddle.
    /// Mirrors Android RequestComposer.
    private var missingRequirement: String? {
        let place = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .business && place.count < 2 { return "Nhập nơi công tác để gửi đơn." }
        if kind == .business && transport == "personal_vehicle" && !(localizedDecimal(distanceKm) ?? 0 > 0) {
            return "Nhập quãng đường khi đi bằng xe cá nhân."
        }
        if kind == .sunday && VietnamTime.calendar.component(.weekday, from: from) != 1 {
            return "Ngày bắt đầu phải là Chủ nhật."
        }
        if kind == .sunday && to <= from { return "Giờ kết thúc phải sau giờ bắt đầu." }
        if cleanReason.count < 10 { return "Lý do cần tối thiểu 10 ký tự (đã nhập \(cleanReason.count))." }
        let dates = submissionDates
        if dates.to < dates.from { return "Thời gian kết thúc phải sau thời gian bắt đầu." }
        return nil
    }

    private var canSubmit: Bool {
        missingRequirement == nil
    }

    private var currentInput: [String] {
        [reason, destination, distanceKm, expense].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private var hasUnsavedInput: Bool {
        scheduleEdited || (initialInput.map { $0 != currentInput } ?? false)
    }

    /// `binding`, marking the schedule as edited when a picker changes it.
    /// Never use this for the form's own prefill: that writes to the state
    /// directly so it stays out of `hasUnsavedInput`.
    private func editedByEmployee(_ binding: Binding<Date>) -> Binding<Date> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                markScheduleEdited(from: binding.wrappedValue, to: newValue)
                binding.wrappedValue = newValue
            }
        )
    }

    /// Compared to the minute: `from` starts as `Date()` with seconds that no
    /// hour-and-minute picker shows, so a picker handing back the same minute
    /// without them is not an edit. Every real change moves at least a minute.
    private func markScheduleEdited(from old: Date, to new: Date) {
        if !VietnamTime.calendar.isDate(old, equalTo: new, toGranularity: .minute) {
            scheduleEdited = true
        }
    }

    private var requestStartBinding: Binding<Date> {
        Binding(
            get: { from },
            set: { newValue in
                markScheduleEdited(from: from, to: newValue)
                updateRequestStart(newValue)
            }
        )
    }

    private func updateRequestStart(_ selected: Date) {
        let calendar = VietnamTime.calendar
        let previousFrom = from
        let previousTo = to

        guard !calendar.isDate(selected, inSameDayAs: previousFrom) else {
            from = selected
            if to < selected {
                to = calendar.date(byAdding: .hour, value: 1, to: selected) ?? selected
            }
            return
        }

        // A new start date creates a same-day request by default. Preserve the
        // chosen start/end clock times rather than adopting a picker or shift
        // default while the user changes only the calendar date.
        let day = calendar.startOfDay(for: selected)
        let startTime = calendar.dateComponents([.hour, .minute, .second], from: previousFrom)
        let endTime = calendar.dateComponents([.hour, .minute, .second], from: previousTo)
        from = calendar.date(byAdding: startTime, to: day) ?? selected
        to = calendar.date(byAdding: endTime, to: day) ?? selected
    }

    private func requestTimeRange(title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            composerLabel(title, icon: icon)
            VStack(spacing: 10) {
                dateRow("Bắt đầu", selection: requestStartBinding)
                dateRow("Kết thúc", selection: editedByEmployee($to), range: from...)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(AppTheme.red.opacity(0.16))
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 25, weight: .semibold))
                                .foregroundStyle(AppTheme.red)
                        }
                        .frame(width: 52, height: 52)

                        Text(template == nil ? "Tạo đơn mới" : "Tạo lại đơn")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text(template == nil
                             ? "Điền thông tin rõ ràng để đơn được xử lý nhanh hơn."
                             : "Nội dung lấy từ đơn bị từ chối. Sửa lại nếu cần rồi gửi.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.muted)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        composerLabel("Loại đơn", icon: "square.grid.2x2")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(compactRequestKinds) { requestKindButton($0) }
                        }
                    }

                    if kind == .attendance {
                        VStack(alignment: .leading, spacing: 12) {
                            composerLabel("Ngày đối chiếu", icon: "calendar.badge.clock")
                            // Laid out as a labelled DatePicker is (label, space,
                            // picker), the picker at its full date; see
                            // `SystemCompactDatePicker`.
                            CompactDateRow(label: "Ngày chấm công") {
                                SystemCompactDatePicker(
                                    selection: editedByEmployee($attendanceDate),
                                    mode: .date,
                                    accessibilityLabel: "Ngày chấm công"
                                )
                                .logsCompactDateWidth(day: attendanceDate, logName: "composer.attendanceDate")
                            }
                            if let day = attendanceDay {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(spacing: 10) {
                                        attendanceTimeCard(title: "GIỜ VÀO", value: day.checkIn, missingPrompt: "Bổ sung giờ vào", selection: editedByEmployee($from))
                                        attendanceTimeCard(title: "GIỜ RA", value: day.checkOut, missingPrompt: "Bổ sung giờ ra", selection: editedByEmployee($to))
                                    }
                                } else {
                                    HStack(spacing: 10) {
                                        attendanceTimeCard(title: "GIỜ VÀO", value: day.checkIn, missingPrompt: "Bổ sung giờ vào", selection: editedByEmployee($from))
                                        attendanceTimeCard(title: "GIỜ RA", value: day.checkOut, missingPrompt: "Bổ sung giờ ra", selection: editedByEmployee($to))
                                    }
                                }
                            } else {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 10) {
                                        DatePicker("Giờ vào", selection: editedByEmployee($from), displayedComponents: .hourAndMinute)
                                        DatePicker("Giờ ra", selection: editedByEmployee($to), displayedComponents: .hourAndMinute)
                                    }
                                } else {
                                    HStack {
                                        DatePicker("Giờ vào", selection: editedByEmployee($from), displayedComponents: .hourAndMinute).labelsHidden()
                                        DatePicker("Giờ ra", selection: editedByEmployee($to), displayedComponents: .hourAndMinute).labelsHidden()
                                    }
                                }
                                Text("Chưa có dữ liệu: nhập cả giờ vào và giờ ra để gửi yêu cầu bổ sung.").foregroundStyle(AppTheme.muted)
                            }
                            if attendanceDay?.classification == "checkout_only" {
                                Text("Đã nhận diện lượt chấm công buổi chiều. Chỉ cần bổ sung giờ vào.")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(AppTheme.redText)
                            } else if attendanceDay?.classification == "checkin_only" {
                                Text("Đã nhận diện lượt chấm công buổi sáng. Chỉ cần bổ sung giờ ra.")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(AppTheme.redText)
                            } else if attendanceDay?.classification == "ambiguous" {
                                Text("Lượt chấm công ở giữa ca; hãy xác nhận lại giờ vào và giờ ra trước khi gửi.")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(AppTheme.text(.orange))
                            }
                            Text("Giờ thiếu chỉ được cập nhật sau khi đơn được duyệt.").font(.footnote).foregroundStyle(AppTheme.muted)
                        }
                    }
                    if kind == .business {
                        requestTimeRange(title: "Thời gian công tác", icon: "calendar.badge.clock")
                        VStack(alignment: .leading, spacing: 14) {
                            composerLabel("Thông tin công tác", icon: "airplane")
                            VStack(alignment: .leading, spacing: 6) {
                                Text("NƠI ĐẾN").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.muted)
                                TextField("Nhập địa điểm công tác", text: $destination)
                                    .textInputAutocapitalization(.sentences)
                                    .focused($focusedInput, equals: .destination)
                                    .padding(.horizontal, 14).frame(height: 48)
                                    .background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .id("request-destination")
                            VStack(alignment: .leading, spacing: 8) {
                                Text("PHƯƠNG TIỆN").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.muted)
                                Picker("Phương tiện", selection: $transport) {
                                    Text("Xe cá nhân").tag("personal_vehicle")
                                    Text("Grab").tag("grab")
                                    Text("Xe công ty").tag("company_vehicle")
                                }
                                .pickerStyle(.segmented)
                            }
                            if transport == "personal_vehicle" {
                                labeledNumberField(
                                    "Số km",
                                    placeholder: "Nhập số km",
                                    text: $distanceKm,
                                    focus: .distance,
                                    scrollID: "request-distance"
                                )
                            }
                            labeledNumberField(
                                "Chi phí",
                                placeholder: "Nhập chi phí (VNĐ)",
                                text: $expense,
                                focus: .expense,
                                scrollID: "request-expense"
                            )
                        }
                    }
                    if kind == .gate {
                        requestTimeRange(title: "Thời gian ra cổng", icon: "calendar.badge.clock")
                    }
                    if kind == .sunday {
                        requestTimeRange(title: "Thời gian làm chủ nhật", icon: "calendar.badge.clock")
                    }
                    if kind == .leave {
                        requestTimeRange(title: "Thời gian xin nghỉ", icon: "calendar.badge.clock")
                    }

                    if kind == .late || kind == .early {
                        VStack(alignment: .leading, spacing: 12) {
                            composerLabel(kind == .late ? "Ngày đi trễ" : "Ngày về sớm", icon: "calendar")
                            // As "Ngày chấm công"; when switching to Đi trễ or Về
                            // sớm moves `from`, the picker widens itself as well.
                            CompactDateRow(label: "Ngày xảy ra") {
                                SystemCompactDatePicker(
                                    selection: editedByEmployee($from),
                                    mode: .date,
                                    accessibilityLabel: "Ngày xảy ra"
                                )
                                .logsCompactDateWidth(day: from, logName: "composer.eventDate")
                            }
                            Text("Chọn đúng ngày xảy ra việc \(singleDayEventName) trước khi gửi đơn.")
                                .font(.footnote)
                                .foregroundStyle(AppTheme.muted)
                            Text(scheduledRequestPreview)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(AppTheme.muted)
                        }
                    }

                    if usesDurationInput {
                        VStack(alignment: .leading, spacing: 12) {
                            composerLabel("Thời lượng", icon: "timer")
                            Text("Chọn thời lượng \(kind.title.lowercased()) để gửi yêu cầu.")
                                .font(.footnote)
                                .foregroundStyle(AppTheme.muted)
                            HStack(spacing: 12) {
                                durationValueMenu
                                durationUnitMenu
                            }
                            Text("Thời lượng đã chọn: \(durationDescription).")
                                .font(.footnote.weight(.medium))
                            Text(scheduledRequestPreview)
                                .font(.footnote)
                                .foregroundStyle(AppTheme.muted)
                                .foregroundStyle(kind.color)
                        }
                        .onChange(of: durationUnit) { previousUnit, unit in
                            durationValue = unit == .hours && previousUnit != .hours
                                ? 1
                                : unit.nearestChoice(to: min(durationValue, unit.maximumValue))
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        composerLabel("Nội dung đơn", icon: "text.alignleft")
                        ZStack(alignment: .topLeading) {
                            if reason.isEmpty {
                                Text(
                                    kind == .business
                                        ? "Nêu mục đích và nội dung công tác..."
                                        : kind == .attendance
                                            ? "Mô tả phần giờ công cần xác nhận hoặc thông tin người duyệt cần lưu ý..."
                                            : "Mô tả lý do và thông tin cần người duyệt lưu ý..."
                                )
                                    .font(.body)
                                    .foregroundStyle(AppTheme.muted.opacity(0.72))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 17)
                                    .allowsHitTesting(false)
                            }
                            GrowingRequestReasonEditor(
                                text: $reason,
                                height: $reasonEditorHeight,
                                isFocused: $reasonFocused,
                                minimumHeight: 150,
                                maximumHeight: 320
                            )
                                .frame(height: reasonEditorHeight)
                        }
                        .background(AppTheme.card)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(reasonFocused ? AppTheme.red.opacity(0.78) : AppTheme.fieldBorder, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .id("request-reason-editor")

                        HStack {
                            Label(cleanReason.count >= 10 ? "Nội dung hợp lệ" : "Tối thiểu 10 ký tự", systemImage: cleanReason.count >= 10 ? "checkmark.circle.fill" : "info.circle")
                                .foregroundStyle(cleanReason.count >= 10 ? Color.green : AppTheme.muted)
                            Spacer()
                            Text("\(reason.count) ký tự").foregroundStyle(AppTheme.muted)
                        }
                        .font(.caption.weight(.medium))
                    }
                    .id("request-reason")
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 120)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focusedInput) { _, field in
                    guard field != nil else { return }
                    keepActiveInputVisible(using: proxy)
                }
                .onChange(of: reasonFocused) { _, focused in
                    guard focused else { return }
                    keepActiveInputVisible(using: proxy)
                }
                // iOS 18 reports focus before it applies the keyboard inset.
                // Re-run the non-animated scroll after that inset changes.
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
                    guard focusedInput != nil || reasonFocused else { return }
                    keepActiveInputVisible(using: proxy)
                }
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .dynamicTypeSize(.xSmall ... .accessibility1)
            .onAppear {
                applyInitialLeaveSchedule()
            }
            .onChange(of: kind) { _, nextKind in
                if nextKind == .leave {
                    applyInitialLeaveSchedule()
                } else {
                    leaveScheduleWasInitialized = false
                }
            }
            .task(id: kind.rawValue + String(attendanceDate.timeIntervalSince1970)) {
                guard kind == .attendance, let token = session.token else { return }
                let month = VietnamTime.monthKey.string(from: attendanceDate)
                let selectedKey = VietnamTime.dayKey.string(from: attendanceDate)
                // A resubmitted request keeps its own times for this first
                // lookup (cached and network); later day changes fill as usual.
                let keepTimes = keepTemplateAttendanceTimes
                keepTemplateAttendanceTimes = false

                func apply(_ data: AttendanceMonth) {
                    attendanceDay = data.days.first { $0.date == selectedKey }
                    guard !keepTimes else { return }
                    let scheduleStart = attendanceDay?.startTime ?? data.startTime
                    let scheduleEnd = attendanceDay?.endTime ?? data.endTime
                    from = attendanceDay?.checkIn.flatMap(VietnamTime.date(fromISO8601:))
                        ?? scheduledAttendanceTime(scheduleStart, on: attendanceDate, fallbackHour: 7, fallbackMinute: 30)
                    to = attendanceDay?.checkOut.flatMap(VietnamTime.date(fromISO8601:))
                        ?? scheduledAttendanceTime(scheduleEnd, on: attendanceDate, fallbackHour: 16, fallbackMinute: 30)
                }

                if let cached = session.cachedAttendanceMonth(month) {
                    apply(cached)
                } else {
                    attendanceDay = nil
                }

                guard session.shouldRevalidateAttendanceMonth(month) else { return }
                if let refreshed = try? await session.loadAttendanceMonth(month, token: token) {
                    apply(refreshed)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hủy") {
                        UIFlowLog.record("composer.userTappedCancel", "unsaved=\(hasUnsavedInput)")
                        dismiss()
                    }
                        .foregroundStyle(AppTheme.muted)
                }
            }
            .onAppear { if initialInput == nil { initialInput = currentInput } }
            // A disappear with no composer.user* line above it was not the
            // employee's doing: the sheet closed on its own.
            .onDisappear {
                UIFlowLog.record(
                    "composer.disappear",
                    "unsaved=\(hasUnsavedInput) scheduleEdited=\(scheduleEdited) submitting=\(isSubmitting) dismissDisabled=\(hasUnsavedInput || isSubmitting)"
                )
            }
            .interactiveDismissDisabled(hasUnsavedInput || isSubmitting)
            .safeAreaInset(edge: .bottom) {
                // The form closes only after the server accepted the request; a
                // failure keeps everything typed and shows the reason above.
                if let submitError {
                    Label(submitError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.redText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                } else if let missingRequirement, !isSubmitting {
                    Label(missingRequirement, systemImage: "info.circle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                }
                Button {
                    let dates = submissionDates
                    isSubmitting = true
                    submitError = nil
                    Task {
                        let error = await submit(kind, dates.from, dates.to, submissionReason, destination, transport, localizedDecimal(distanceKm), localizedDecimal(expense))
                        isSubmitting = false
                        if let error {
                            submitError = error
                        } else {
                            UIFlowLog.record("composer.userSubmitted")
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        if isSubmitting {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                        Text(isSubmitting ? "Đang gửi…" : "Gửi đơn")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(canSubmit ? AppTheme.red : AppTheme.red.opacity(0.32))
                    .foregroundStyle(canSubmit ? Color.white : Color.white.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: canSubmit ? AppTheme.red.opacity(0.28) : .clear, radius: 16, y: 7)
                }
                .disabled(!canSubmit)
                // Same compact rounded frosted backing as meeting booking.
                // Only the area around the button is blurred (iOS 17+).
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 25, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 25, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
                        }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .onChange(of: from) { oldValue, newValue in
                if to < newValue {
                    to = newValue.addingTimeInterval(max(to.timeIntervalSince(oldValue), 60 * 60))
                }
            }
            .onChange(of: kind) { _, newKind in
                let now = Date()
                if newKind == .business || newKind == .gate {
                    from = now
                    to = now.addingTimeInterval(60 * 60)
                } else if newKind == .sunday {
                    applySundaySchedule(now: now)
                } else if [.late, .early, .overtime].contains(newKind) {
                    durationValue = 30
                    durationUnit = .minutes
                    from = VietnamTime.calendar.startOfDay(for: now)
                    to = from.addingTimeInterval(30 * 60)
                }
            }
        }
        // Pickers show and select Vietnam time on any device time zone;
        // requests are sent as instants, so the server receives the time the
        // employee meant.
        .environment(\.timeZone, VietnamTime.timeZone)
        .environment(\.calendar, VietnamTime.calendar)
    }

    private func keepActiveInputVisible(using proxy: ScrollViewProxy) {
        let target: String?
        if reasonFocused {
            target = "request-reason-editor"
        } else {
            switch focusedInput {
            case .some(.destination): target = "request-destination"
            case .some(.distance): target = "request-distance"
            case .some(.expense): target = "request-expense"
            case .none: target = nil
            }
        }
        guard let target else { return }

        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    private func composerLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.primary)
    }

    /// One row per moment: the label, then the picker at its full width
    /// (about 270pt for "18 thg 10, 2026  08:00"). Only the label adapts to
    /// the room left beside it; the picker is never swapped for another,
    /// which a layout choice around it (ViewThatFits) would do, and a new
    /// picker would come up at the old width (see `SystemCompactDatePicker`).
    /// At accessibility text sizes the label goes over the picker.
    @ViewBuilder
    private func dateRow(_ title: String, selection: Binding<Date>, range: PartialRangeFrom<Date>? = nil) -> some View {
        if usesCompactDateRows {
            HStack(spacing: 6) {
                requestDateLabel(title, besidePicker: true)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                dateTimePicker(title, selection: selection, range: range)
                    .fixedSize()
                    .layoutPriority(2)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                requestDateLabel(title)
                dateTimePicker(title, selection: selection, range: range)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        }
    }

    /// The icon beside the title, the same way in both rows. Beside the
    /// picker it is set one size smaller, so "Kết thúc", the longer title,
    /// fits as "Bắt đầu" does (02708ca chose a layout per row and drew
    /// "Kết thúc" as a small title under its icon). It shrinks a little,
    /// never wraps, on the narrowest phones.
    private func requestDateLabel(_ title: String, besidePicker: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: title == "Bắt đầu" ? "arrow.right.circle.fill" : "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
            Text(title)
                .font(besidePicker ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(title == "Bắt đầu" ? AppTheme.red : Color.green)
    }

    /// Apple's compact picker, so it keeps "18 thg 10, 2026" rather than
    /// "18/10/26"; see `SystemCompactDatePicker`.
    ///
    /// The system picker, not a custom pill with a popover: a SwiftUI
    /// `.popover` inside this sheet closed the whole composer when tapped
    /// (debug.log on iOS 27), and the system's own compact picker, as in
    /// the attendance request, is the smoother and steadier of the two.
    private func dateTimePicker(_ title: String, selection: Binding<Date>, range: PartialRangeFrom<Date>?) -> some View {
        compactDateTimePicker(title, selection: selection, range: range)
            .logsCompactDateWidth(day: selection.wrappedValue, includesTime: true, logName: "composer.\(title)")
    }

    /// Apple's compact date and time picker, set to its date before it is
    /// measured; see `SystemCompactDatePicker`.
    private func compactDateTimePicker(_ title: String, selection: Binding<Date>, range: PartialRangeFrom<Date>?) -> some View {
        SystemCompactDatePicker(
            selection: selection,
            mode: .dateAndTime,
            minimum: range?.lowerBound,
            accessibilityLabel: title
        )
    }

    /// The menu's amounts. A resubmitted request keeps its own amount
    /// selectable even when it is not a 5-minute step ("7 phút"), rather
    /// than having it rounded away unseen.
    private var durationValueChoices: [Int] {
        let choices = durationUnit.choices
        return choices.contains(durationValue) ? choices : (choices + [durationValue]).sorted()
    }

    private var durationValueMenu: some View {
        durationMenu(title: "Số lượng", value: "\(durationValue)") {
            Picker("Số lượng", selection: $durationValue) {
                ForEach(durationValueChoices, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
        }
    }

    private var durationUnitMenu: some View {
        durationMenu(title: "Đơn vị", value: durationUnit.title) {
            Picker("Đơn vị", selection: $durationUnit) {
                ForEach(DurationUnit.allCases) { unit in
                    Text(unit.title).tag(unit)
                }
            }
        }
    }

    @ViewBuilder
    private func durationMenu<Content: View>(title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.muted)
            Menu {
                content()
            } label: {
                HStack(spacing: 8) {
                    Text(value)
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.muted)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(AppTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
