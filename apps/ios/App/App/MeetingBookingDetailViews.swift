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

struct MeetingBookingDetailSheet: View {
    // Only calls session methods: must not redraw on every session change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @EnvironmentObject private var meetingStore: MeetingStore
    @Environment(\.dismiss) private var dismiss
    let booking: MeetingBooking
    let room: MeetingRoom
    @State private var details: MeetingBookingDetails?
    @State private var isCancelling = false
    @State private var showCancelConfirmation = false
    @State private var cancelError: String?

    // Role color is shared with Android: organiser green, invitee/limited blue.
    private var isLimitedViewer: Bool { details?.isLimitedViewer == true }
    private var accent: Color { booking.isOwner == true ? Color(red: 0.13, green: 0.71, blue: 0.45) : .blue }
    private var roleTitle: String {
        if isLimitedViewer { return "Thông tin giới hạn dành cho Phòng Nhân sự" }
        return booking.isOwner == true ? "Bạn là người tổ chức" : "Bạn được mời tham dự"
    }
    private var roleIcon: String {
        isLimitedViewer ? "lock.shield.fill" : booking.isOwner == true ? "person.badge.key.fill" : "person.2.badge.gearshape.fill"
    }

    // Read the live schedule copy first so an end/extension redraws this sheet
    // immediately after the mutation endpoint responds.
    private var currentBooking: MeetingBooking {
        meetingStore.bookings.first(where: { $0.id == booking.id }) ?? booking
    }
    private var startDate: Date? { currentBooking.startDate }
    private var endDate: Date? { currentBooking.endDate }

    private var dateTitle: String {
        guard let start = startDate else { return "Chưa xác định" }
        return VietnamTime.weekdayLongDate.string(from: start).capitalized
    }
    private var durationTitle: String {
        guard let start = startDate, let end = endDate else { return "—" }
        return DurationClock.title(minutes: max(0, Int(end.timeIntervalSince(start) / 60)))
    }
    private var displayedRoom: MeetingRoom { details?.room ?? room }
    /// The organiser of a confirmed booking can cancel it before it starts
    /// and control it (end, extend) once it has started.
    private var isOrganizerOfLiveBooking: Bool {
        booking.isOwner == true && currentBooking.status == "confirmed"
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(alignment: .top) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.title2.bold()).foregroundStyle(.white)
                                .frame(width: 54, height: 54).background(accent.gradient)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            Spacer()
                            Label(currentBooking.status == "confirmed" ? "Đã xác nhận" : currentBooking.status, systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.bold)).foregroundStyle(accent)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(accent.opacity(0.12)).clipShape(Capsule())
                        }
                        Text(currentBooking.title.isEmpty ? "Cuộc họp" : currentBooking.title)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                        Label(roleTitle, systemImage: roleIcon)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [accent.opacity(0.18), Color(uiColor: .secondarySystemBackground)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                    detailCard(title: "Thời gian", icon: "clock.fill") {
                        Text(MeetingPresentation.range(currentBooking)).font(.title3.weight(.bold).monospacedDigit())
                        Text(dateTitle).font(.subheadline).foregroundStyle(.secondary)
                        if !isLimitedViewer {
                            HStack(spacing: 8) {
                                detailPill(durationTitle, icon: "timer")
                                detailPill("\(currentBooking.attendeeCount) người", icon: "person.2.fill")
                            }
                        }
                    }
                    if !isLimitedViewer {
                        detailCard(title: "Địa điểm", icon: "building.2.fill") {
                            Text(displayedRoom.name).font(.headline)
                            if !displayedRoom.location.isEmpty { Label(displayedRoom.location, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(.secondary) }
                            Text("Sức chứa phòng: \(displayedRoom.capacity) người").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                        if !displayedRoom.equipment.isEmpty {
                            detailCard(title: "Thiết bị sẵn có", icon: "display.2") {
                                Text(displayedRoom.equipment.joined(separator: "  ·  ")).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let details {
                        if isLimitedViewer {
                            detailCard(title: "Thông tin cuộc họp", icon: "lock.shield.fill") {
                                Label("Loại cuộc họp: \(details.title)", systemImage: "tag.fill")
                                    .font(.headline)
                                Label("Người tổ chức: \(details.employee.fullName)", systemImage: "person.crop.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                        } else {
                            detailCard(title: "Người tổ chức", icon: "person.crop.circle.fill") {
                                Text(details.employee.fullName).font(.headline)
                                Text([details.employee.employeeCode, details.employee.department, details.employee.jobTitle]
                                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                                    .joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            detailCard(title: "Người tham gia (\(details.participants.count))", icon: "person.2.fill") {
                                if details.participants.isEmpty {
                                    Text("Chưa có người được mời thêm.").font(.subheadline).foregroundStyle(.secondary)
                                } else {
                                    ForEach(details.participants) { participant in
                                        Text(participant.employee.fullName)
                                            .font(.subheadline.weight(.medium))
                                    }
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Đang tải thông tin người tham gia…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if isOrganizerOfLiveBooking, let startDate {
                        // "Hủy lịch" gives way to the meeting controls at the
                        // start time, also while this sheet stays open.
                        TimelineView(.explicit([startDate])) { clock in
                            if startDate <= max(clock.date, Date()) {
                                MeetingControlCard(
                                    bookingID: currentBooking.id,
                                    roomId: currentBooking.roomId,
                                    roomName: displayedRoom.name,
                                    endDate: endDate
                                )
                            } else {
                                Button(role: .destructive) {
                                    showCancelConfirmation = true
                                } label: {
                                    Label(isCancelling ? "Đang hủy lịch…" : "Hủy lịch", systemImage: "calendar.badge.minus")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                }
                                .disabled(isCancelling)
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }
                    }
                    Text("Thông tin được đồng bộ theo thời gian thực.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Chi tiết cuộc họp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Đóng") { dismiss() } }
            .task(id: booking.id) {
                if let cached = session.cachedMeetingBookingDetails(id: booking.id) {
                    details = cached
                }
                if let loaded = await session.meetingBookingDetails(id: booking.id) {
                    details = loaded
                }
            }
            .alert("Hủy lịch họp?", isPresented: $showCancelConfirmation) {
                Button("Không", role: .cancel) {}
                Button("Hủy lịch", role: .destructive) {
                    Task {
                        isCancelling = true
                        let error = await session.cancelMeeting(id: booking.id, scheduledAt: booking.startsAt)
                        isCancelling = false
                        if let error { cancelError = error } else { dismiss() }
                    }
                }
            } message: {
                Text("Những người được mời sẽ nhận được thông báo lịch họp đã hủy.")
            }
            .alert("Chưa thể hủy lịch", isPresented: Binding(
                get: { cancelError != nil },
                set: { if !$0 { cancelError = nil } }
            )) {
                Button("Đã hiểu", role: .cancel) {}
            } message: {
                Text(cancelError ?? "")
            }
        }
    }

    private func detailCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon).font(.subheadline.weight(.bold)).foregroundStyle(accent)
            content()
        }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func detailPill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(accent)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(accent.opacity(0.12)).clipShape(Capsule())
    }
}

/// The organiser's controls for a meeting in progress: extend it in 5-minute
/// steps up to `MeetingExtension`'s limit, or end it now. Shared by the
/// booking detail and the meeting notification (the iOS 17 UIKit detail uses
/// the same `MeetingExtension` rules). Turns into "đã kết thúc" by itself at
/// the end time.
struct MeetingControlCard: View {
    // Only calls session methods: must not redraw on every session change.
    @Environment(\.sessionActions) private var sessionActions
    @EnvironmentObject private var meetingStore: MeetingStore
    let bookingID: String
    let roomId: String
    let roomName: String
    let endDate: Date?
    @State private var extensionMinutes = MeetingExtension.step
    @State private var submittingAction: String?
    @State private var confirmingEnd = false
    @State private var actionError: String?

    private var isSubmitting: Bool { submittingAction != nil }
    private var nextBooking: MeetingBooking? {
        guard let endDate else { return nil }
        return meetingStore.nextBooking(after: endDate, inRoom: roomId, excluding: bookingID)
    }
    private var maximumExtensionMinutes: Int {
        guard let endDate else { return 0 }
        return MeetingExtension.maximumMinutes(end: endDate, nextStart: nextBooking?.startDate)
    }
    private var extensionBlockMessage: String {
        guard let nextBooking else {
            return "Không thể gia hạn vì lịch phòng đang được cập nhật."
        }
        let title = nextBooking.title.isEmpty ? "cuộc họp tiếp theo" : "“\(nextBooking.title)”"
        return "Không thể gia hạn vì \(roomName) có \(title) lúc \(MeetingPresentation.time(nextBooking.startsAt))."
    }

    var body: some View {
        // Redraw exactly when the meeting ends, not every minute. AnyView
        // keeps the type shallow: on iOS 17 this card sits in the SwiftUI
        // notification detail, and iOS 17 SwiftUI aborted building deep
        // meeting view types (see LegacyMeetingRoomsUIKitView).
        TimelineView(.explicit(endDate.map { [$0] } ?? [])) { clock in
            AnyView(card(ended: endDate.map { $0 <= max(clock.date, Date()) } ?? false))
        }
    }

    private func card(ended: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                ended ? "Cuộc họp đã kết thúc" : "Điều khiển cuộc họp",
                systemImage: ended ? "checkmark.circle.fill" : "slider.horizontal.3"
            )
            .font(.headline.weight(.bold))
            .foregroundStyle(AppTheme.text(.green))

            if ended {
                Text("Cuộc họp đã kết thúc. Bạn không thể gia hạn hoặc kết thúc lại.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                if let actionError {
                    Text(actionError)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if maximumExtensionMinutes >= MeetingExtension.step {
                    Stepper(
                        value: $extensionMinutes,
                        in: MeetingExtension.step...maximumExtensionMinutes,
                        step: MeetingExtension.step
                    ) {
                        Text("Gia hạn thêm \(min(extensionMinutes, maximumExtensionMinutes)) phút")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppTheme.text(.green))
                    }
                    .disabled(isSubmitting)
                    .onChange(of: extensionMinutes) { _, _ in actionError = nil }

                    Button {
                        Task { await submit("extend") }
                    } label: {
                        HStack(spacing: 8) {
                            if submittingAction == "extend" {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark")
                            }
                            Text(submittingAction == "extend" ? "Đang gia hạn…" : "Xác nhận gia hạn")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isSubmitting)
                } else {
                    // Kept visible, disabled, so the organiser sees why.
                    Button {} label: {
                        Label("Gia hạn không khả dụng", systemImage: "clock.badge.exclamationmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)

                    Text(extensionBlockMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }

                Button(role: .destructive) {
                    // Irreversible: ask first.
                    confirmingEnd = true
                } label: {
                    HStack(spacing: 8) {
                        if submittingAction == "end" {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "stop.fill")
                        }
                        Text(submittingAction == "end" ? "Đang kết thúc…" : "Kết thúc cuộc họp")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
                .confirmationDialog("Kết thúc cuộc họp?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                    Button("Kết thúc", role: .destructive) { Task { await submit("end") } }
                    Button("Tiếp tục họp", role: .cancel) {}
                } message: {
                    Text("Phòng sẽ được giải phóng ngay để người khác có thể đặt. Không thể hoàn tác.")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @MainActor
    private func submit(_ action: String) async {
        guard !isSubmitting else { return }
        submittingAction = action
        actionError = nil
        // A booking added meanwhile can lower the limit below the chosen value.
        let minutes = min(extensionMinutes, maximumExtensionMinutes)
        actionError = await sessionActions.store.performMeetingControl(
            bookingID: bookingID,
            action: action,
            extensionMinutes: minutes
        )
        if actionError == nil {
            extensionMinutes = MeetingExtension.step
        }
        submittingAction = nil
    }
}

struct MyMeetingsSheet: View {
    // Only calls session methods: must not redraw on every session change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @EnvironmentObject private var meetingStore: MeetingStore
    @Environment(\.dismiss) private var dismiss
    let day: Date
    @State private var showsUpcoming = true
    @State private var selectedMeeting: MeetingBooking?

    private var myBookings: [MeetingBooking] {
        meetingStore.bookings.filter { $0.isMine ?? false }
    }

    /// The meetings of the chosen tab at `now` (bookings are already sorted).
    private func meetings(at now: Date) -> [MeetingBooking] {
        myBookings.filter { meeting in
            guard let end = meeting.endDate else { return showsUpcoming }
            return showsUpcoming ? end >= now : end < now
        }
    }

    private var dateLabel: String {
        return VietnamTime.weekdayLongDayMonth.string(from: day).capitalized
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    // A meeting moves from "Sắp tới" to "Đã qua" when it
                    // ends: redraw exactly then.
                    TimelineView(.explicit(myBookings.compactMap(\.endDate))) { clock in
                        let shown = meetings(at: max(clock.date, Date()))
                        VStack(alignment: .leading, spacing: 18) {
                            header(count: shown.count)
                            scheduleFilter

                            if shown.isEmpty {
                                emptyState
                            } else {
                                LazyVStack(spacing: 12) {
                                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, meeting in
                                        Button { selectedMeeting = meeting } label: {
                                            MeetingSummaryCard(
                                                meeting: meeting,
                                                roomName: meetingStore.rooms.first(where: { $0.id == meeting.roomId })?.name ?? "Phòng họp",
                                                color: showsUpcoming ? Self.cardColors[index % Self.cardColors.count] : .gray
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Xem chi tiết cuộc họp \(meeting.title)")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 34)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height), abs(value.translation.width) > 48 else { return }
                            withAnimation(.snappy) { showsUpcoming = value.translation.width > 0 }
                        }
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        if #available(iOS 26.0, *) {
                            // iOS 26 draws every toolbar button as one round
                            // Liquid Glass control; a circle of our own showed
                            // up as a second layer inside it.
                            Image(systemName: "xmark")
                                .font(.subheadline.weight(.bold))
                        } else {
                            // Earlier toolbars have no button background.
                            Image(systemName: "xmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color(uiColor: .label))
                                .frame(width: 34, height: 34)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                    }
                    .accessibilityLabel("Đóng lịch của tôi")
                }
            }
            .task { await session.refreshMeetingSchedule(date: day) }
            .sheet(item: $selectedMeeting) { meeting in
                if let room = meetingStore.rooms.first(where: { $0.id == meeting.roomId }) {
                    MeetingBookingDetailSheet(booking: meeting, room: room)
                } else {
                    ContentUnavailableView("Không tìm thấy thông tin phòng", systemImage: "building.2.crop.circle")
                }
            }
        }
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lịch của tôi")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                    Text(dateLabel)
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
                Spacer(minLength: 12)
                VStack(spacing: 1) {
                    Text("\(count)")
                        .font(.title3.weight(.bold).monospacedDigit())
                    Text(showsUpcoming ? "sắp tới" : "đã qua")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Color.red)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(Color.red)
                Text("Lịch họp được đồng bộ theo thời gian thực")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var scheduleFilter: some View {
        Picker("Trạng thái lịch", selection: $showsUpcoming) {
            Text("Sắp tới").tag(true)
            Text("Đã qua").tag(false)
        }
        .pickerStyle(.segmented)
        .padding(4)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(showsUpcoming ? "Chưa có lịch sắp tới" : "Chưa có lịch đã qua", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text(showsUpcoming ? "Các cuộc họp bạn tạo hoặc được mời sẽ xuất hiện tại đây." : "Các cuộc họp đã kết thúc sẽ được lưu tại đây.")
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .padding(20)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private static let cardColors: [Color] = [.red, .blue, .green, .orange, .purple, .teal]
}

struct MeetingSummaryCard: View {
    let meeting: MeetingBooking
    let roomName: String
    let color: Color

    var body: some View {
        HStack(spacing: 13) {
            VStack(spacing: 3) {
                Text(MeetingPresentation.time(meeting.startsAt))
                    .font(.headline.weight(.bold).monospacedDigit())
                Text(MeetingPresentation.time(meeting.endsAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            .frame(width: 54)

            Rectangle()
                .fill(color)
                .frame(width: 4)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 5) {
                Text(meeting.title.isEmpty ? "Cuộc họp" : meeting.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(2)
                Label(roomName, systemImage: "building.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
                Text(meeting.isOwner == true ? "Bạn tạo lịch" : "Bạn được mời")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .padding(14)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(color.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: color.opacity(0.08), radius: 8, y: 3)
    }
}
