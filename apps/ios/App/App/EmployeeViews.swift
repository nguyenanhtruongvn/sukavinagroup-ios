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

private enum MeetingPresentation {
    static let timezone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    static var calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timezone
        return value
    }()
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.timeZone = timezone
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    static func time(_ value: String) -> String {
        guard let date = date(from: value) else {
            return String(value.split(separator: "T").last?.prefix(5) ?? "")
        }
        return clock.string(from: date)
    }

    static func range(_ booking: MeetingBooking) -> String {
        "\(time(booking.startsAt)) – \(time(booking.endsAt))"
    }
}

@available(iOS 17.0, *)
struct MeetingRoomsView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var day = Date()
    @State private var bookingRoom: MeetingRoom?
    @State private var scheduleRoom: MeetingRoom?
    @State private var showMine = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    MeetingRoomsHeader(day: $day, showMine: $showMine)
                    ForEach(session.meetingRooms) { room in
                        MeetingRoomCard(
                            room: room,
                            bookings: session.meetingBookings.filter { $0.roomId == room.id },
                            day: day,
                            onBook: { bookingRoom = room },
                            onSchedule: { scheduleRoom = room }
                        )
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await session.refreshMeetingSchedule(date: day)
            }
            .onChange(of: day) { _, date in
                Task { await session.refreshMeetingSchedule(date: date) }
            }
            .refreshable {
                await session.refreshMeetingSchedule(date: day)
            }
            .sheet(item: $bookingRoom) { room in
                MeetingBookingSheet(room: room, day: day)
                    .environmentObject(session)
            }
            .sheet(isPresented: $showMine) {
                MyMeetingsSheet()
                    .environmentObject(session)
            }
            .sheet(item: $scheduleRoom) { room in
                MeetingRoomScheduleSheet(room: room, day: day)
                    .environmentObject(session)
            }
        }
    }
}

@available(iOS 17.0, *)
private struct MeetingRoomsHeader: View {
    @Binding var day: Date
    @Binding var showMine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Phòng họp")
                .font(.largeTitle.bold())
            HStack(spacing: 9) {
                Button("Hôm nay") { day = .now }
                    .buttonStyle(.borderedProminent)
                Button("Ngày mai") {
                    day = MeetingPresentation.calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
                }
                .buttonStyle(.bordered)
                Spacer()
                DatePicker("", selection: $day, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Button { showMine = true } label: {
                    Image(systemName: "calendar.badge.clock")
                        .font(.headline)
                }
                .accessibilityLabel("Lịch của tôi")
            }
        }
    }
}

@available(iOS 17.0, *)
private struct MeetingRoomCard: View {
    let room: MeetingRoom
    let bookings: [MeetingBooking]
    let day: Date
    let onBook: () -> Void
    let onSchedule: () -> Void

    private var currentBooking: MeetingBooking? {
        let now = Date()
        guard MeetingPresentation.calendar.isDate(day, inSameDayAs: now) else { return nil }
        return bookings.first {
            guard let start = MeetingPresentation.date(from: $0.startsAt),
                  let end = MeetingPresentation.date(from: $0.endsAt) else { return false }
            return now >= start && now < end
        }
    }

    private var nextBooking: MeetingBooking? {
        let point = MeetingPresentation.calendar.isDate(day, inSameDayAs: .now) ? Date() : day
        return bookings.first {
            guard let start = MeetingPresentation.date(from: $0.startsAt) else { return false }
            return start > point
        }
    }

    private var isAvailable: Bool { currentBooking == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            MeetingRoomImage(room: room)
            VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.name).font(.headline)
                    Text("\(room.capacity) chỗ · \(room.equipment.joined(separator: " · "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(isAvailable ? "• Trống" : "• Đang họp")
                    .foregroundStyle(isAvailable ? .green : .red)
                    .font(.caption.bold())
            }
                Text(availabilityText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isAvailable ? .green : .red)
                if isAvailable {
                    Button("Đặt phòng", action: onBook)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                } else {
                    Button("Xem lịch", action: onSchedule)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(13)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: onSchedule)
    }

    private var availabilityText: String {
        if let currentBooking {
            return "Đang họp đến \(MeetingPresentation.time(currentBooking.endsAt))"
        }
        if let nextBooking {
            return "Trống đến \(MeetingPresentation.time(nextBooking.startsAt))"
        }
        return "Còn trống cả ngày"
    }
}

@available(iOS 17.0, *)
private struct MeetingRoomImage: View {
    let room: MeetingRoom

    var body: some View {
        Group {
            if let url = imageURL {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 92, height: 112)
        .background(Color.green.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var imageURL: URL? {
        let value = room.imageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/") {
            return URL(string: "https://sukavinagroup.net\(value)")
        }
        return URL(string: value)
    }

    private var placeholder: some View {
        Image(systemName: "building.2.fill")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@available(iOS 17.0, *)
private struct MeetingRoomScheduleSheet: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    let room: MeetingRoom
    let day: Date
    @State private var selectedDay: Date
    @State private var showBooking = false
    @State private var selectedBooking: MeetingBooking?

    init(room: MeetingRoom, day: Date) {
        self.room = room
        self.day = day
        _selectedDay = State(initialValue: day)
    }

    private var bookings: [MeetingBooking] {
        session.meetingBookings
            .filter { $0.roomId == room.id }
            .sorted { $0.startsAt < $1.startsAt }
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDay)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        DatePicker("Ngày", selection: $selectedDay, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .padding(.horizontal)
                            .padding(.bottom, 12)
                            .onChange(of: selectedDay) { _, value in
                                Task { await session.refreshMeetingSchedule(date: value) }
                            }
                        MeetingTimeline(bookings: bookings, date: selectedDay) { booking in
                            guard !booking.id.isEmpty else { return }
                            selectedBooking = booking
                        }
                    }
                }
                .task {
                    await session.refreshMeetingSchedule(date: selectedDay)
                    if isToday {
                        proxy.scrollTo(Calendar.current.component(.hour, from: Date()), anchor: .center)
                    }
                }
            }
            .navigationTitle(room.name)
            .toolbar {
                Button("Đóng") { dismiss() }
            }
            .overlay(alignment: .bottomTrailing) {
                Button { showBooking = true } label: {
                    Image(systemName: "plus")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Color.green)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }
                .padding(22)
            }
            .sheet(isPresented: $showBooking) {
                MeetingBookingSheet(room: room, day: selectedDay)
                    .environmentObject(session)
            }
            .sheet(item: $selectedBooking) { booking in
                MeetingBookingDetailSheet(booking: booking, room: room)
            }
        }
    }
}

@available(iOS 17.0, *)
private struct MeetingTimeline: View {
    let bookings: [MeetingBooking]
    let date: Date
    let onSelect: (MeetingBooking) -> Void
    private let firstHour = 6
    private let lastHour = 23
    private let hourHeight: CGFloat = 72

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(firstHour...lastHour), id: \.self) { hour in
                    Text(String(format: "%02d:00", hour))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: hourHeight, alignment: .topTrailing)
                        .padding(.trailing, 8)
                        .id(hour)
                }
            }
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(Array(firstHour...lastHour), id: \.self) { _ in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.07))
                            .frame(height: hourHeight - 1)
                        Divider()
                    }
                }
                ForEach(bookings) { booking in
                    if let position = bookingPosition(booking) {
                        MeetingTimelineBlock(booking: booking, color: bookingColor(booking))
                            .frame(height: position.height)
                        .offset(y: position.top)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(booking) }
                    }
                }
                if let currentOffset {
                    Rectangle()
                        .fill(.red)
                        .frame(height: 2)
                        .offset(y: currentOffset)
                    Text(MeetingPresentation.clock.string(from: Date()))
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.red)
                        .offset(y: currentOffset - 13)
                }
            }
            .frame(maxWidth: .infinity, minHeight: hourHeight * CGFloat(lastHour - firstHour + 1), alignment: .topLeading)
        }
    }

    private var currentOffset: CGFloat? {
        guard MeetingPresentation.calendar.isDateInToday(date) else { return nil }
        let now = Date()
        let hour = MeetingPresentation.calendar.component(.hour, from: now)
        guard hour >= firstHour && hour <= lastHour else { return nil }
        let minute = MeetingPresentation.calendar.component(.minute, from: now)
        return CGFloat(hour - firstHour) * hourHeight + CGFloat(minute) / 60 * hourHeight
    }

    private func bookingPosition(_ booking: MeetingBooking) -> (top: CGFloat, height: CGFloat)? {
        guard let start = MeetingPresentation.date(from: booking.startsAt),
              let end = MeetingPresentation.date(from: booking.endsAt) else { return nil }
        let startMinute = MeetingPresentation.calendar.component(.hour, from: start) * 60 + MeetingPresentation.calendar.component(.minute, from: start)
        let endMinute = MeetingPresentation.calendar.component(.hour, from: end) * 60 + MeetingPresentation.calendar.component(.minute, from: end)
        let visibleStart = max(startMinute, firstHour * 60)
        let visibleEnd = min(endMinute, (lastHour + 1) * 60)
        guard visibleEnd > visibleStart else { return nil }
        return (
            CGFloat(visibleStart - firstHour * 60) / 60 * hourHeight,
            max(CGFloat(visibleEnd - visibleStart) / 60 * hourHeight, 24)
        )
    }

    private func bookingColor(_ booking: MeetingBooking) -> Color {
        let palette: [Color] = [.red.opacity(0.23), .purple.opacity(0.24), .blue.opacity(0.24), .green.opacity(0.23), .orange.opacity(0.25)]
        return palette[abs(booking.id.hashValue) % palette.count]
    }
}

@available(iOS 17.0, *)
private struct MeetingTimelineBlock: View {
    let booking: MeetingBooking
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(booking.title.isEmpty ? "Đã có lịch" : booking.title)
                .font(.caption.bold())
                .lineLimit(1)
            Text(MeetingPresentation.range(booking))
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color)
    }
}

@available(iOS 17.0, *)
private struct MeetingBookingDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let booking: MeetingBooking
    let room: MeetingRoom

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("THÔNG TIN CUỘC HỌP", systemImage: "calendar.badge.clock")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                    Text(booking.title.isEmpty ? "Cuộc họp đã được đặt" : booking.title)
                        .font(.title2.weight(.bold))
                    detail("Thời gian", MeetingPresentation.range(booking), "clock.fill")
                    detail("Phòng họp", room.name, "building.2.fill")
                    if !room.location.isEmpty { detail("Vị trí", room.location, "mappin.and.ellipse") }
                    detail("Số người tham dự", "\(booking.attendeeCount) người", "person.2.fill")
                    if !room.equipment.isEmpty { detail("Thiết bị", room.equipment.joined(separator: " · "), "tv.fill") }
                    Text(booking.isOwner == true ? "Bạn là người đặt phòng" : "Bạn được mời tham gia")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Chi tiết lịch họp")
            .toolbar { Button("Đóng") { dismiss() } }
        }
    }

    private func detail(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.red).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.semibold))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

@available(iOS 17.0, *)
private struct MeetingBookingSheet: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    let room: MeetingRoom
    let day: Date

    @State private var title = ""
    @State private var start = Date()
    @State private var durationValue = 30
    @State private var durationUnit = "phút"
    @State private var query = ""
    @State private var departmentQuery = ""
    @State private var selectedDepartment: String?
    @State private var selected = Set<String>()
    @State private var inviteesError: String?
    @State private var showStartPicker = false
    @State private var showDurationPicker = false

    private var people: [MeetingInvitee] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty || selectedDepartment != nil else { return [] }
        return session.meetingInvitees.filter {
            (selectedDepartment == nil || $0.department.caseInsensitiveCompare(selectedDepartment!) == .orderedSame)
                && (trimmedQuery.isEmpty
                    || $0.fullName.localizedCaseInsensitiveContains(trimmedQuery)
                    || $0.employeeCode.localizedCaseInsensitiveContains(trimmedQuery))
        }
    }

    private var departments: [String] {
        Array(Set(session.meetingInvitees.map(\.department)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var selectedInvitees: [MeetingInvitee] {
        session.meetingInvitees.filter { selected.contains($0.id) }
    }

    private var durationMinutes: Int {
        durationUnit == "giờ" ? durationValue * 60 : durationValue
    }

    var body: some View {
        NavigationStack {
            Form {
                meetingDetailsSection
                inviteesSection
                Section {
                    Button("Xác nhận đặt phòng") { createBooking() }
                        .disabled(title.count < 3 || selected.count + 1 > room.capacity)
                }
            }
            .navigationTitle(room.name)
            .toolbar {
                Button("Đóng") { dismiss() }
            }
            .onAppear { start = initialStartTime }
            .task {
                inviteesError = await session.refreshMeetingInvitees()
            }
        }
    }

    private var meetingDetailsSection: some View {
        Section("Cuộc họp") {
            TextField("Nội dung cuộc họp", text: $title)
            Button { showStartPicker.toggle() } label: {
                LabeledContent("Giờ bắt đầu", value: MeetingPresentation.clock.string(from: start))
            }
            if showStartPicker {
                HStack {
                    Picker("Giờ", selection: startHourBinding) {
                        ForEach(0...23, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .pickerStyle(.wheel)
                    Picker("Phút", selection: startMinuteBinding) {
                        ForEach(0...59, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .pickerStyle(.wheel)
                }
                .frame(height: 130)
            }
            Button { showDurationPicker.toggle() } label: {
                LabeledContent("Thời lượng", value: "\(durationValue) \(durationUnit)")
            }
            if showDurationPicker {
                HStack {
                    Picker("Số", selection: $durationValue) {
                        ForEach(durationUnit == "giờ" ? Array(1...8) : [5, 10, 15, 20, 30, 45, 60, 90, 120], id: \.self) {
                            Text("\($0)").tag($0)
                        }
                    }
                    .pickerStyle(.wheel)
                    Picker("Đơn vị", selection: $durationUnit) {
                        Text("phút").tag("phút")
                        Text("giờ").tag("giờ")
                    }
                    .pickerStyle(.wheel)
                    .onChange(of: durationUnit) { _, unit in
                        durationValue = unit == "giờ" ? 1 : 30
                    }
                }
                .frame(height: 130)
            }
            Text("Thời gian dự kiến: \(MeetingPresentation.clock.string(from: start)) – \(MeetingPresentation.clock.string(from: start.addingTimeInterval(Double(durationMinutes * 60))))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var inviteesSection: some View {
        Section("Mời người tham gia (\(selected.count))") {
            if !selectedInvitees.isEmpty {
                Text("Đã mời")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(selectedInvitees) { person in
                    HStack {
                        Text(person.fullName)
                        Spacer()
                        Button(role: .destructive) { selected.remove(person.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                }
            }
            TextField("Tìm nhân viên hoặc phòng ban", text: $query)
            TextField("Tìm phòng ban", text: $departmentQuery)
            if !departments.isEmpty {
                Picker("Phòng ban", selection: $selectedDepartment) {
                    Text("Tất cả").tag(String?.none)
                    ForEach(departments.filter {
                        departmentQuery.isEmpty || $0.localizedCaseInsensitiveContains(departmentQuery)
                    }, id: \.self) { department in
                        Text(department).tag(Optional(department))
                    }
                }
            }
            if let inviteeLoadError = inviteesError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(inviteeLoadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Tải lại danh sách mời") {
                        Task { inviteesError = await session.refreshMeetingInvitees() }
                    }
                    .font(.caption.bold())
                }
            }
            ForEach(people) { person in
                Toggle(isOn: inviteeBinding(for: person.id)) {
                    VStack(alignment: .leading) {
                        Text(person.fullName)
                        Text(person.department).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var initialStartTime: Date {
        let now = Date()
        let time = Calendar.current.dateComponents([.hour, .minute], from: now)
        return Calendar.current.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    private var startHourBinding: Binding<Int> {
        Binding(
            get: { Calendar.current.component(.hour, from: start) },
            set: { hour in
                start = Calendar.current.date(bySettingHour: hour, minute: Calendar.current.component(.minute, from: start), second: 0, of: start) ?? start
            }
        )
    }

    private var startMinuteBinding: Binding<Int> {
        Binding(
            get: { Calendar.current.component(.minute, from: start) },
            set: { minute in
                start = Calendar.current.date(bySettingHour: Calendar.current.component(.hour, from: start), minute: minute, second: 0, of: start) ?? start
            }
        )
    }

    private func inviteeBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isSelected in
                if isSelected { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func createBooking() {
        Task {
            let didCreate = await session.createMeeting(
                room: room,
                title: title,
                start: start,
                duration: durationMinutes,
                participants: Array(selected)
            )
            if didCreate { dismiss() }
        }
    }
}

@available(iOS 17.0, *)
private struct MyMeetingsSheet: View {
    @EnvironmentObject private var session: SessionStore
    @State private var showsUpcoming = true

    private var meetings: [MeetingBooking] {
        session.meetingBookings
            .filter { $0.isMine ?? false }
            .filter { meeting in
                guard let end = MeetingPresentation.date(from: meeting.endsAt) else { return showsUpcoming }
                return showsUpcoming ? end >= Date() : end < Date()
            }
            .sorted { $0.startsAt < $1.startsAt }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Trạng thái lịch", selection: $showsUpcoming) {
                    Text("Sắp tới").tag(true)
                    Text("Đã qua").tag(false)
                }
                .pickerStyle(.segmented)
                .padding()
                List(meetings) { meeting in
                    VStack(alignment: .leading) {
                        Text(meeting.title.isEmpty ? "Cuộc họp" : meeting.title)
                            .font(.headline)
                        Text(session.meetingRooms.first(where: { $0.id == meeting.roomId })?.name ?? "Phòng họp")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(MeetingPresentation.range(meeting))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Lịch của tôi")
        }
    }
}








@available(iOS 17.0, *)
struct EmployeePortalView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var requestInitialFilter: EmployeeRequestStatus?








    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView {
                requestInitialFilter = .pending
                selectedTab = 1
            }
                .adaptivePortalTabBarBackground()
                .tabItem { Label("Trang chủ", systemImage: "house.fill") }
                .tag(0)
            RequestsView(initialFilter: requestInitialFilter)
                .adaptivePortalTabBarBackground()
                .tabItem { Label("Đơn từ", systemImage: "doc.text.fill") }
            .tag(1)
            MeetingRoomsView()
                .adaptivePortalTabBarBackground()
                .tabItem { Label("Phòng họp", systemImage: "building.2.fill") }
                .tag(2)
            NotificationsView()
                .adaptivePortalTabBarBackground()
                .tabItem { Label("Thông báo", systemImage: "bell.fill") }
                .badge(session.unreadCount + session.requestUnreadCount)
                .tag(3)
            ProfileView()
                .adaptivePortalTabBarBackground()
                .tabItem { Label("Tài khoản", systemImage: "person.crop.circle.fill") }
                .tag(4)
        }
        .accentColor(AppTheme.red)
        .adaptivePortalTabBarBackground()
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
                    if let day = selectedDay(in: data, month: month) {
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
        return HStack(spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                summary(item.1, item.0, item.2)
            }
        }
        .frame(maxWidth: .infinity)
    }








    private func preloadedCalendarCard(_ data: AttendanceMonth, month: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lịch chấm công").font(.headline).foregroundStyle(Color.primary)
            HStack(spacing: 4) {
                ForEach(["T2", "T3", "T4", "T5", "T6", "T7", "CN"], id: \.self) {
                    Text($0).font(.caption.bold()).foregroundStyle(AppTheme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 7) {
                ForEach(0..<preloadedLeadingEmptyDays(data), id: \.self) { _ in
                    Color.clear.frame(height: 50)
                }
                ForEach(data.days) { day in
                    let selected = selectedDay(in: data, month: month)?.date == day.date
                    Button {
                        selectedDates[month] = day.date
                    } label: {
                        Text(String(Int(day.date.suffix(2)) ?? 0))
                            .font(.subheadline.weight(selected ? .bold : .medium))
                            .foregroundStyle(dayStatuses(day).contains("absent") ? Self.absentColor : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 50)
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
        VStack(spacing: 5) {
            Text("\(value)").font(.title3.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(AppTheme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 13)
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
