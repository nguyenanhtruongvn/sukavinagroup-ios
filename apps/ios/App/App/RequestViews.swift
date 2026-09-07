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
    case leave, late, early, overtime, business, attendance, gate
    var id: String { rawValue }
    var title: String {
        switch self { case .leave: return "Nghỉ phép"; case .late: return "Đi trễ"; case .early: return "Về sớm"; case .overtime: return "Làm thêm giờ"; case .business: return "Công tác"; case .attendance: return "Xác nhận giờ công"; case .gate: return "Ra cổng" }
    }
    var icon: String {
        switch self {
        case .leave: return "calendar.badge.minus"
        case .late: return "clock.badge.exclamationmark"
        case .early: return "figure.walk.departure"
        case .overtime: return "moon.stars.fill"
        case .business: return "airplane"; case .attendance: return "checkmark.circle"; case .gate: return "rectangle.portrait.and.arrow.right"
        }
    }
    var color: Color {
        switch self {
        case .leave: return .blue
        case .late: return .orange
        case .early: return Color(red: 0.9, green: 0.22, blue: 0.52)
        case .overtime: return Color(red: 0.32, green: 0.4, blue: 0.96)
        case .business: return Color(red: 0.0, green: 0.5, blue: 0.5); case .attendance: return .green; case .gate: return .purple
        }
    }
}

struct EmployeeRequest: Codable, Identifiable {
    struct EmployeeSummary: Codable { let fullName: String; let employeeCode: String }
    let id: String
    let kind: EmployeeRequestKind
    let from: Date
    let to: Date
    let reason: String
    let status: EmployeeRequestStatus
    let createdAt: Date
    let dueAt: Date
    let decisionNote: String?
    let autoApproved: Bool
    let employee: EmployeeSummary?

    enum CodingKeys: String, CodingKey {
        case id, kind, reason, status, createdAt, dueAt, decisionNote, autoApproved, employee
        case from = "startsAt"
        case to = "endsAt"
    }
}

struct RequestBody: Encodable { let kind: String; let startsAt: Date; let endsAt: Date; let reason: String; let businessDestination: String?; let businessTransport: String?; let businessDistanceKm: Double?; let businessExpense: Double? }
struct RequestDecisionBody: Encodable { let status: String; let note: String? }

@MainActor
@available(iOS 17.0, *)
final class EmployeeRequestStore: ObservableObject {
    @Published private(set) var requests: [EmployeeRequest] = []
    @Published private(set) var approvals: [EmployeeRequest] = []
    @Published var message: String?

    private func record(_ error: Error) {
        // SwiftUI cancels obsolete .task/.refreshable work when this view is
        // replaced or refreshed again. That is expected lifecycle behavior,
        // not an error the employee should see in the request screen.
        guard !(error is CancellationError) else { return }
        message = error.localizedDescription
    }

    func load(_ token: String?) async {
        guard let token else { return }
        do {
            async let mine: [EmployeeRequest] = APIClient.shared.request("me/requests", token: token)
            async let assigned: [EmployeeRequest] = APIClient.shared.request("me/requests/approvals", token: token)
            requests = try await mine
            approvals = try await assigned
        } catch { record(error) }
    }

    func submit(token: String?, kind: EmployeeRequestKind, from: Date, to: Date, reason: String, destination: String? = nil, transport: String? = nil, distanceKm: Double? = nil, expense: Double? = nil) async -> Bool {
        guard let token else { return false }
        do {
            let _: EmployeeRequest = try await APIClient.shared.request("me/requests", method: "POST", token: token, body: RequestBody(kind: kind.rawValue, startsAt: from, endsAt: to, reason: reason, businessDestination: destination, businessTransport: transport, businessDistanceKm: distanceKm, businessExpense: expense))
            await load(token); return true
        } catch { record(error); return false }
    }

    func cancel(token: String?, id: String) async {
        guard let token else { return }
        do { let _: EmployeeRequest = try await APIClient.shared.request("me/requests/\(id)", method: "DELETE", token: token); await load(token) }
        catch { record(error) }
    }

    func decide(token: String?, id: String, approved: Bool, note: String) async -> Bool {
        guard let token else { return false }
        do {
            let _: EmployeeRequest = try await APIClient.shared.request("me/requests/\(id)/decision", method: "PATCH", token: token, body: RequestDecisionBody(status: approved ? "approved" : "rejected", note: note.isEmpty ? nil : note))
            await load(token); return true
        } catch { record(error); return false }
    }
}

@available(iOS 17.0, *)
struct RequestsView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var store = EmployeeRequestStore()
    let initialFilter: EmployeeRequestStatus?
    @State private var filter: EmployeeRequestStatus?
    @State private var composing = false
    @State private var reviewing: EmployeeRequest?
    @State private var cancelling: EmployeeRequest?
    @State private var filterIndex = 0
    private var combinedRequests: [EmployeeRequest] {
        var seen = Set<String>()
        return (store.approvals + store.requests)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private var visible: [EmployeeRequest] { filter.map { value in combinedRequests.filter { $0.status == value } } ?? combinedRequests }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
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

                    TabView(selection: $filterIndex) {
                        ForEach(filterOptions.indices, id: \.self) { index in
                            requestPage(filterOptions[index])
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.easeInOut(duration: 0.22), value: filterIndex)
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
                .ignoresSafeArea(.container, edges: .bottom)

                Button { composing = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 58, height: 58)
                        .background(AppTheme.red)
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                        .shadow(color: AppTheme.red.opacity(0.38), radius: 18, y: 9)
                }
                .accessibilityLabel("Tạo đơn mới")
                .padding(.trailing, 20)
                .padding(.bottom, 18)
            }
            .background(AppTheme.ink.ignoresSafeArea()).navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $composing) {
                RequestComposer { kind, from, to, reason, destination, transport, distance, expense in
                    Task { _ = await store.submit(token: session.token, kind: kind, from: from, to: to, reason: reason, destination: destination, transport: transport, distanceKm: distance, expense: expense) }
                }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
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
                        Task { await store.cancel(token: session.token, id: request.id) }
                    },
                    secondaryButton: .cancel(Text("Giữ lại"))
                )
            }
            .task { await store.load(session.token) }
            .refreshable { await store.load(session.token) }
            .alert("Đơn từ", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("Đóng") { store.message = nil } } message: { Text(store.message ?? "") }
        }
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
        let requests = status.map { value in combinedRequests.filter { $0.status == value } } ?? combinedRequests
        ScrollView {
            if requests.isEmpty {
                ContentUnavailableView(
                    "Chưa có đơn",
                    systemImage: "doc.text",
                    description: Text("Không có đơn trong trạng thái này.")
                )
                .padding(.top, 70)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(requests) { request in
                        if store.approvals.contains(where: { $0.id == request.id && $0.status == .pending }) {
                            Button { reviewing = request } label: {
                                RequestCard(request: request, canCancel: false, cancel: {})
                            }
                            .buttonStyle(.plain)
                        } else {
                            RequestCard(request: request) { cancelling = request }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 112)
            }
        }
        .hidesPortalBottomScrollEdgeEffect()
        .refreshable { await store.load(session.token) }
    }
}

@available(iOS 17.0, *)
struct RequestCard: View {
    let request: EmployeeRequest
    var canCancel = true
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
        }.padding(16).background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)).shadow(color: Color.black.opacity(0.035), radius: 5, y: 2)
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            requestIcon
            VStack(alignment: .leading, spacing: 6) {
                Text(request.employee?.fullName ?? "Đơn của tôi").font(.headline).lineLimit(1)
                HStack(spacing: 7) {
                    kindBadge
                    Text(request.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(AppTheme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            statusBadge
        }
    }

    private var expandedHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                requestIcon
                Text(request.employee?.fullName ?? "Đơn của tôi")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                kindBadge
                Spacer(minLength: 8)
                statusBadge
            }
            Text(request.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
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
        if usesExpandedLayout {
            VStack(alignment: .leading, spacing: 6) {
                requestPeriodLine("Từ", request.from)
                requestPeriodLine("Đến", request.to)
            }
        } else {
            Label("\(request.from.formatted(date: .abbreviated, time: .shortened)) – \(request.to.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
        }
    }

    private func requestPeriodLine(_ title: String, _ date: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "calendar")
                .font(.caption)
            Text(title + ":")
                .font(.subheadline.weight(.semibold))
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(AppTheme.muted)
    }
}

@available(iOS 17.0, *)
struct RequestDecisionView: View {
    let request: EmployeeRequest
    let decide: (Bool, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    @State private var note = ""
    @State private var working = false
    @State private var rejecting = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                RequestCard(request: request, canCancel: false, cancel: {})
                Text(rejecting ? "Lý do từ chối" : "Ghi chú cho nhân viên (tùy chọn)").font(.headline)
                TextEditor(text: $note).scrollContentBackground(.hidden).padding(12).frame(minHeight: 130)
                    .background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 18))
                if rejecting { Text("Lý do từ chối là bắt buộc, tối thiểu 5 ký tự.").font(.caption).foregroundStyle(AppTheme.red) }
                HStack(spacing: 12) {
                    Button("Từ chối") { rejecting = true }.buttonStyle(.bordered).tint(AppTheme.red)
                    Button(rejecting ? "Xác nhận từ chối" : "Duyệt đơn") {
                        Task { working = true; if await decide(!rejecting, note.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }; working = false }
                    }
                    .buttonStyle(.borderedProminent).tint(rejecting ? AppTheme.red : .green)
                    .disabled(working || (rejecting && note.trimmingCharacters(in: .whitespacesAndNewlines).count < 5))
                }.frame(maxWidth: .infinity, alignment: .trailing)
                Spacer()
            }.padding(20).background(AppTheme.ink.ignoresSafeArea()).navigationTitle("Xử lý đơn")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } } }
        }
    }
}

@available(iOS 17.0, *)
struct RequestComposer: View {
    private enum DurationUnit: String, CaseIterable, Identifiable {
        case minutes
        case hours

        var id: String { rawValue }
        var title: String { self == .minutes ? "Phút" : "Giờ" }
        var maximumValue: Int { self == .minutes ? 60 : 24 }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var kind = EmployeeRequestKind.leave
    @State private var from = Date()
    @State private var to = Calendar.current.date(byAdding: .hour, value: 8, to: Date()) ?? Date()
    @State private var reason = ""
    @State private var attendanceDate = Calendar.current.startOfDay(for: Date())
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
    let submit: (EmployeeRequestKind, Date, Date, String, String?, String?, Double?, Double?) -> Void
    private var cleanReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var usesCompactDateRows: Bool { dynamicTypeSize <= .large }
    private var usesDurationInput: Bool { [.late, .early, .overtime].contains(kind) }
    private var singleDayEventName: String { kind == .late ? "đi trễ" : "về sớm" }
    private var compactRequestKinds: [EmployeeRequestKind] {
        EmployeeRequestKind.allCases.filter { $0 != .attendance }
    }
    private var durationMinutes: Int { durationUnit == .hours ? durationValue * 60 : durationValue }
    private var durationDescription: String { "\(durationValue) \(durationUnit.title.lowercased())" }
    private var workStartTime: String? { session.dashboard?.workStartTime }
    private var workEndTime: String? { session.dashboard?.workEndTime }

    private func applyInitialLeaveSchedule() {
        guard kind == .leave, !leaveScheduleWasInitialized else { return }
        let leaveDay = Calendar.current.startOfDay(for: from)
        from = scheduledAttendanceTime(workStartTime, on: leaveDay, fallbackHour: 7, fallbackMinute: 30)
        to = scheduledAttendanceTime(workEndTime, on: leaveDay, fallbackHour: 16, fallbackMinute: 30)
        leaveScheduleWasInitialized = true
    }

    private var scheduledRequestDates: (from: Date, to: Date) {
        let calendar = Calendar.current
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "HH:mm"
        let dates = scheduledRequestDates
        return "Khung giờ theo ca làm: \(formatter.string(from: dates.from)) – \(formatter.string(from: dates.to))."
    }

    private var submissionDates: (from: Date, to: Date) {
        let calendar = Calendar.current
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
    @ViewBuilder private func businessTransportButton(_ title: String, key: String, icon: String) -> some View {
        Button { transport = key } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(transport == key ? EmployeeRequestKind.business.color.opacity(0.18) : AppTheme.card)
                .foregroundStyle(transport == key ? EmployeeRequestKind.business.color : Color.primary)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(transport == key ? EmployeeRequestKind.business.color : Color.primary.opacity(0.1), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func labeledNumberField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.muted)
            TextField(placeholder, text: text).keyboardType(.decimalPad)
                .padding(.horizontal, 14).frame(height: 48)
                .background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
    private func attendanceDateKey(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    @ViewBuilder private func attendanceTimeCard(title: String, value: String?, selection: Binding<Date>) -> some View {
        let compact = dynamicTypeSize <= .large
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.muted)
            Text(attendanceTime(value))
                .font(compact ? .headline.weight(.bold) : .title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? AppTheme.red : .green)
            if value == nil {
                DatePicker("Nhập giờ", selection: selection, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        guard let value else { return "Thiếu" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return "Thiếu" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "vi_VN"); formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func scheduledAttendanceTime(_ time: String?, on date: Date, fallbackHour: Int, fallbackMinute: Int) -> Date {
        let parts = time?.split(separator: ":").compactMap { Int($0) } ?? []
        let hour = parts.count == 2 && (0...23).contains(parts[0]) ? parts[0] : fallbackHour
        let minute = parts.count == 2 && (0...59).contains(parts[1]) ? parts[1] : fallbackMinute
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    private var canSubmit: Bool {
        let dates = submissionDates
        return (kind == .business || cleanReason.count >= 10)
            && dates.to >= dates.from
            && (kind != .business || (destination.count >= 2 && (transport != "personal_vehicle" || Double(distanceKm) ?? 0 > 0)))
    }

    private func requestTimeRange(title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            composerLabel(title, icon: icon)
            VStack(spacing: 10) {
                dateRow("Bắt đầu", selection: $from)
                dateRow("Kết thúc", selection: $to, range: from...)
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
                ScrollView {
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

                        Text("Tạo đơn mới")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Điền thông tin rõ ràng để đơn được xử lý nhanh hơn.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.muted)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        composerLabel("Loại đơn", icon: "square.grid.2x2")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(compactRequestKinds) { requestKindButton($0) }
                        }
                        requestKindButton(.attendance, fullWidth: true)
                    }

                    if kind == .attendance {
                        VStack(alignment: .leading, spacing: 12) {
                            composerLabel("Ngày đối chiếu", icon: "calendar.badge.clock")
                            DatePicker("Ngày chấm công", selection: $attendanceDate, displayedComponents: .date)
                                .datePickerStyle(.compact)
                            if let day = attendanceDay {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(spacing: 10) {
                                        attendanceTimeCard(title: "GIỜ VÀO", value: day.checkIn, selection: $from)
                                        attendanceTimeCard(title: "GIỜ RA", value: day.checkOut, selection: $to)
                                    }
                                } else {
                                    HStack(spacing: 10) {
                                        attendanceTimeCard(title: "GIỜ VÀO", value: day.checkIn, selection: $from)
                                        attendanceTimeCard(title: "GIỜ RA", value: day.checkOut, selection: $to)
                                    }
                                }
                            } else {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 10) {
                                        DatePicker("Giờ vào", selection: $from, displayedComponents: .hourAndMinute)
                                        DatePicker("Giờ ra", selection: $to, displayedComponents: .hourAndMinute)
                                    }
                                } else {
                                    HStack {
                                        DatePicker("Giờ vào", selection: $from, displayedComponents: .hourAndMinute).labelsHidden()
                                        DatePicker("Giờ ra", selection: $to, displayedComponents: .hourAndMinute).labelsHidden()
                                    }
                                }
                                Text("Chưa có dữ liệu: nhập cả giờ vào và giờ ra để gửi yêu cầu bổ sung.").foregroundStyle(AppTheme.muted)
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
                                    .padding(.horizontal, 14).frame(height: 48)
                                    .background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("PHƯƠNG TIỆN").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.muted)
                                HStack(spacing: 8) {
                                    businessTransportButton("Xe cá nhân", key: "personal_vehicle", icon: "car.fill")
                                    businessTransportButton("Grab", key: "grab", icon: "location.fill")
                                    businessTransportButton("Xe công ty", key: "company_vehicle", icon: "building.2.fill")
                                }
                            }
                            if transport == "personal_vehicle" {
                                labeledNumberField("Số km", placeholder: "Nhập số km", text: $distanceKm)
                            }
                            labeledNumberField("Chi phí", placeholder: "Nhập chi phí (VNĐ)", text: $expense)
                            Text("Không cần nhập lý do cho đơn công tác.")
                                .font(.footnote).foregroundStyle(AppTheme.muted)
                        }
                    }
                    if kind == .gate {
                        requestTimeRange(title: "Thời gian ra cổng", icon: "calendar.badge.clock")
                    }
                    if kind == .leave {
                        requestTimeRange(title: "Thời gian nghỉ phép", icon: "calendar.badge.clock")
                    }

                    if kind == .late || kind == .early {
                        VStack(alignment: .leading, spacing: 12) {
                            composerLabel(kind == .late ? "Ngày đi trễ" : "Ngày về sớm", icon: "calendar")
                            DatePicker("Ngày xảy ra", selection: $from, displayedComponents: .date)
                                .datePickerStyle(.compact)
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
                                : min(durationValue, unit.maximumValue)
                        }
                    }

                    if kind != .business {
                    VStack(alignment: .leading, spacing: 12) {
                        composerLabel("Nội dung đơn", icon: "text.alignleft")
                        ZStack(alignment: .topLeading) {
                            if reason.isEmpty {
                                Text(kind == .attendance ? "Mô tả phần giờ công cần xác nhận hoặc thông tin người duyệt cần lưu ý..." : "Mô tả lý do và thông tin cần người duyệt lưu ý...")
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
                                .stroke(reasonFocused ? AppTheme.red.opacity(0.78) : Color.white.opacity(0.08), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        HStack {
                            Label(cleanReason.count >= 10 ? "Nội dung hợp lệ" : "Tối thiểu 10 ký tự", systemImage: cleanReason.count >= 10 ? "checkmark.circle.fill" : "info.circle")
                                .foregroundStyle(cleanReason.count >= 10 ? Color.green : AppTheme.muted)
                            Spacer()
                            Text("\(reason.count) ký tự").foregroundStyle(AppTheme.muted)
                        }
                        .font(.caption.weight(.medium))
                    }
                    .id("request-composer-reason")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 120)
            }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: reasonFocused) { _, focused in
                    guard focused else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("request-composer-reason", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: reasonEditorHeight) { _, _ in
                    guard reasonFocused else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("request-composer-reason", anchor: .bottom)
                    }
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
                let month = attendanceDateKey(attendanceDate, format: "yyyy-MM")
                let selectedKey = attendanceDateKey(attendanceDate, format: "yyyy-MM-dd")
                attendanceDay = nil
                if let data = try? await APIClient.shared.request("me/attendance?month=" + month, token: token) as AttendanceMonth {
                    attendanceDay = data.days.first { $0.date == selectedKey }
                    let scheduleStart = attendanceDay?.startTime ?? data.startTime
                    let scheduleEnd = attendanceDay?.endTime ?? data.endTime
                    from = attendanceDay?.checkIn.flatMap { ISO8601DateFormatter().date(from: $0) }
                        ?? scheduledAttendanceTime(scheduleStart, on: attendanceDate, fallbackHour: 7, fallbackMinute: 30)
                    to = attendanceDay?.checkOut.flatMap { ISO8601DateFormatter().date(from: $0) }
                        ?? scheduledAttendanceTime(scheduleEnd, on: attendanceDate, fallbackHour: 16, fallbackMinute: 30)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hủy") { dismiss() }
                        .foregroundStyle(AppTheme.muted)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let dates = submissionDates
                    submit(kind, dates.from, dates.to, kind == .business ? "" : submissionReason, destination, transport, Double(distanceKm), Double(expense))
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "paperplane.fill")
                        Text("Gửi đơn")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(canSubmit ? AppTheme.red : AppTheme.red.opacity(0.32))
                    .foregroundStyle(canSubmit ? Color.white : Color.white.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: canSubmit ? AppTheme.red.opacity(0.28) : .clear, radius: 16, y: 7)
                }
                .disabled(!canSubmit)
                .padding(.horizontal, 20)
                .padding(.top, 12)
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
                } else if [.late, .early, .overtime].contains(newKind) {
                    durationValue = 30
                    durationUnit = .minutes
                    from = Calendar.current.startOfDay(for: now)
                    to = from.addingTimeInterval(30 * 60)
                }
            }
        }
    }

    private func composerLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func dateRow(_ title: String, selection: Binding<Date>, range: PartialRangeFrom<Date>? = nil) -> some View {
        if usesCompactDateRows {
            HStack(spacing: 12) {
                requestDateLabel(title)
                Spacer(minLength: 8)
                dateTimePicker(selection: selection, range: range)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                requestDateLabel(title)
                dateTimePicker(selection: selection, range: range)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        }
    }

    private func requestDateLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: title == "Bắt đầu" ? "arrow.right.circle.fill" : "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
        .foregroundStyle(title == "Bắt đầu" ? AppTheme.red : Color.green)
        .layoutPriority(1)
    }

    @ViewBuilder
    private func dateTimePicker(selection: Binding<Date>, range: PartialRangeFrom<Date>?) -> some View {
        if let range {
            DatePicker("", selection: selection, in: range, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden().datePickerStyle(.compact)
        } else {
            DatePicker("", selection: selection, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden().datePickerStyle(.compact)
        }
    }

    private var durationValueMenu: some View {
        durationMenu(title: "Số lượng", value: "\(durationValue)") {
            Picker("Số lượng", selection: $durationValue) {
                ForEach(1...durationUnit.maximumValue, id: \.self) { value in
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

    @ViewBuilder
    private func dateOnlyRow(_ title: String, selection: Binding<Date>, range: PartialRangeFrom<Date>? = nil) -> some View {
        if usesCompactDateRows {
            HStack(spacing: 12) {
                leaveDateLabel(title)
                Spacer(minLength: 8)
                dateOnlyPicker(selection: selection, range: range)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                leaveDateLabel(title)
                dateOnlyPicker(selection: selection, range: range)
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        }
    }

    private func leaveDateLabel(_ title: String) -> some View {
        Label(title, systemImage: title == "Từ ngày" ? "calendar.badge.plus" : "calendar.badge.checkmark")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(title == "Từ ngày" ? AppTheme.red : Color.green)
            .lineLimit(1)
    }

    @ViewBuilder
    private func dateOnlyPicker(selection: Binding<Date>, range: PartialRangeFrom<Date>?) -> some View {
        if let range {
            DatePicker("", selection: selection, in: range, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.compact)
        } else {
            DatePicker("", selection: selection, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.compact)
        }
    }
}
