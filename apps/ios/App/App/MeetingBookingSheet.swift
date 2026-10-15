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

struct MeetingBookingSheet: View {
    // Only calls session methods: must not redraw on every session change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @EnvironmentObject private var meetingStore: MeetingStore
    @Environment(\.dismiss) private var dismiss
    let room: MeetingRoom
    let day: Date

    @State private var title = ""
    @State private var meetingType = "Nội bộ"
    @State private var start = Date()
    @State private var durationValue = 30
    @State private var durationUnit = "phút"
    @State private var query = ""
    @State private var departmentQuery = ""
    @State private var selectedDepartments = Set<String>()
    @State private var selected = Set<String>()
    @State private var inviteesError: String?
    @State private var showStartPicker = false
    @State private var showDurationPicker = false
    @State private var isSubmittingBooking = false
    @State private var bookingErrorMessage: String?
    @State private var bookingErrorRevision = 0
    @FocusState private var focusedInviteeField: InviteeSearchField?

    private enum InviteeSearchField: Hashable {
        case people
        case departments
    }

    private var people: [MeetingInvitee] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty || !selectedDepartments.isEmpty else { return [] }
        return meetingStore.invitees.filter {
            (selectedDepartments.isEmpty || selectedDepartments.contains($0.department))
                && (trimmedQuery.isEmpty
                    || $0.fullName.localizedCaseInsensitiveContains(trimmedQuery)
                    || $0.employeeCode.localizedCaseInsensitiveContains(trimmedQuery))
        }
    }

    private var departments: [String] {
        Array(Set(meetingStore.invitees.map(\.department)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var selectedInvitees: [MeetingInvitee] {
        meetingStore.invitees.filter { selected.contains($0.id) }
    }

    private var matchingDepartments: [String] {
        let value = departmentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        return departments.filter { $0.localizedCaseInsensitiveContains(value) }
    }

    private var unselectedDepartmentInvitees: [MeetingInvitee] {
        guard !selectedDepartments.isEmpty else { return [] }
        return meetingStore.invitees.filter {
            selectedDepartments.contains($0.department) && !selected.contains($0.id)
        }
    }

    private var canInviteEntireDepartment: Bool {
        selected.count + unselectedDepartmentInvitees.count + 1 <= room.capacity
    }

    private var durationMinutes: Int {
        durationUnit == "giờ" ? durationValue * 60 : durationValue
    }

    private var isValid: Bool {
        selected.count + 1 <= room.capacity
    }

    private var bookingTitle: String {
        let content = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? meetingType : "\(meetingType) · \(content)"
    }

    private var canConfirmBooking: Bool {
        // Do not disable booking from NWPathMonitor alone. CFNetwork can have a
        // valid cellular route while the monitor is briefly stale.
        isValid && !isSubmittingBooking
    }

    private var endTime: Date {
        start.addingTimeInterval(Double(durationMinutes * 60))
    }

    private var dayLabel: String {
        VietnamTime.weekdayDate.string(from: day).capitalized
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            // Limit the generic type metadata resolved in one
                            // pass by iOS 17 while retaining the same native form.
                            AnyView(bookingHeader)
                            AnyView(meetingDetailsCard)
                            AnyView(inviteesCard)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 110)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: focusedInviteeField) { _, field in
                        guard field != nil else { return }
                        keepFocusedInviteeFieldVisible(using: proxy)
                    }
                    .onChange(of: selected) { _, _ in
                        keepFocusedInviteeFieldVisible(using: proxy)
                    }
                    .onChange(of: selectedDepartments) { _, _ in
                        keepFocusedInviteeFieldVisible(using: proxy)
                    }
                    .onChange(of: query) { _, _ in
                        guard focusedInviteeField == .people else { return }
                        keepFocusedInviteeFieldVisible(using: proxy)
                    }
                    .onChange(of: departmentQuery) { _, _ in
                        guard focusedInviteeField == .departments else { return }
                        keepFocusedInviteeFieldVisible(using: proxy)
                    }
                    // On iOS 18 the focus update precedes the keyboard safe-area
                    // update. Reposition once its final frame is known so the
                    // bottom of the active search field sits above the keyboard.
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
                        guard focusedInviteeField != nil else { return }
                        keepFocusedInviteeFieldVisible(using: proxy)
                    }
                }

                if let bookingErrorMessage {
                    VStack {
                        MeetingBookingErrorNotice(message: bookingErrorMessage)
                            .padding(.top, 10)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .zIndex(3)
                }
            }
            .safeAreaInset(edge: .bottom) {
                confirmButton
                    // Match the new-request submit button's compact frosted card.
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .onAppear { start = initialStartTime }
            .task {
                inviteesError = await session.refreshMeetingInvitees()
            }
            .task(id: bookingErrorRevision) {
                guard bookingErrorMessage != nil else { return }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                bookingErrorMessage = nil
            }
        }
    }

    private var bookingHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("ĐẶT PHÒNG")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.red)
                Text(room.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color(uiColor: .label))
                Text("\(room.capacity) chỗ · \(dayLabel)")
                    .font(.caption)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var meetingDetailsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Thông tin cuộc họp", systemImage: "text.bubble.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color(uiColor: .label))

            HStack(spacing: 10) {
                meetingTypeButton("Nội bộ", icon: "person.2.fill")
                meetingTypeButton("Tiếp khách", icon: "person.badge.plus")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Nội dung cuộc họp")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                TextField("Ví dụ: Họp kế hoạch tuần", text: $title)
                    .font(.body)
                    .padding(.horizontal, 13)
                    .frame(height: 48)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

            HStack(spacing: 10) {
                timeAction(
                    title: "Bắt đầu",
                    value: MeetingPresentation.clock.string(from: start),
                    icon: "clock.fill",
                    active: showStartPicker
                ) {
                    withAnimation(.snappy) { showStartPicker.toggle() }
                }

                timeAction(
                    title: "Thời lượng",
                    value: "\(durationValue) \(durationUnit)",
                    icon: "timer",
                    active: showDurationPicker
                ) {
                    withAnimation(.snappy) { showDurationPicker.toggle() }
                }
            }

            if showStartPicker {
                HStack(spacing: 0) {
                    pickerColumn("Giờ", selection: startHourBinding, values: Array(0...23))
                    pickerColumn("Phút", selection: startMinuteBinding, values: Array(0...59))
                }
                .frame(height: 138)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showDurationPicker {
                HStack(spacing: 0) {
                    pickerColumn("Số", selection: $durationValue, values: durationUnit == "giờ" ? Array(1...8) : [5, 10, 15, 20, 30, 45, 60, 90, 120])
                    Picker("Đơn vị", selection: $durationUnit) {
                        Text("phút").tag("phút")
                        Text("giờ").tag("giờ")
                    }
                    .pickerStyle(.wheel)
                    .onChange(of: durationUnit) { _, unit in
                        durationValue = unit == "giờ" ? 1 : 30
                    }
                }
                .frame(height: 138)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 9) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Color.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Thời gian dự kiến")
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                    Text("\(MeetingPresentation.clock.string(from: start)) – \(MeetingPresentation.clock.string(from: endTime))")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                }
                Spacer()
            }
            .padding(12)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .padding(16)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }

    private func meetingTypeButton(_ value: String, icon: String) -> some View {
        let selected = meetingType == value
        return Button {
            meetingType = value
        } label: {
            Label(value, systemImage: icon)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(selected ? .white : Color(uiColor: .label))
                .background(selected ? Color(red: 0.0, green: 0.42, blue: 0.25) : Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(selected ? Color.clear : Color(uiColor: .separator), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private var inviteesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Mời người tham gia", systemImage: "person.2.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("\(selected.count) người")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.10))
                    .clipShape(Capsule())
            }

            if !selectedInvitees.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Đã chọn")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                    ForEach(selectedInvitees) { person in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(Color.red.opacity(0.14))
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Text(person.fullName.prefix(1).uppercased())
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.red)
                                }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.fullName)
                                    .font(.subheadline.weight(.medium))
                                Text(person.department)
                                    .font(.caption)
                                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                            }
                            Spacer()
                            Button { selected.remove(person.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(11)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

            departmentSearchResults

            if !selectedDepartments.isEmpty, !unselectedDepartmentInvitees.isEmpty {
                Button {
                    selected.formUnion(unselectedDepartmentInvitees.map(\.id))
                } label: {
                    Label(
                        "Mời tất cả \(unselectedDepartmentInvitees.count) người thuộc \(selectedDepartments.count) phòng ban",
                        systemImage: "person.3.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                .tint(Color.red)
                .disabled(!canInviteEntireDepartment)

                if !canInviteEntireDepartment {
                    Text("Số người trong phòng ban vượt quá số chỗ còn lại của phòng họp.")
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
            }

            peopleSearchSection
            departmentSearchField

            if let inviteeLoadError = inviteesError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(inviteeLoadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Tải lại danh sách mời") {
                        Task { inviteesError = await session.refreshMeetingInvitees() }
                    }
                    .font(.caption.weight(.bold))
                }
            }

            if query.isEmpty && selectedDepartments.isEmpty {
                Text("Gõ tên nhân viên hoặc chọn phòng ban để hiển thị danh sách.")
                    .font(.caption)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }

            Text("\(selected.count + 1)/\(room.capacity) chỗ · gồm bạn và người được mời")
                .font(.caption)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
        }
        .padding(16)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }

    private var peopleSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Results stay in the card's layout, immediately above the active
            // field. The scroll position is then adjusted without animation,
            // so expanding this panel does not push the field toward the
            // keyboard or overlap another result row.
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !selectedDepartments.isEmpty {
                peopleSearchResults
            }

            searchField(
                icon: "magnifyingglass",
                placeholder: "Tìm tên hoặc mã nhân viên",
                text: $query,
                focus: .people
            )
        }
        .id("meeting-person-search")
    }

    private var peopleSearchResults: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !people.isEmpty {
                Text("Kết quả người tham gia")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(people) { person in
                            let isChosen = selected.contains(person.id)
                            Button {
                                if isChosen { selected.remove(person.id) }
                                else { selected.insert(person.id) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isChosen ? "checkmark.circle.fill" : "plus.circle")
                                        .foregroundStyle(isChosen ? Color.red : Color(uiColor: .secondaryLabel))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.fullName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text("\(person.employeeCode) · \(person.department)")
                                            .font(.caption)
                                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .frame(maxWidth: 220, alignment: .leading)
                                .background(isChosen ? Color.red.opacity(0.10) : Color(uiColor: .secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(!isChosen && selected.count + 1 >= room.capacity)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .frame(height: 62)
            } else {
                Text("Không tìm thấy người phù hợp.")
                    .font(.caption)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }

    private var departmentSearchResults: some View {
        Group {
            if !selectedDepartments.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Phòng ban đã chọn")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            Button("Bỏ chọn tất cả") {
                                selectedDepartments.removeAll()
                                query = ""
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(Capsule())
                            .buttonStyle(.plain)

                            ForEach(selectedDepartments.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { department in
                                Button {
                                    selectedDepartments.remove(department)
                                } label: {
                                    Text(department)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .foregroundStyle(.white)
                                        .background(Color.red)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                    .frame(height: 44)
                }
            }
        }
    }

    private var departmentSearchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !departmentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                departmentAutocompleteResults
            }

            searchField(
                icon: "building.2",
                placeholder: "Tìm phòng ban",
                text: $departmentQuery,
                focus: .departments
            )
        }
        .id("meeting-department-search")
    }

    private var departmentAutocompleteResults: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !matchingDepartments.isEmpty {
                Text("Kết quả phòng ban")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(matchingDepartments, id: \.self) { department in
                            let isSelected = selectedDepartments.contains(department)
                            Button {
                                if isSelected {
                                    selectedDepartments.remove(department)
                                } else {
                                    selectedDepartments.insert(department)
                                    query = ""
                                }
                            } label: {
                                Text(department)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .foregroundStyle(isSelected ? .white : Color(uiColor: .label))
                                    .background(isSelected ? Color.red : Color(uiColor: .secondarySystemBackground))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .frame(height: 48)
            } else {
                Text("Không tìm thấy phòng ban phù hợp.")
                    .font(.caption)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }

    private func timeAction(
        title: String,
        value: String,
        icon: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(Color.red)
                    Spacer()
                    Image(systemName: active ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                Text(value)
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color(uiColor: .label))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Color.red.opacity(0.10) : Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(active ? Color.red.opacity(0.35) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func pickerColumn(
        _ title: String,
        selection: Binding<Int>,
        values: [Int]
    ) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .padding(.top, 8)
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text(String(format: "%02d", value)).tag(value)
                }
            }
            .pickerStyle(.wheel)
        }
        .frame(maxWidth: .infinity)
    }

    private func searchField(
        icon: String,
        placeholder: String,
        text: Binding<String>,
        focus: InviteeSearchField
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
            TextField(placeholder, text: text)
                .font(.subheadline)
                .focused($focusedInviteeField, equals: focus)
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func keepFocusedInviteeFieldVisible(using proxy: ScrollViewProxy) {
        guard let focusedInviteeField else { return }
        let target = focusedInviteeField == .people
            ? "meeting-person-search"
            : "meeting-department-search"

        // Do not animate layout changes. This keeps the field's lower edge in
        // the keyboard-safe area while only the content above it is repositioned.
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    private var confirmButton: some View {
        Button {
            createBooking()
        } label: {
            HStack(spacing: 8) {
                if isSubmittingBooking {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(isSubmittingBooking ? "Đang đặt phòng..." : "Xác nhận đặt phòng")
                    .font(.headline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(.white)
            .background(canConfirmBooking ? Color.red : Color(uiColor: .systemGray3))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canConfirmBooking)
    }

    // Booking times are Vietnam times (AGENTS.md), whatever the device time zone.
    private var initialStartTime: Date {
        let now = Date()
        let time = MeetingPresentation.calendar.dateComponents([.hour, .minute], from: now)
        return MeetingPresentation.calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    private var startHourBinding: Binding<Int> {
        Binding(
            get: { MeetingPresentation.calendar.component(.hour, from: start) },
            set: { hour in
                start = MeetingPresentation.calendar.date(bySettingHour: hour, minute: MeetingPresentation.calendar.component(.minute, from: start), second: 0, of: start) ?? start
            }
        )
    }

    private var startMinuteBinding: Binding<Int> {
        Binding(
            get: { MeetingPresentation.calendar.component(.minute, from: start) },
            set: { minute in
                start = MeetingPresentation.calendar.date(bySettingHour: MeetingPresentation.calendar.component(.hour, from: start), minute: minute, second: 0, of: start) ?? start
            }
        )
    }

    private func createBooking() {
        guard canConfirmBooking else { return }
        isSubmittingBooking = true
        Task {
            let failureMessage = await session.createMeeting(
                room: room,
                title: bookingTitle,
                start: start,
                duration: durationMinutes,
                participants: Array(selected)
            )
            if let failureMessage {
                isSubmittingBooking = false
                bookingErrorMessage = failureMessage
                bookingErrorRevision += 1
            } else {
                dismiss()
            }
        }
    }
}

struct MeetingBookingErrorNotice: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.black.opacity(0.90), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
        .accessibilityLabel("Không thể đặt phòng: \(message)")
    }
}
