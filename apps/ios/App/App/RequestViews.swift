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
    case leave, late, early, overtime, business
    var id: String { rawValue }
    var title: String {
        switch self { case .leave: return "Nghỉ phép"; case .late: return "Đi trễ"; case .early: return "Về sớm"; case .overtime: return "Làm thêm giờ"; case .business: return "Công tác" }
    }
    var icon: String {
        switch self {
        case .leave: return "calendar.badge.minus"
        case .late: return "clock.badge.exclamationmark"
        case .early: return "figure.walk.departure"
        case .overtime: return "moon.stars.fill"
        case .business: return "airplane"
        }
    }
    var color: Color {
        switch self {
        case .leave: return .blue
        case .late: return .orange
        case .early: return Color(red: 0.9, green: 0.22, blue: 0.52)
        case .overtime: return Color(red: 0.32, green: 0.4, blue: 0.96)
        case .business: return Color(red: 0.0, green: 0.5, blue: 0.5)
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

struct RequestBody: Encodable { let kind: String; let startsAt: Date; let endsAt: Date; let reason: String }
struct RequestDecisionBody: Encodable { let status: String; let note: String? }

@MainActor
@available(iOS 17.0, *)
final class EmployeeRequestStore: ObservableObject {
    @Published private(set) var requests: [EmployeeRequest] = []
    @Published private(set) var approvals: [EmployeeRequest] = []
    @Published var message: String?

    func load(_ token: String?) async {
        guard let token else { return }
        do {
            async let mine: [EmployeeRequest] = APIClient.shared.request("me/requests", token: token)
            async let assigned: [EmployeeRequest] = APIClient.shared.request("me/requests/approvals", token: token)
            requests = try await mine
            approvals = try await assigned
        } catch { message = error.localizedDescription }
    }

    func submit(token: String?, kind: EmployeeRequestKind, from: Date, to: Date, reason: String) async -> Bool {
        guard let token else { return false }
        do {
            let _: EmployeeRequest = try await APIClient.shared.request("me/requests", method: "POST", token: token, body: RequestBody(kind: kind.rawValue, startsAt: from, endsAt: to, reason: reason))
            await load(token); return true
        } catch { message = error.localizedDescription; return false }
    }

    func cancel(token: String?, id: String) async {
        guard let token else { return }
        do { let _: EmployeeRequest = try await APIClient.shared.request("me/requests/\(id)", method: "DELETE", token: token); await load(token) }
        catch { message = error.localizedDescription }
    }

    func decide(token: String?, id: String, approved: Bool, note: String) async -> Bool {
        guard let token else { return false }
        do {
            let _: EmployeeRequest = try await APIClient.shared.request("me/requests/\(id)/decision", method: "PATCH", token: token, body: RequestDecisionBody(status: approved ? "approved" : "rejected", note: note.isEmpty ? nil : note))
            await load(token); return true
        } catch { message = error.localizedDescription; return false }
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
                RequestComposer { kind, from, to, reason in
                    Task { _ = await store.submit(token: session.token, kind: kind, from: from, to: to, reason: reason) }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: request.kind.icon).frame(width: 42, height: 42).background(request.kind.color.opacity(0.16)).foregroundStyle(request.kind.color).clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.employee?.fullName ?? "Đơn của tôi").font(.headline)
                    HStack(spacing: 7) {
                        Text(request.kind.title).font(.caption.bold()).foregroundStyle(request.kind.color).padding(.horizontal, 9).padding(.vertical, 4).background(request.kind.color.opacity(0.14)).clipShape(Capsule())
                        Text(request.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(AppTheme.muted)
                    }
                }
                Spacer()
                Text(request.status.title).font(.caption.bold()).foregroundStyle(request.status.color).padding(.horizontal, 10).padding(.vertical, 6).background(request.status.color.opacity(0.14)).clipShape(Capsule())
            }
            Label("\(request.from.formatted(date: .abbreviated, time: .shortened)) – \(request.to.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar").font(.subheadline).foregroundStyle(AppTheme.muted)
            Text(request.reason).font(.subheadline)
            if let note = request.decisionNote, !note.isEmpty { Label(note, systemImage: "text.bubble").font(.caption).foregroundStyle(AppTheme.muted) }
            if canCancel && request.status == .pending { Button("Hủy đơn", role: .destructive, action: cancel).font(.subheadline.bold()).frame(maxWidth: .infinity, alignment: .trailing) }
        }.padding(16).background(LinearGradient(colors: [request.kind.color.opacity(0.09), AppTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing)).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(request.kind.color.opacity(0.22), lineWidth: 1))
    }
}

@available(iOS 17.0, *)
struct RequestDecisionView: View {
    let request: EmployeeRequest
    let decide: (Bool, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
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
    @Environment(\.dismiss) private var dismiss
    @State private var kind = EmployeeRequestKind.leave
    @State private var from = Date()
    @State private var to = Calendar.current.date(byAdding: .hour, value: 8, to: Date()) ?? Date()
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool
    let submit: (EmployeeRequestKind, Date, Date, String) -> Void
    private var cleanReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { cleanReason.count >= 10 && to >= from }

    var body: some View {
        NavigationStack {
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
                            ForEach(EmployeeRequestKind.allCases) { item in
                                Button { kind = item } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: item.icon)
                                            .font(.system(size: 16, weight: .semibold))
                                        Text(item.title)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 13)
                                    .frame(maxWidth: .infinity, minHeight: 48)
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
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        composerLabel("Thời gian", icon: "calendar")
                        VStack(spacing: 0) {
                            dateRow("Bắt đầu", selection: $from)
                            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 44)
                            dateRow("Kết thúc", selection: $to, range: from...)
                        }
                        .padding(.horizontal, 14)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        composerLabel("Nội dung đơn", icon: "text.alignleft")
                        ZStack(alignment: .topLeading) {
                            if reason.isEmpty {
                                Text("Mô tả lý do và thông tin cần người duyệt lưu ý...")
                                    .font(.body)
                                    .foregroundStyle(AppTheme.muted.opacity(0.72))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 17)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $reason)
                                .focused($reasonFocused)
                                .scrollContentBackground(.hidden)
                                .padding(11)
                                .frame(minHeight: 150)
                                .background(Color.clear)
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
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 120)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hủy") { dismiss() }
                        .foregroundStyle(AppTheme.muted)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    submit(kind, from, to, cleanReason)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "paperplane.fill")
                        Text("Gửi đơn")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(canSubmit ? AppTheme.red : Color.white.opacity(0.08))
                    .foregroundStyle(canSubmit ? Color.white : AppTheme.muted)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: canSubmit ? AppTheme.red.opacity(0.28) : .clear, radius: 16, y: 7)
                }
                .disabled(!canSubmit)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(.ultraThinMaterial)
            }
            .onChange(of: from) { oldValue, newValue in
                if to < newValue {
                    let previousDuration = max(to.timeIntervalSince(oldValue), 60 * 60)
                    to = newValue.addingTimeInterval(previousDuration)
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
        HStack(spacing: 12) {
            Image(systemName: title == "Bắt đầu" ? "arrow.right.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(title == "Bắt đầu" ? AppTheme.red : Color.green)
                .font(.system(size: 20))
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if let range {
                DatePicker("", selection: selection, in: range)
                    .labelsHidden()
            } else {
                DatePicker("", selection: selection)
                    .labelsHidden()
            }
        }
        .frame(minHeight: 58)
    }
}
