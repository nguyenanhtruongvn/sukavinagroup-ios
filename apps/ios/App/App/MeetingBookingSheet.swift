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
    @State private var durationMinutes = 30
    @State private var query = ""
    @State private var departmentQuery = ""
    @State private var selectedDepartments = Set<String>()
    @State private var selected = Set<String>()
    @State private var inviteesError: String?
    @State private var isSubmittingBooking = false
    @State private var bookingErrorMessage: String?
    @State private var confirmingDiscard = false
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

    /// Why "Xác nhận đặt phòng" is disabled (past start, over capacity).
    private var blockReason: String? {
        MeetingBookingTime.blockReason(
            start: start, now: Date(), attendeeCount: selected.count + 1,
            capacity: room.capacity, calendar: MeetingPresentation.calendar
        )
    }

    private var isValid: Bool {
        blockReason == nil
    }

    /// A typed title or chosen invitees would be lost by closing.
    private var hasUnsavedInput: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selected.isEmpty
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
                    // Adding people grows the list above the search field and
                    // pushes it down, so follow it. Removing someone (the x in
                    // "Đã chọn") only shrinks that list: the user is working
                    // there, and jumping back to the search field was jarring.
                    .onChange(of: selected) { old, new in
                        guard new.count > old.count else { return }
                        keepFocusedInviteeFieldVisible(using: proxy)
                    }
                    .onChange(of: selectedDepartments) { old, new in
                        guard new.count > old.count else { return }
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
                    Button("Đóng") {
                        if hasUnsavedInput { confirmingDiscard = true } else { dismiss() }
                    }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .interactiveDismissDisabled(hasUnsavedInput || isSubmittingBooking)
            .confirmationDialog("Bỏ lịch đang đặt?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Bỏ lịch", role: .destructive) { dismiss() }
                Button("Tiếp tục đặt", role: .cancel) {}
            } message: {
                Text("Tiêu đề và người được mời bạn đã chọn sẽ không được lưu.")
            }
            .onAppear { start = initialStartTime }
            .task {
                inviteesError = await session.refreshMeetingInvitees()
            }
            // Apple's alert, which stays until it is read and dismissed
            // (it was a dark notice drawn at the top that hid itself after
            // five seconds).
            .alert(
                "Không thể đặt phòng",
                isPresented: Binding(
                    get: { bookingErrorMessage != nil },
                    set: { if !$0 { bookingErrorMessage = nil } }
                )
            ) {
                Button("Đã hiểu", role: .cancel) { bookingErrorMessage = nil }
            } message: {
                Text(bookingErrorMessage ?? "")
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

            Picker("Loại cuộc họp", selection: $meetingType) {
                Text("Nội bộ").tag("Nội bộ")
                Text("Tiếp khách").tag("Tiếp khách")
            }
            .pickerStyle(.segmented)

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

            // The two facts of a booking as tiles: when it starts (hh:mm) and
            // how long it lasts. Each tile is wholly a button opening Apple's
            // popover with Apple's time wheels (DatePopoverButton); from one
            // popover, a tap on the other tile opens that one at once.
            HStack(spacing: 10) {
                bookingTile(
                    title: "Bắt đầu",
                    value: MeetingPresentation.clock.string(from: start),
                    icon: "clock.fill"
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .overlay(DatePopoverButton(
                    selection: $start,
                    minuteInterval: MeetingBookingTime.minuteStep,
                    accessibilityLabel: "Bắt đầu",
                    accessibilityValue: MeetingPresentation.clock.string(from: start)
                ))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                // Hours and minutes of the wheels are the length: 01:30 is
                // 1 giờ 30 phút; 5-minute steps, 00:05 to 08:00.
                bookingTile(
                    title: "Thời lượng",
                    value: DurationClock.title(minutes: durationMinutes),
                    icon: "timer"
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .overlay(DatePopoverButton(
                    selection: durationClock,
                    minuteInterval: MeetingBookingTime.minuteStep,
                    minimum: DurationClock.date(
                        forMinutes: MeetingBookingTime.durationRange.lowerBound,
                        calendar: VietnamTime.calendar
                    ),
                    maximum: DurationClock.date(
                        forMinutes: MeetingBookingTime.durationRange.upperBound,
                        calendar: VietnamTime.calendar
                    ),
                    accessibilityLabel: "Thời lượng",
                    accessibilityValue: DurationClock.title(minutes: durationMinutes)
                ))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .stroke(AppTheme.cardBorder, lineWidth: 1)
        }
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
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Bỏ mời \(person.fullName)")
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
                // Allow selecting the full department. If it exceeds capacity,
                // the shared blockReason appears beside Xác nhận đặt phòng,
                // in the same place as the past-start warning.
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

        }
        .padding(16)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.cardBorder, lineWidth: 1)
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
                            // Selecting one extra invitee must surface the
                            // capacity warning beside Xác nhận đặt phòng,
                            // rather than silently disabling this result.
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

    /// `durationMinutes` as the time Apple's time picker shows ("01:30").
    private var durationClock: Binding<Date> {
        Binding(
            get: { DurationClock.date(forMinutes: durationMinutes, calendar: VietnamTime.calendar) },
            set: { durationMinutes = DurationClock.minutes(from: $0, step: MeetingBookingTime.minuteStep, range: MeetingBookingTime.durationRange, calendar: VietnamTime.calendar) }
        )
    }

    /// A start or duration tile: icon and chevron, caption, value. Drawn
    /// only; the picker under it does the choosing.
    private func bookingTile(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(Color.red)
                Spacer()
                Image(systemName: "chevron.down")
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
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        VStack(spacing: 8) {
            if let blockReason, !isSubmittingBooking {
                Label(blockReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    // Neutral surface and outline match the surrounding
                    // frosted confirmation card; only the warning glyph and
                    // text are red.
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color(uiColor: .separator).opacity(0.40), lineWidth: 0.75)
                    }
            }
            confirmActionButton
        }
    }

    private var confirmActionButton: some View {
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
        }
        // Apple's prominent button (it was a drawn red rectangle); disabled,
        // the system greys it.
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .controlSize(.large)
        .tint(.red)
        .disabled(!canConfirmBooking)
    }

    // Booking times are Vietnam times (AGENTS.md), whatever the device time zone.
    private var initialStartTime: Date {
        MeetingBookingTime.defaultStart(on: day, now: Date(), calendar: MeetingPresentation.calendar)
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
            } else {
                dismiss()
            }
        }
    }
}
