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

/// Direct-report picker shared by a manager creating a request for one or
/// more people. Its two-column tiles intentionally match the meal-order flow.
private struct RequestRecipientsPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: EmployeeRequestStore
    let token: String?
    @Binding var selectedIDs: Set<String>
    @State private var sheetHeight: CGFloat = 1
    /// A new request opens with only the manager selected. That default should
    /// be replaced once by the first direct report, but must never make a
    /// later tap on another employee silently remove “Tôi” again.
    @State private var hasChosenManagedEmployee = false

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    private var allIDs: Set<String> { Set(store.managedEmployees.map(\.id)) }
    private var allSelected: Bool { !allIDs.isEmpty && selectedIDs.isSuperset(of: allIDs) }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func toggleManagedEmployee(_ id: String) {
        guard let selfID = store.managedEmployees.first(where: \.isSelf)?.id else {
            toggle(id)
            return
        }

        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else if !hasChosenManagedEmployee && selectedIDs == [selfID] {
            // The first direct-report choice replaces the default “Tôi”.
            hasChosenManagedEmployee = true
            selectedIDs = [id]
        } else {
            // From then on, people are added to the current joint request.
            hasChosenManagedEmployee = true
            selectedIDs.insert(id)
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Tạo đơn cho").font(.title2.bold())
                    Spacer(minLength: 12)
                    Button("Hoàn tất") { dismiss() }
                        .font(.headline)
                        .foregroundStyle(AppTheme.red)
                }
                if !store.managedEmployeesLoaded {
                    VStack(spacing: 14) {
                        if let error = store.managedEmployeesError {
                            Text(error).multilineTextAlignment(.center).foregroundStyle(AppTheme.muted)
                            Button("Thử lại") {
                                Task { await store.loadManagedEmployees(token, force: true) }
                            }
                            .buttonStyle(.borderedProminent).tint(AppTheme.red)
                        } else {
                            ProgressView("Đang tải danh sách...")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    let selfPerson = store.managedEmployees.first(where: \.isSelf)
                    let employees = store.managedEmployees.filter { !$0.isSelf }
                    LazyVGrid(columns: columns, spacing: 8) {
                        if let selfPerson {
                            RequestRecipientChoiceTile(
                                title: "Tôi",
                                selected: selectedIDs.contains(selfPerson.id)
                            ) { toggle(selfPerson.id) }
                        }
                        RequestRecipientChoiceTile(title: "Tất cả", selected: allSelected) {
                            hasChosenManagedEmployee = true
                            selectedIDs = allSelected ? [] : allIDs
                        }
                    }
                    if !employees.isEmpty {
                        Text("TẠO ĐƠN CÙNG NHÂN VIÊN")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.muted)
                            .kerning(0.8)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(employees) { employee in
                                RequestRecipientChoiceTile(
                                    title: employee.fullName,
                                    selected: selectedIDs.contains(employee.id)
                                ) { toggleManagedEmployee(employee.id) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 18)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: MealSheetHeightPreferenceKey.self, value: proxy.size.height)
                }
            }
        }
        .background(AppTheme.ink.ignoresSafeArea())
        .onPreferenceChange(MealSheetHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            let maximumHeight = UIScreen.main.bounds.height * 0.82
            let measuredHeight = min(ceil(height + 8), maximumHeight)
            if abs(sheetHeight - measuredHeight) > 1 {
                sheetHeight = measuredHeight
            }
        }
        .fittedMealSheetSizing(fallbackHeight: sheetHeight)
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .attachedMealSheetCorners()
    }
}

private struct RequestRecipientChoiceTile: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .padding(.horizontal, 12)
                .foregroundStyle(selected ? Color.green : Color.primary)
                .background(selected ? Color.green.opacity(0.16) : AppTheme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? Color.green.opacity(0.65) : Color.primary.opacity(0.10), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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

struct RequestBody: Encodable {
    let kind: String
    let startsAt: Date
    let endsAt: Date
    let reason: String
    let businessDestination: String?
    let businessTransport: String?
    let businessDistanceKm: Double?
    let businessExpense: Double?
    /// Used only by the batch endpoint. The ordinary endpoint ignores it so
    /// older server versions remain compatible with a request for yourself.
    let employeeIds: [String]?
}
struct ManagedRequestEmployee: Codable, Identifiable, Equatable {
    let id: String
    let employeeCode: String
    let fullName: String
    let department: String
    let isSelf: Bool
}
private struct BatchCreatedRequests: Codable { let requests: [EmployeeRequest] }
struct RequestDecisionBody: Encodable { let status: String; let note: String? }

@MainActor
final class EmployeeRequestStore: ObservableObject {
    private struct CachedRequests: Codable {
        let savedAt: Date
        let requests: [EmployeeRequest]
        let approvals: [EmployeeRequest]
    }

    private struct CachedManagedDirectory: Codable {
        let employees: [ManagedRequestEmployee]
    }

    // Every change of these two lists ends with one rebuildIndex() call
    // (a didSet on each rebuilt it two or three times per change).
    @Published private(set) var requests: [EmployeeRequest] = []
    @Published private(set) var approvals: [EmployeeRequest] = []
    @Published private(set) var managedEmployees: [ManagedRequestEmployee] = []
    @Published private(set) var managedEmployeesLoaded = false
    @Published private(set) var managedEmployeesError: String?
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
    private let managedDirectoryCachePrefix = "native-managed-request-directory-"
    private var cacheEmployeeCode: String?
    private var managedDirectoryCacheOwner: String?
    private var lastLoadedAt: Date?
    private var loadTask: Task<Void, Never>?
    private var loadTaskID: UUID?
    private var managedEmployeesTask: Task<Void, Never>?
    private var managedEmployeesTaskID: UUID?
    /// Coalesce Admin changes received while an older directory GET runs.
    private var managedEmployeesRerunRequested = false
    /// A forced load arrived while one was running: run once more.
    private var rerunRequested = false
    private let refreshTTL: TimeInterval = 60

    /// Restore first so a previously loaded request list remains usable when
    /// the network is unavailable. Data is namespaced to the signed-in person.
    func restoreCache(employeeCode: String?) {
        guard let employeeCode = employeeCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !employeeCode.isEmpty else { return }
        // Direct-report data uses an independent lifetime and never expires.
        restoreManagedDirectoryCache(employeeCode: employeeCode)
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
        rebuildIndex()
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
        managedEmployeesTask?.cancel()
        managedEmployeesTask = nil
        managedEmployeesTaskID = nil
        managedEmployeesRerunRequested = false
        managedEmployees = []
        managedEmployeesLoaded = false
        managedEmployeesError = nil
        managedDirectoryCacheOwner = nil
        rebuildIndex()
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

    /// Read the last server-authorized directory immediately. Stored per
    /// account in file-protected Application Support and purged on sign-out.
    /// Revalidation is event-driven; there is deliberately no time-based TTL.
    func restoreManagedDirectoryCache(employeeCode: String?) {
        guard let employeeCode = employeeCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !employeeCode.isEmpty else { return }
        guard managedDirectoryCacheOwner != employeeCode else { return }
        managedEmployeesTask?.cancel()
        managedEmployeesTask = nil
        managedEmployeesTaskID = nil
        managedEmployeesRerunRequested = false
        managedDirectoryCacheOwner = employeeCode
        managedEmployees = []
        managedEmployeesLoaded = false
        managedEmployeesError = nil
        guard let data = AccountDocumentStore.shared.data(forKey: managedDirectoryCachePrefix + employeeCode),
              let cached = try? JSONDecoder().decode(CachedManagedDirectory.self, from: data) else { return }
        managedEmployees = cached.employees
        managedEmployeesLoaded = true
    }

    /// Both the request composer and the meal-order picker share one
    /// indefinite, account-scoped employee directory. The live menu includes
    /// the same people with additional per-day meal statuses. Only names/IDs
    /// are saved here; meal selections stay in TodayMenu.
    func reconcileManagedDirectoryFromMenu(_ menu: TodayMenu, profile: Profile?) {
        guard let employees = menu.managedEmployees,
              let profile, !profile.id.isEmpty, !profile.employeeCode.isEmpty else { return }
        restoreManagedDirectoryCache(employeeCode: profile.employeeCode)
        let previousSelf = managedEmployees.first(where: \.isSelf)
        let selfEntry = ManagedRequestEmployee(
            id: profile.id,
            employeeCode: profile.employeeCode,
            fullName: previousSelf.flatMap { $0.fullName.isEmpty ? nil : $0.fullName } ?? profile.name,
            department: previousSelf?.department ?? "",
            isSelf: true
        )
        let directory = [selfEntry] + employees
            .filter { !$0.id.isEmpty && $0.id != profile.id }
            .map {
                ManagedRequestEmployee(
                    id: $0.id,
                    employeeCode: $0.employeeCode,
                    fullName: $0.fullName,
                    department: $0.department,
                    isSelf: false
                )
            }
        guard !managedEmployeesLoaded || managedEmployees != directory else { return }
        managedEmployees = directory
        managedEmployeesLoaded = true
        managedEmployeesError = nil
        if let data = try? JSONEncoder().encode(CachedManagedDirectory(employees: directory)) {
            AccountDocumentStore.shared.set(
                data, forKey: managedDirectoryCachePrefix + profile.employeeCode
            )
        }
    }

    /// Load only on first use, an Admin-scoped realtime change, or stream
    /// reconnection (which uses a conditional HTTP GET / ETag 304).
    func loadManagedEmployees(_ token: String?, employeeCode: String? = nil, force: Bool = false) async {
        if let employeeCode { restoreManagedDirectoryCache(employeeCode: employeeCode) }
        guard let token else { return }
        if !force, managedEmployeesLoaded { return }
        if let task = managedEmployeesTask {
            if force { managedEmployeesRerunRequested = true }
            await task.value
            return
        }
        let requestedFor = managedDirectoryCacheOwner
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let employees: [ManagedRequestEmployee] = try await APIClient.shared.request(
                    "me/requests/managed-employees", token: token
                )
                guard !Task.isCancelled, self.managedDirectoryCacheOwner == requestedFor else { return }
                let changed = self.managedEmployees != employees
                if changed { self.managedEmployees = employees }
                if !self.managedEmployeesLoaded { self.managedEmployeesLoaded = true }
                if self.managedEmployeesError != nil { self.managedEmployeesError = nil }
                if let requestedFor, changed,
                   let encoded = try? JSONEncoder().encode(CachedManagedDirectory(employees: employees)) {
                    AccountDocumentStore.shared.set(encoded, forKey: self.managedDirectoryCachePrefix + requestedFor)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.managedDirectoryCacheOwner == requestedFor else { return }
                let message = Self.actionMessage(error, fallback: "Không tải được danh sách nhân viên.")
                if self.managedEmployeesError != message { self.managedEmployeesError = message }
            }
        }
        managedEmployeesTask = task
        managedEmployeesTaskID = taskID
        await task.value
        if managedEmployeesTaskID == taskID {
            managedEmployeesTask = nil
            managedEmployeesTaskID = nil
            if managedEmployeesRerunRequested {
                managedEmployeesRerunRequested = false
                await loadManagedEmployees(token, employeeCode: requestedFor, force: true)
            }
        }
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
                var delegatedRequests: [EmployeeRequest]
                repeat {
                    self.rerunRequested = false
                    async let mine: [EmployeeRequest] = APIClient.shared.request("me/requests", token: token)
                    async let assigned: [EmployeeRequest] = APIClient.shared.request("me/requests/approvals", token: token)
                    async let delegated: [EmployeeRequest] = APIClient.shared.request("me/requests/delegated", token: token)
                    loadedRequests = try await mine
                    loadedApprovals = try await assigned
                    delegatedRequests = try await delegated
                } while self.rerunRequested && !Task.isCancelled
                guard !Task.isCancelled else { return }
                var seenRequestIDs = Set<String>()
                self.requests = (loadedRequests + delegatedRequests).filter { seenRequestIDs.insert($0.id).inserted }
                self.approvals = loadedApprovals
                self.rebuildIndex()
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
    func submit(token: String?, kind: EmployeeRequestKind, from: Date, to: Date, reason: String, destination: String? = nil, transport: String? = nil, distanceKm: Double? = nil, expense: Double? = nil, employeeIds: [String]? = nil) async -> String? {
        guard let token else { return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại." }
        do {
            loadTask?.cancel()
            loadTask = nil
            loadTaskID = nil
            let body = RequestBody(
                kind: kind.rawValue,
                startsAt: from,
                endsAt: to,
                reason: reason,
                businessDestination: destination,
                businessTransport: transport,
                businessDistanceKm: distanceKm,
                businessExpense: expense,
                employeeIds: employeeIds
            )
            let created: [EmployeeRequest]
            if employeeIds != nil {
                let result: BatchCreatedRequests = try await APIClient.shared.request(
                    "me/requests/batch", method: "POST", token: token, body: body
                )
                created = result.requests
            } else {
                let request: EmployeeRequest = try await APIClient.shared.request(
                    "me/requests", method: "POST", token: token, body: body
                )
                created = [request]
            }
            let createdIDs = Set(created.map(\.id))
            requests.removeAll { createdIDs.contains($0.id) }
            requests.insert(contentsOf: created, at: 0)
            rebuildIndex()
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
            rebuildIndex()
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
            rebuildIndex()
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
                requestComposerSheet(template: nil)
            }
            .sheet(item: $resubmitting) { request in
                requestComposerSheet(template: request)
            }
            .sheet(item: $reviewing) { request in
                RequestDecisionView(request: request) { approved, note in
                    await store.decide(token: session.token, id: request.id, approved: approved, note: note)
                }
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
                    systemImage: "doc.text"
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

    /// TestFlight 144 still crashes in AttributeGraph while the large SwiftUI
    /// composer is built on iOS 17.  The entire iOS 17 composer is native
    /// UIKit; iOS 18 and later retain the richer SwiftUI implementation.
    @ViewBuilder
    private func requestComposerSheet(template: EmployeeRequest?) -> some View {
        if #available(iOS 18.0, *) {
            RequestComposer(template: template, submit: submitRequest)
                .presentationDetents([.large])
                .presentationContentInteraction(.resizes)
                .presentationDragIndicator(.hidden)
        } else {
            LegacyRequestComposerUIKitView(
                token: session.token,
                session: session,
                store: store,
                workStartTime: session.dashboard?.workStartTime,
                workEndTime: session.dashboard?.workEndTime,
                template: template,
                submit: submitRequest
            )
        }
    }

    private func submitRequest(
        kind: EmployeeRequestKind,
        from: Date,
        to: Date,
        reason: String,
        destination: String?,
        transport: String?,
        distance: Double?,
        expense: Double?,
        employeeIds: [String]?
    ) async -> String? {
        await store.submit(
            token: session.token, kind: kind, from: from, to: to, reason: reason,
            destination: destination, transport: transport, distanceKm: distance,
            expense: expense, employeeIds: employeeIds
        )
    }
}

struct RequestCard: View {
    let request: EmployeeRequest
    var canCancel = true
    /// The user's rejected request: tapping the card opens it to send again.
    var resubmittable = false
    // Only request cards presented from Notifications use high-contrast
    // white/black body text; other tabs keep their established appearance.
    var readableNotificationText = false
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
            if let note = request.decisionNote, !note.isEmpty { Label(note, systemImage: "text.bubble").font(.caption).foregroundStyle(readableNotificationText ? Color(uiColor: .label) : AppTheme.muted) }
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
            .foregroundStyle(readableNotificationText ? Color(uiColor: .label) : AppTheme.muted)
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
        // Calendar dates in both Requests and notification detail use
        // system primary text: white in Dark Mode, black in Light Mode.
        .foregroundStyle(Color(uiColor: .label))
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

// MARK: - iOS 17 native request composer

/// Intentionally a thin representable.  The form itself is UIKit so opening a
/// new request on iOS 17 never asks SwiftUI/AttributeGraph to construct the
/// large, stateful composer tree that appears in the TestFlight crash logs.
private struct LegacyRequestComposerUIKitView: UIViewControllerRepresentable {
    let token: String?
    let session: SessionStore
    let store: EmployeeRequestStore
    let workStartTime: String?
    let workEndTime: String?
    let template: EmployeeRequest?
    let submit: (EmployeeRequestKind, Date, Date, String, String?, String?, Double?, Double?, [String]?) async -> String?

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: LegacyRequestComposerController(
            token: token, session: session, store: store, workStartTime: workStartTime,
            workEndTime: workEndTime, template: template, submit: submit
        ))
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

@MainActor
private final class LegacyRequestComposerController: UIViewController, UITextViewDelegate {
    private let token: String?
    private let session: SessionStore
    private let store: EmployeeRequestStore
    private let workStartTime: String?
    private let workEndTime: String?
    private let template: EmployeeRequest?
    private let submitRequest: (EmployeeRequestKind, Date, Date, String, String?, String?, Double?, Double?, [String]?) async -> String?
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let kindButton = UIButton(type: .system)
    private let fromPicker = UIDatePicker()
    private let toPicker = UIDatePicker()
    private let dayPicker = UIDatePicker()
    private let attendanceDatePicker = UIDatePicker()
    private let attendanceStatusLabel = UILabel()
    private let durationField = UITextField()
    private let destinationField = UITextField()
    private let distanceField = UITextField()
    private let expenseField = UITextField()
    private let transportButton = UIButton(type: .system)
    private let recipientsButton = UIButton(type: .system)
    private let reasonView = UITextView()
    private let reasonPlaceholder = UILabel()
    private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let submitButton = UIButton(type: .system)
    private let validationLabel = UILabel()
    private var kind: EmployeeRequestKind
    private var selectedRecipientIDs = Set<String>()
    private var recipientsLoaded = false
    /// Only the first direct-report choice replaces the default manager.
    /// Kept by the composer (rather than the pushed picker) so returning to
    /// the picker cannot make a later choice silently remove “Tôi”.
    private var hasChosenManagedEmployee = false
    private var isSending = false
    private var attendanceDay: AttendanceDay?
    private var keepTemplateAttendanceTimes: Bool
    private var initialInput: [String] = []
    private var scheduleEdited = false

    init(
        token: String?, session: SessionStore, store: EmployeeRequestStore, workStartTime: String?, workEndTime: String?, template: EmployeeRequest?,
        submit: @escaping (EmployeeRequestKind, Date, Date, String, String?, String?, Double?, Double?, [String]?) async -> String?
    ) {
        self.token = token
        self.session = session
        self.store = store
        self.workStartTime = workStartTime
        self.workEndTime = workEndTime
        self.template = template
        self.submitRequest = submit
        self.kind = template?.kind ?? .leave
        self.keepTemplateAttendanceTimes = template?.kind == .attendance
        super.init(nibName: nil, bundle: nil)
        if let template {
            fromPicker.date = template.from
            toPicker.date = template.to
            dayPicker.date = template.from
            reasonView.text = RequestReasonPrefill(
                reason: template.reason, kindTitle: template.kind.title,
                usesDuration: [.late, .early, .overtime].contains(template.kind)
            ).reason
            destinationField.text = template.businessDestination
            distanceField.text = template.businessDistanceKm.map(Self.numberText)
            expenseField.text = template.businessExpense.map(Self.numberText)
            if let transport = template.businessTransport, !transport.isEmpty { transportButton.accessibilityIdentifier = transport }
        } else {
            let now = Date()
            fromPicker.date = now
            toPicker.date = VietnamTime.calendar.date(byAdding: .hour, value: 8, to: now) ?? now
            dayPicker.date = now
        }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = template == nil ? "Tạo đơn mới" : "Tạo lại đơn"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Hủy", style: .plain, target: self, action: #selector(close))
        configureControls()
        if template == nil { applyScheduleDefaults(for: kind) }
        configureLayout()
        rebuildForm()
        initialInput = currentInput
        Task { [weak self] in
            guard let self else { return }
            await store.loadManagedEmployees(token, employeeCode: session.profile?.employeeCode)
            guard !Task.isCancelled else { return }
            recipientsLoaded = store.managedEmployeesLoaded
            if selectedRecipientIDs.isEmpty {
                selectedRecipientIDs = Set(store.managedEmployees.filter(\.isSelf).map(\.id))
            }
            updateRecipientsTitle()
            renderValidation()
        }
    }

    private func configureControls() {
        [fromPicker, toPicker].forEach { $0.datePickerMode = .dateAndTime; $0.preferredDatePickerStyle = .compact }
        [fromPicker, toPicker, dayPicker, attendanceDatePicker].forEach { $0.addAction(UIAction { [weak self] _ in self?.scheduleEdited = true; self?.renderValidation() }, for: .valueChanged) }
        dayPicker.datePickerMode = .date
        dayPicker.preferredDatePickerStyle = .compact
        attendanceDatePicker.datePickerMode = .date
        attendanceDatePicker.preferredDatePickerStyle = .compact
        attendanceDatePicker.date = template?.from ?? Date()
        attendanceDatePicker.addAction(UIAction { [weak self] _ in self?.loadAttendanceForSelectedDay() }, for: .valueChanged)
        attendanceStatusLabel.numberOfLines = 0
        attendanceStatusLabel.font = .preferredFont(forTextStyle: .footnote)
        attendanceStatusLabel.textColor = .secondaryLabel
        kindButton.showsMenuAsPrimaryAction = true
        kindButton.configuration = .tinted()
        kindButton.menu = UIMenu(children: EmployeeRequestKind.allCases.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.icon), state: item == kind ? .on : .off) { [weak self] _ in
                self?.kind = item
                self?.applyScheduleDefaults(for: item)
                self?.rebuildForm()
            }
        })
        recipientsButton.configuration = .gray()
        recipientsButton.addTarget(self, action: #selector(showRecipients), for: .touchUpInside)
        transportButton.configuration = .gray()
        transportButton.showsMenuAsPrimaryAction = true
        let currentTransport = transportButton.accessibilityIdentifier ?? "personal_vehicle"
        setTransport(currentTransport)

        [durationField, distanceField, expenseField].forEach {
            $0.keyboardType = .decimalPad
            $0.borderStyle = .roundedRect
            $0.addAction(UIAction { [weak self] _ in self?.renderValidation() }, for: .editingChanged)
        }
        durationField.placeholder = "Số phút (bội số của 5)"
        durationField.text = "30"
        destinationField.placeholder = "Nhập địa điểm công tác"
        destinationField.borderStyle = .roundedRect
        destinationField.addAction(UIAction { [weak self] _ in self?.renderValidation() }, for: .editingChanged)
        distanceField.placeholder = "Số km"
        expenseField.placeholder = "Chi phí (VNĐ)"

        reasonView.font = .preferredFont(forTextStyle: .body)
        reasonView.delegate = self
        reasonView.layer.borderColor = UIColor.separator.cgColor
        reasonView.layer.borderWidth = 1
        reasonView.layer.cornerRadius = 12
        reasonView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        reasonPlaceholder.text = "Mô tả lý do và thông tin cần người duyệt lưu ý"
        reasonPlaceholder.textColor = .placeholderText
        reasonPlaceholder.font = .preferredFont(forTextStyle: .body)
        reasonPlaceholder.numberOfLines = 0
        reasonPlaceholder.isUserInteractionEnabled = false
        updateReasonPlaceholder()
    }

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.layer.cornerRadius = 24
        bottomBar.layer.cornerCurve = .continuous
        bottomBar.clipsToBounds = true
        bottomBar.layer.borderWidth = 0.75
        bottomBar.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        validationLabel.font = UIFont.preferredFont(forTextStyle: .footnote).requestWeight(.semibold)
        validationLabel.textColor = .systemRed
        validationLabel.numberOfLines = 0
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 16
        configuration.image = UIImage(systemName: "paperplane.fill")
        configuration.imagePadding = 8
        configuration.title = "Gửi đơn"
        configuration.baseBackgroundColor = .systemRed
        configuration.baseForegroundColor = .white
        submitButton.configuration = configuration
        submitButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        submitButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        let footerStack = UIStackView(arrangedSubviews: [validationLabel, submitButton])
        footerStack.axis = .vertical; footerStack.spacing = 8
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(footerStack)
        view.addSubview(scrollView)
        view.addSubview(bottomBar)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bottomBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bottomBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            footerStack.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor, constant: 8),
            footerStack.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor, constant: 8),
            footerStack.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor, constant: -8),
            footerStack.bottomAnchor.constraint(equalTo: bottomBar.contentView.bottomAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        ])
    }

    private func rebuildForm() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        kindButton.configuration?.title = kind.title
        stack.addArrangedSubview(headerView())
        // Match the iOS 18+ composer: the recipient is the first choice a
        // manager sees, before selecting the request type.
        let recipientsCard = card()
        recipientsCard.addArrangedSubview(sectionTitle("Tạo đơn cho", icon: "person.2.fill"))
        recipientsCard.addArrangedSubview(recipientsButton)
        stack.addArrangedSubview(recipientsCard)
        let kindCard = card()
        kindCard.addArrangedSubview(sectionTitle("Loại đơn", icon: "square.grid.2x2.fill"))
        kindCard.addArrangedSubview(requestKindGrid())
        stack.addArrangedSubview(kindCard)

        let detailsCard = card()
        if kind == .attendance {
            detailsCard.addArrangedSubview(section("Ngày đối chiếu", attendanceDatePicker))
            detailsCard.addArrangedSubview(attendanceStatusLabel)
            detailsCard.addArrangedSubview(dateSection(title: "Giờ chấm công", start: fromPicker, end: toPicker))
            loadAttendanceForSelectedDay()
        } else if [.late, .early, .overtime].contains(kind) {
            detailsCard.addArrangedSubview(section(kind == .late ? "Ngày đi trễ" : kind == .early ? "Ngày về sớm" : "Ngày làm thêm", dayPicker))
            detailsCard.addArrangedSubview(section("Thời lượng", durationField))
        } else {
            detailsCard.addArrangedSubview(dateSection(title: dateTitle, start: fromPicker, end: toPicker))
        }
        if kind == .business {
            detailsCard.addArrangedSubview(section("Nơi công tác", destinationField))
            detailsCard.addArrangedSubview(section("Phương tiện", transportButton))
            if selectedTransport == "personal_vehicle" { detailsCard.addArrangedSubview(section("Quãng đường", distanceField)) }
            detailsCard.addArrangedSubview(section("Chi phí", expenseField))
        }
        stack.addArrangedSubview(detailsCard)
        let reasonCard = card(); reasonCard.addArrangedSubview(sectionTitle("Nội dung đơn", icon: "text.alignleft")); reasonCard.addArrangedSubview(reasonSection())
        stack.addArrangedSubview(reasonCard)
        updateRecipientsTitle()
        renderValidation()
    }

    private func headerView() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "doc.badge.plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)))
        icon.tintColor = .systemRed
        icon.contentMode = .center
        icon.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        icon.layer.cornerRadius = 17
        icon.layer.cornerCurve = .continuous
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 54), icon.heightAnchor.constraint(equalToConstant: 54)])
        let kicker = label(template == nil ? "ĐƠN TỪ" : "GỬI LẠI ĐƠN", style: .caption1, weight: .bold, color: .systemRed)
        let heading = label(template == nil ? "Tạo đơn mới" : "Tạo lại đơn", style: .title2, weight: .bold, color: .label)
        let subtitle = label("Điền thông tin để gửi người duyệt.", style: .subheadline, color: .secondaryLabel)
        let texts = UIStackView(arrangedSubviews: [kicker, heading, subtitle])
        texts.axis = .vertical; texts.spacing = 3
        let row = UIStackView(arrangedSubviews: [icon, texts, UIView()])
        row.alignment = .center; row.spacing = 12
        return row
    }

    private func card() -> UIStackView {
        let card = UIStackView()
        card.axis = .vertical; card.spacing = 14
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 20; card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.75; card.layer.borderColor = UIColor.separator.withAlphaComponent(0.22).cgColor
        return card
    }

    private func sectionTitle(_ text: String, icon: String) -> UIView {
        let image = UIImageView(image: UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
        image.tintColor = .systemRed
        image.setContentHuggingPriority(.required, for: .horizontal)
        let title = label(text, style: .subheadline, weight: .bold, color: .label)
        let row = UIStackView(arrangedSubviews: [image, title, UIView()])
        row.alignment = .center; row.spacing = 8
        return row
    }

    private func requestKindGrid() -> UIView {
        let columns = UIStackView(); columns.axis = .vertical; columns.spacing = 8
        let choices = [EmployeeRequestKind.leave, .business, .late, .early, .overtime, .sunday, .gate, .attendance]
        for index in stride(from: 0, to: choices.count, by: 2) {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 8; row.distribution = .fillEqually
            row.addArrangedSubview(requestKindButton(choices[index]))
            row.addArrangedSubview(requestKindButton(choices[index + 1]))
            columns.addArrangedSubview(row)
        }
        return columns
    }

    private func requestKindButton(_ item: EmployeeRequestKind) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: item.icon)
        configuration.imagePadding = 7
        configuration.title = item.title
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        configuration.baseForegroundColor = item == kind ? UIColor(item.color) : .label
        configuration.background.backgroundColor = item == kind ? UIColor(item.color).withAlphaComponent(0.16) : .tertiarySystemGroupedBackground
        configuration.background.cornerRadius = 14
        configuration.background.strokeColor = item == kind ? UIColor(item.color).withAlphaComponent(0.75) : UIColor.separator.withAlphaComponent(0.35)
        configuration.background.strokeWidth = 1
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.kind = item
            self?.applyScheduleDefaults(for: item)
            self?.rebuildForm()
        })
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .subheadline).requestWeight(.semibold)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        return button
    }

    private func applyScheduleDefaults(for nextKind: EmployeeRequestKind) {
        let calendar = VietnamTime.calendar
        if nextKind == .sunday {
            let today = calendar.startOfDay(for: Date())
            let daysToSunday = (8 - calendar.component(.weekday, from: today)) % 7
            let sunday = calendar.date(byAdding: .day, value: daysToSunday, to: today) ?? today
            fromPicker.date = scheduledTime(workStartTime, on: sunday, fallbackHour: 7, fallbackMinute: 30)
            toPicker.date = scheduledTime(workEndTime, on: sunday, fallbackHour: 16, fallbackMinute: 30)
        } else if nextKind == .leave {
            let day = calendar.startOfDay(for: fromPicker.date)
            fromPicker.date = scheduledTime(workStartTime, on: day, fallbackHour: 7, fallbackMinute: 30)
            toPicker.date = scheduledTime(workEndTime, on: day, fallbackHour: 16, fallbackMinute: 30)
        }
    }

    private func scheduledTime(_ value: String?, on date: Date, fallbackHour: Int, fallbackMinute: Int) -> Date {
        let parts = value?.split(separator: ":").compactMap { Int($0) } ?? []
        let hour = parts.count == 2 && (0...23).contains(parts[0]) ? parts[0] : fallbackHour
        let minute = parts.count == 2 && (0...59).contains(parts[1]) ? parts[1] : fallbackMinute
        return VietnamTime.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    /// Mirrors the iOS 18 composer: a confirmation request starts from the
    /// recorded check-in/check-out of the selected day.  Only a missing clock
    /// can be edited manually; a recorded clock remains evidence, not a
    /// value that a request form can accidentally overwrite.
    private func loadAttendanceForSelectedDay() {
        guard kind == .attendance, let token else { return }
        let month = VietnamTime.monthKey.string(from: attendanceDatePicker.date)
        let selectedKey = VietnamTime.dayKey.string(from: attendanceDatePicker.date)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let keepTimes = keepTemplateAttendanceTimes
            keepTemplateAttendanceTimes = false
            if let cached = session.cachedAttendanceMonth(month) { applyAttendance(cached, selectedKey: selectedKey, keepTimes: keepTimes) }
            else {
                attendanceDay = nil
                fromPicker.isEnabled = true; toPicker.isEnabled = true
                attendanceStatusLabel.text = "Đang tải dữ liệu chấm công…"
            }
            guard session.shouldRevalidateAttendanceMonth(month), let refreshed = try? await session.loadAttendanceMonth(month, token: token) else { return }
            applyAttendance(refreshed, selectedKey: selectedKey, keepTimes: keepTimes)
        }
    }

    private func applyAttendance(_ data: AttendanceMonth, selectedKey: String, keepTimes: Bool) {
        guard kind == .attendance,
              VietnamTime.dayKey.string(from: attendanceDatePicker.date) == selectedKey else { return }
        attendanceDay = data.days.first { $0.date == selectedKey }
        let scheduleStart = attendanceDay?.startTime ?? data.startTime
        let scheduleEnd = attendanceDay?.endTime ?? data.endTime
        if !keepTimes {
            fromPicker.date = attendanceDay?.checkIn.flatMap(VietnamTime.date(fromISO8601:))
                ?? scheduledTime(scheduleStart, on: attendanceDatePicker.date, fallbackHour: 7, fallbackMinute: 30)
            toPicker.date = attendanceDay?.checkOut.flatMap(VietnamTime.date(fromISO8601:))
                ?? scheduledTime(scheduleEnd, on: attendanceDatePicker.date, fallbackHour: 16, fallbackMinute: 30)
        }
        fromPicker.isEnabled = attendanceDay?.checkIn == nil
        toPicker.isEnabled = attendanceDay?.checkOut == nil
        let inText = attendanceDay?.checkIn.flatMap(VietnamTime.date(fromISO8601:)).map { VietnamTime.clock.string(from: $0) } ?? "Chưa có"
        let outText = attendanceDay?.checkOut.flatMap(VietnamTime.date(fromISO8601:)).map { VietnamTime.clock.string(from: $0) } ?? "Chưa có"
        attendanceStatusLabel.text = "Giờ vào: \(inText) · Giờ ra: \(outText)"
        renderValidation()
    }

    private func label(_ text: String, style: UIFont.TextStyle, weight: UIFont.Weight = .regular, color: UIColor) -> UILabel {
        let result = UILabel()
        result.text = text
        result.font = UIFont.preferredFont(forTextStyle: style).requestWeight(weight)
        result.adjustsFontForContentSizeCategory = true
        result.textColor = color
        result.numberOfLines = 0
        return result
    }

    private var dateTitle: String {
        switch kind {
        case .leave: return "Thời gian xin nghỉ"
        case .business: return "Thời gian công tác"
        case .gate: return "Thời gian ra cổng"
        case .sunday: return "Thời gian làm chủ nhật"
        case .attendance: return "Thời gian chấm công"
        default: return "Thời gian"
        }
    }

    private func section(_ title: String, _ control: UIView) -> UIView {
        let box = UIStackView()
        box.axis = .vertical; box.spacing = 7
        let label = UILabel(); label.text = title.uppercased(); label.font = .preferredFont(forTextStyle: .caption1).withSize(12); label.textColor = .secondaryLabel
        box.addArrangedSubview(label); box.addArrangedSubview(control)
        return box
    }

    private func dateSection(title: String, start: UIDatePicker, end: UIDatePicker) -> UIView {
        let box = UIStackView(); box.axis = .vertical; box.spacing = 7
        let label = UILabel(); label.text = title.uppercased(); label.font = .preferredFont(forTextStyle: .caption1).withSize(12); label.textColor = .secondaryLabel
        let row = UIStackView(); row.axis = .vertical; row.spacing = 8
        row.addArrangedSubview(labeledControl("Bắt đầu", start)); row.addArrangedSubview(labeledControl("Kết thúc", end))
        box.addArrangedSubview(label); box.addArrangedSubview(row)
        return box
    }

    private func labeledControl(_ title: String, _ control: UIView) -> UIView {
        let row = UIStackView(); row.axis = .horizontal; row.alignment = .center
        let label = UILabel(); label.text = title; label.textColor = .secondaryLabel
        row.addArrangedSubview(label); row.addArrangedSubview(UIView()) ; row.addArrangedSubview(control)
        return row
    }

    private func reasonSection() -> UIView {
        let holder = UIView(); holder.addSubview(reasonView); holder.addSubview(reasonPlaceholder)
        reasonView.translatesAutoresizingMaskIntoConstraints = false; reasonPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            reasonView.leadingAnchor.constraint(equalTo: holder.leadingAnchor), reasonView.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            reasonView.topAnchor.constraint(equalTo: holder.topAnchor), reasonView.bottomAnchor.constraint(equalTo: holder.bottomAnchor), reasonView.heightAnchor.constraint(equalToConstant: 150),
            reasonPlaceholder.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 16), reasonPlaceholder.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16), reasonPlaceholder.topAnchor.constraint(equalTo: holder.topAnchor, constant: 16)
        ])
        return holder
    }

    private var selectedTransport: String { transportButton.accessibilityIdentifier ?? "personal_vehicle" }
    private func setTransport(_ value: String) {
        transportButton.accessibilityIdentifier = value
        let options = [("personal_vehicle", "Xe cá nhân"), ("grab", "Grab"), ("company_vehicle", "Xe công ty")]
        transportButton.configuration?.title = options.first { $0.0 == value }?.1 ?? "Xe cá nhân"
        transportButton.menu = UIMenu(children: options.map { code, title in
            UIAction(title: title, state: code == value ? .on : .off) { [weak self] _ in self?.setTransport(code); self?.rebuildForm() }
        })
    }

    private func updateRecipientsTitle() {
        guard recipientsLoaded else { recipientsButton.configuration?.title = "Tôi"; return }
        let selected = store.managedEmployees.filter { selectedRecipientIDs.contains($0.id) }
        let all = Set(store.managedEmployees.map(\.id))
        let title: String
        if selected.isEmpty { title = "Chưa chọn người" }
        else if selected.count == 1 && selected[0].isSelf { title = "Tôi" }
        else if selected.count > 1 && !all.isEmpty && selectedRecipientIDs.isSuperset(of: all) { title = "Tất cả" }
        else { title = selected.map { $0.isSelf ? "Tôi" : $0.fullName }.joined(separator: ", ") }
        recipientsButton.configuration?.title = title
    }

    @objc private func showRecipients() {
        guard recipientsLoaded else { return }
        let picker = LegacyRequestRecipientsController(
            employees: store.managedEmployees,
            selectedIDs: selectedRecipientIDs,
            hasChosenManagedEmployee: hasChosenManagedEmployee
        ) { [weak self] selected, hasChosenManagedEmployee in
            self?.selectedRecipientIDs = selected
            self?.hasChosenManagedEmployee = hasChosenManagedEmployee
            self?.updateRecipientsTitle()
            self?.renderValidation()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    @objc private func close() { dismiss(animated: true) }

    private var validationMessage: String? {
        let reason = reasonView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.count < 10 { return "Nội dung đơn cần tối thiểu 10 ký tự." }
        if recipientsLoaded && selectedRecipientIDs.isEmpty { return "Chọn ít nhất một người tạo đơn." }
        if kind == .business {
            if (destinationField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 2 { return "Nhập nơi công tác để gửi đơn." }
            if selectedTransport == "personal_vehicle" && !(decimalValue(distanceField) ?? 0 > 0) { return "Nhập quãng đường khi đi bằng xe cá nhân." }
        }
        if [.late, .early, .overtime].contains(kind) {
            let rawMinutes = decimalValue(durationField) ?? 0
            let minutes = Int(rawMinutes)
            if rawMinutes != Double(minutes) || minutes < 5 || minutes > 1435 || !minutes.isMultiple(of: 5) { return "Thời lượng phải từ 5 phút đến 23 giờ 55 phút, theo bước 5 phút." }
        }
        if kind == .sunday && VietnamTime.calendar.component(.weekday, from: fromPicker.date) != 1 { return "Ngày bắt đầu phải là Chủ nhật." }
        if kind == .sunday && toPicker.date <= fromPicker.date { return "Giờ kết thúc phải sau giờ bắt đầu." }
        if ![.late, .early, .overtime].contains(kind), toPicker.date < fromPicker.date { return "Thời gian kết thúc phải sau thời gian bắt đầu." }
        return nil
    }

    private func renderValidation() {
        let warning = isSending ? nil : validationMessage
        validationLabel.text = warning
        validationLabel.isHidden = warning == nil
        var configuration = submitButton.configuration
        configuration?.baseBackgroundColor = warning == nil && !isSending ? .systemRed : .systemGray3
        configuration?.background.backgroundColor = warning == nil && !isSending ? .systemRed : .systemGray3
        configuration?.title = isSending ? "Đang gửi…" : "Gửi đơn"
        submitButton.configuration = configuration
        submitButton.isEnabled = warning == nil && !isSending
        navigationController?.isModalInPresentation = isSending || scheduleEdited || currentInput != initialInput
    }

    private var currentInput: [String] {
        [reasonView.text, destinationField.text, distanceField.text, expenseField.text]
            .map { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func decimalValue(_ field: UITextField) -> Double? {
        Double(field.text?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".") ?? "")
    }

    @objc private func send() {
        guard !isSending else { return }
        if let warning = validationMessage { showError(warning); return }
        let cleanReason = reasonView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric: (UITextField) -> Double? = { [weak self] in self?.decimalValue($0) }
        let destination = destinationField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .business && (destination?.count ?? 0) < 2 { showError("Nhập nơi công tác để gửi đơn."); return }
        if kind == .business && selectedTransport == "personal_vehicle" && !(numeric(distanceField) ?? 0 > 0) { showError("Nhập quãng đường khi đi bằng xe cá nhân."); return }
        var from = fromPicker.date
        var to = toPicker.date
        var submittedReason = cleanReason
        if [.late, .early, .overtime].contains(kind) {
            let rawMinutes = numeric(durationField) ?? 0
            let minutes = Int(rawMinutes)
            guard rawMinutes == Double(minutes), minutes >= 5, minutes <= 1435, minutes.isMultiple(of: 5) else { showError("Thời lượng phải từ 5 phút đến 23 giờ 55 phút, theo bước 5 phút."); return }
            let day = VietnamTime.calendar.startOfDay(for: dayPicker.date)
            let start = scheduledTime(workStartTime, on: day, fallbackHour: 7, fallbackMinute: 30)
            let end = scheduledTime(workEndTime, on: day, fallbackHour: 16, fallbackMinute: 30)
            if kind == .late { from = start; to = start.addingTimeInterval(TimeInterval(minutes * 60)) }
            if kind == .early { from = end.addingTimeInterval(TimeInterval(-minutes * 60)); to = end }
            if kind == .overtime { from = end; to = end.addingTimeInterval(TimeInterval(minutes * 60)) }
            submittedReason = "\(kind.title): \(DurationClock.title(minutes: minutes)). \(cleanReason)"
        }
        guard to >= from else { showError("Thời gian kết thúc phải sau thời gian bắt đầu."); return }
        if kind == .sunday && VietnamTime.calendar.component(.weekday, from: from) != 1 { showError("Ngày bắt đầu phải là Chủ nhật."); return }
        if kind == .sunday && to <= from { showError("Giờ kết thúc phải sau giờ bắt đầu."); return }
        isSending = true
        renderValidation()
        Task { [weak self] in
            guard let self else { return }
            let error = await submitRequest(kind, from, to, submittedReason, destination, kind == .business ? selectedTransport : nil, kind == .business ? numeric(distanceField) : nil, kind == .business ? numeric(expenseField) : nil, recipientsLoaded ? Array(selectedRecipientIDs) : nil)
            guard !Task.isCancelled else { return }
            isSending = false
            renderValidation()
            if let error { showError(error) } else { UINotificationFeedbackGenerator().notificationOccurred(.success); dismiss(animated: true) }
        }
    }

    private func showError(_ text: String) {
        let alert = UIAlertController(title: "Chưa thể gửi đơn", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đã hiểu", style: .default))
        present(alert, animated: true)
    }

    func textViewDidChange(_ textView: UITextView) { updateReasonPlaceholder(); renderValidation() }
    private func updateReasonPlaceholder() { reasonPlaceholder.isHidden = !reasonView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func numberText(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(value) }
}

@MainActor
private final class LegacyRequestRecipientsController: UIViewController {
    private let employees: [ManagedRequestEmployee]
    private var selectedIDs: Set<String>
    private var hasChosenManagedEmployee: Bool
    private let completion: (Set<String>, Bool) -> Void
    private let scroll = UIScrollView()
    private let content = UIStackView()

    init(
        employees: [ManagedRequestEmployee],
        selectedIDs: Set<String>,
        hasChosenManagedEmployee: Bool,
        completion: @escaping (Set<String>, Bool) -> Void
    ) {
        self.employees = employees
        self.selectedIDs = selectedIDs
        self.hasChosenManagedEmployee = hasChosenManagedEmployee
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Tạo đơn cho"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Xong", style: .done, target: self, action: #selector(done))
        view.backgroundColor = .systemGroupedBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.showsVerticalScrollIndicator = false
        content.translatesAutoresizingMaskIntoConstraints = false; content.axis = .vertical; content.spacing = 12
        view.addSubview(scroll); scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20), content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20), content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        render()
    }

    private func render() {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        let selfPerson = employees.first(where: \.isSelf)
        let allIDs = Set(employees.map(\.id))
        let firstRow = UIStackView(); firstRow.axis = .horizontal; firstRow.spacing = 8; firstRow.distribution = .fillEqually
        if let selfPerson { firstRow.addArrangedSubview(tile("Tôi", selected: selectedIDs.contains(selfPerson.id)) { [weak self] in self?.toggle(selfPerson.id) }) }
        firstRow.addArrangedSubview(tile("Tất cả", selected: !allIDs.isEmpty && selectedIDs.isSuperset(of: allIDs)) { [weak self] in
            guard let self else { return }
            self.hasChosenManagedEmployee = true
            self.selectedIDs = self.selectedIDs.isSuperset(of: allIDs) ? [] : allIDs
            self.render()
        })
        if selfPerson == nil { firstRow.addArrangedSubview(UIView()) }
        content.addArrangedSubview(firstRow)
        let directReports = employees.filter { !$0.isSelf }
        guard !directReports.isEmpty else { return }
        let title = UILabel(); title.text = "TẠO ĐƠN CÙNG NHÂN VIÊN"; title.font = UIFont.preferredFont(forTextStyle: .caption1).requestWeight(.bold); title.textColor = .secondaryLabel
        content.addArrangedSubview(title)
        for index in stride(from: 0, to: directReports.count, by: 2) {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 8; row.distribution = .fillEqually
            let first = directReports[index]
            row.addArrangedSubview(tile(first.fullName, selected: selectedIDs.contains(first.id)) { [weak self] in self?.toggleManagedEmployee(first.id) })
            if index + 1 < directReports.count {
                let second = directReports[index + 1]
                row.addArrangedSubview(tile(second.fullName, selected: selectedIDs.contains(second.id)) { [weak self] in self?.toggleManagedEmployee(second.id) })
            } else { row.addArrangedSubview(UIView()) }
            content.addArrangedSubview(row)
        }
    }

    private func tile(_ title: String, selected: Bool, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title; config.titleAlignment = .leading
        config.titleLineBreakMode = .byWordWrapping
        config.baseForegroundColor = selected ? .systemGreen : .label
        config.background.backgroundColor = selected ? UIColor.systemGreen.withAlphaComponent(0.14) : .secondarySystemGroupedBackground
        config.background.strokeColor = selected ? UIColor.systemGreen.withAlphaComponent(0.65) : UIColor.separator.withAlphaComponent(0.25)
        config.background.strokeWidth = 1; config.background.cornerRadius = 12
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.titleLabel?.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: UIFont.systemFont(ofSize: 17, weight: .semibold),
            maximumPointSize: 22
        )
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.lineBreakMode = .byWordWrapping
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        return button
    }

    private func toggle(_ id: String) { if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }; render() }
    private func toggleManagedEmployee(_ id: String) {
        guard let selfID = employees.first(where: \.isSelf)?.id else {
            toggle(id)
            return
        }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else if !hasChosenManagedEmployee && selectedIDs == [selfID] {
            hasChosenManagedEmployee = true
            selectedIDs = [id]
        } else {
            hasChosenManagedEmployee = true
            selectedIDs.insert(id)
        }
        render()
    }
    @objc private func done() { completion(selectedIDs, hasChosenManagedEmployee); navigationController?.popViewController(animated: true) }
}

private extension UIFont {
    func requestWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

struct RequestComposer: View {
    /// Đi trễ, Về sớm and Làm thêm giờ last 5 minutes to 23 giờ 55 phút, in
    /// 5-minute steps: what Apple's time picker can show as hh:mm
    /// (`DurationClock`).
    private static let durationRange = 5...1435
    private static let durationStep = 5

    @Environment(\.dismiss) private var dismiss
    // Only calls session methods and reads the shift times once: the form
    // must not redraw (while typing) on every session change.
    @Environment(\.sessionActions) private var sessionActions
    @EnvironmentObject private var requestStore: EmployeeRequestStore
    private var session: SessionStore { sessionActions.store }
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
    @State private var durationMinutes = 30
    @FocusState private var reasonFocused: Bool
    @State private var leaveScheduleWasInitialized = false
    @FocusState private var focusedInput: RequestInputFocus?

    private enum RequestInputFocus: Hashable {
        case destination
        case distance
        case expense
    }
    /// Returns nil on success, otherwise the reason the server rejected it.
    let submit: (EmployeeRequestKind, Date, Date, String, String?, String?, Double?, Double?, [String]?) async -> String?
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
    @State private var selectedRecipientIDs = Set<String>()
    @State private var recipientsInitialized = false
    @State private var showingRecipientPicker = false

    init(
        template: EmployeeRequest? = nil,
        submit: @escaping (EmployeeRequestKind, Date, Date, String, String?, String?, Double?, Double?, [String]?) async -> String?
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
        if let minutes = prefill.durationMinutes {
            _durationMinutes = State(initialValue: minutes)
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
    /// Pairs that belong together: whole-day absence (Xin nghỉ, Công tác),
    /// shift deviations (Đi trễ, Về sớm), extra work (Làm thêm giờ, Làm chủ
    /// nhật), then Ra cổng and Xác nhận giờ công. Same order on Android and web.
    private var compactRequestKinds: [EmployeeRequestKind] {
        [.leave, .business, .late, .early, .overtime, .sunday, .gate, .attendance]
    }
    /// "30 phút", "2 giờ", "1 giờ 30 phút": shown, and sent at the head of
    /// the reason, where `RequestReasonPrefill` reads it back.
    private var durationDescription: String { DurationClock.title(minutes: durationMinutes) }
    private var workStartTime: String? { session.dashboard?.workStartTime }
    private var workEndTime: String? { session.dashboard?.workEndTime }
    private var recipientSummary: String {
        guard requestStore.managedEmployeesLoaded else { return "Tôi" }
        let people = requestStore.managedEmployees
        let eligibleIDs = Set(people.map(\.id))
        let selected = people.filter { selectedRecipientIDs.contains($0.id) }
        if selected.isEmpty { return recipientsInitialized ? "Chưa chọn người" : "Tôi" }
        if selected.count == 1 && selected[0].isSelf { return "Tôi" }
        if selected.count > 1 && !eligibleIDs.isEmpty && selectedRecipientIDs.isSuperset(of: eligibleIDs) { return "Tất cả" }
        return selected.map { $0.isSelf ? "Tôi" : $0.fullName }.joined(separator: ", ")
    }

    private func initializeRecipientsIfNeeded() {
        guard requestStore.managedEmployeesLoaded, !recipientsInitialized else { return }
        selectedRecipientIDs = Set(requestStore.managedEmployees.filter(\.isSelf).map(\.id))
        recipientsInitialized = true
    }

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


    private var submissionDates: (from: Date, to: Date) {
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

    /// A missing time is chosen like the booking's Bắt đầu: the whole card
    /// is a button opening Apple's popover with Apple's time wheels
    /// (`DatePopoverButton`).
    @ViewBuilder private func attendanceTimeCard(title: String, value: String?, missingPrompt: String, selection: Binding<Date>) -> some View {
        if value == nil {
            attendanceTimeCardFace(title: title, value: value, chosen: selection.wrappedValue)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .overlay(DatePopoverButton(
                    selection: selection,
                    accessibilityLabel: missingPrompt,
                    accessibilityValue: VietnamTime.clock.string(from: selection.wrappedValue)
                ))
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
        if requestStore.managedEmployeesLoaded && selectedRecipientIDs.isEmpty {
            return "Chọn ít nhất một người tạo đơn."
        }
        if kind == .sunday && to <= from { return "Giờ kết thúc phải sau giờ bắt đầu." }
        if cleanReason.count < 10 { return "Nội dung đơn cần tối thiểu 10 ký tự." }
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
                            .font(.title.bold())
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Tạo đơn cho", systemImage: "person.2.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                        Button { showingRecipientPicker = true } label: {
                            HStack(spacing: 10) {
                                Text(recipientSummary)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppTheme.muted)
                            }
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(AppTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $showingRecipientPicker) {
                            RequestRecipientsPickerSheet(
                                store: requestStore,
                                token: session.token,
                                selectedIDs: $selectedRecipientIDs
                            )
                        }
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
                            DatePopoverField(
                                selection: editedByEmployee($attendanceDate),
                                mode: .date,
                                accessibilityLabel: "Ngày chấm công"
                            )
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
                                // DatePopoverField, as the other date and
                                // time fields.
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 10) {
                                        CompactDateRow(label: "Giờ vào") {
                                            DatePopoverField(selection: editedByEmployee($from), mode: .time, accessibilityLabel: "Giờ vào")
                                        }
                                        CompactDateRow(label: "Giờ ra") {
                                            DatePopoverField(selection: editedByEmployee($to), mode: .time, accessibilityLabel: "Giờ ra")
                                        }
                                    }
                                } else {
                                    HStack {
                                        DatePopoverField(selection: editedByEmployee($from), mode: .time, accessibilityLabel: "Giờ vào")
                                            .fixedSize()
                                        DatePopoverField(selection: editedByEmployee($to), mode: .time, accessibilityLabel: "Giờ ra")
                                            .fixedSize()
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
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
                            DatePopoverField(
                                selection: editedByEmployee($from),
                                mode: .date,
                                accessibilityLabel: "Ngày xảy ra"
                            )
                        }
                    }

                    if usesDurationInput {
                        VStack(alignment: .leading, spacing: 12) {
                            composerLabel("Thời lượng", icon: "timer")
                            durationTile
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        composerLabel("Nội dung đơn", icon: "text.alignleft")
                        ZStack(alignment: .topLeading) {
                            if reason.isEmpty {
                                Text("Mô tả lý do và thông tin cần người duyệt lưu ý")
                                    .font(.body)
                                    .foregroundStyle(AppTheme.muted.opacity(0.72))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 17)
                                    .allowsHitTesting(false)
                            }
                            // A UIViewRepresentable that writes height back to
                            // SwiftUI during updateUIView forms a layout/state
                            // feedback loop while this iOS 17 sheet is presented.
                            // Native TextEditor owns its own layout and scrolling.
                            TextEditor(text: $reason)
                                .focused($reasonFocused)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .frame(minHeight: 150, maxHeight: 260)
                        }
                        .background(AppTheme.card)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(reasonFocused ? AppTheme.red.opacity(0.78) : AppTheme.fieldBorder, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .id("request-reason-editor")

                    }
                    .id("request-reason")
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                // The submit footer already reserves its own safe-area
                // space. Extra 120pt padding made a large empty strip
                // after the last input when the form was scrolled.
                .padding(.bottom, 16)
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
            .task {
                await requestStore.loadManagedEmployees(session.token, employeeCode: session.profile?.employeeCode)
                initializeRecipientsIfNeeded()
            }
            .onChange(of: requestStore.managedEmployeesLoaded) { _, loaded in
                if loaded { initializeRecipientsIfNeeded() }
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
                    Button("Hủy") { dismiss() }
                        .foregroundStyle(AppTheme.muted)
                }
            }
            .onAppear { if initialInput == nil { initialInput = currentInput } }
            .interactiveDismissDisabled(hasUnsavedInput || isSubmitting)
            .safeAreaInset(edge: .bottom) {
                // Match the meeting-booking confirmation footer: validation
                // and server errors share one visible warning immediately
                // above Gửi đơn, inside the same rounded frosted card.
                VStack(spacing: 8) {
                    if !isSubmitting, let warning = submitError ?? missingRequirement {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color(uiColor: .separator).opacity(0.40), lineWidth: 0.75)
                            }
                    }

                    Button {
                        guard canSubmit && !isSubmitting else { return }
                        let dates = submissionDates
                        isSubmitting = true
                        submitError = nil
                        Task {
                            let employeeIDs = requestStore.managedEmployeesLoaded ? Array(selectedRecipientIDs) : nil
                            let error = await submit(kind, dates.from, dates.to, submissionReason, destination, transport, localizedDecimal(distanceKm), localizedDecimal(expense), employeeIDs)
                            isSubmitting = false
                            if let error {
                                submitError = error
                            } else {
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
                        .frame(maxWidth: .infinity)
                    }
                    // Apple's prominent button (it was a drawn red rectangle
                    // with a shadow); disabled, the system dims it.
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 17))
                    .controlSize(.large)
                    .tint(AppTheme.red)
                    .disabled(!canSubmit || isSubmitting)
                }
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
                    durationMinutes = 30
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

    /// One row per moment: the label, then the date and time at full width
    /// ("08:00  18 thg 10, 2026"). Only the label adapts to the room left
    /// beside it. At accessibility text sizes the label goes over the value.
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

    /// The date and time, opening Apple's popover with its wheels
    /// (`DatePopoverField`). UIKit presents it: a SwiftUI `.popover` inside
    /// this sheet closed the whole composer when tapped (seen on iOS 27).
    private func dateTimePicker(_ title: String, selection: Binding<Date>, range: PartialRangeFrom<Date>?) -> some View {
        DatePopoverField(
            selection: selection,
            mode: .dateAndTime,
            minimum: range?.lowerBound,
            accessibilityLabel: title
        )
    }

    /// The duration as the booking's Thời lượng: icon and chevron, caption,
    /// bold value, the whole tile a button opening Apple's popover with
    /// Apple's time wheels (`DatePopoverButton`). Their hours and minutes
    /// are the length: 01:30 is 1 giờ 30 phút.
    private var durationTile: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "timer")
                    .foregroundStyle(kind.color)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.muted)
            }
            Text("Thời lượng")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            Text(durationDescription)
                .font(.headline.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .overlay(DatePopoverButton(
            selection: durationClock,
            minuteInterval: Self.durationStep,
            minimum: DurationClock.date(forMinutes: Self.durationRange.lowerBound, calendar: VietnamTime.calendar),
            maximum: DurationClock.date(forMinutes: Self.durationRange.upperBound, calendar: VietnamTime.calendar),
            accessibilityLabel: "Thời lượng",
            accessibilityValue: durationDescription
        ))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// `durationMinutes` as the time Apple's time wheels show ("01:30").
    private var durationClock: Binding<Date> {
        Binding(
            get: { DurationClock.date(forMinutes: durationMinutes, calendar: VietnamTime.calendar) },
            set: {
                durationMinutes = DurationClock.minutes(
                    from: $0,
                    step: Self.durationStep,
                    range: Self.durationRange,
                    calendar: VietnamTime.calendar
                )
            }
        )
    }
}
