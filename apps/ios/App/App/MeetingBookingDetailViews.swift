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
    @State private var extensionMinutes = 5
    @State private var isSubmittingControl = false
    @State private var confirmingEnd = false
    @State private var controlAction: String?
    @State private var controlError: String?

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
    private var meetingStarted: Bool { startDate.map { $0 <= Date() } ?? false }
    private var meetingEnded: Bool { endDate.map { $0 <= Date() } ?? false }

    private var dateTitle: String {
        guard let start = startDate else { return "Chưa xác định" }
        return VietnamTime.weekdayLongDate.string(from: start).capitalized
    }
    private var durationTitle: String {
        guard let start = startDate, let end = endDate else { return "—" }
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        return minutes >= 60 ? "\(minutes / 60) giờ\(minutes % 60 == 0 ? "" : " \(minutes % 60) phút")" : "\(minutes) phút"
    }
    private var displayedRoom: MeetingRoom { details?.room ?? room }
    private var canCancel: Bool {
        guard booking.isOwner == true,
              currentBooking.status == "confirmed",
              let start = startDate else { return false }
        return start > Date()
    }
    private var canShowMeetingControls: Bool {
        booking.isOwner == true &&
            currentBooking.status == "confirmed" &&
            meetingStarted
    }
    private var nextBooking: MeetingBooking? {
        guard let endDate else { return nil }
        return meetingStore.bookings
            .filter { $0.roomId == currentBooking.roomId && $0.id != currentBooking.id }
            .filter { candidate in
                guard let start = candidate.startDate else { return false }
                return start > endDate
            }
            .sorted { left, right in
                (left.startDate ?? .distantFuture)
                    < (right.startDate ?? .distantFuture)
            }
            .first
    }
    private var maximumExtensionMinutes: Int {
        guard let endDate else { return 0 }
        guard let nextStart = nextBooking.flatMap({ $0.startDate }) else {
            return 120
        }
        return min(120, max(0, Int(nextStart.timeIntervalSince(endDate) / 60) - 5))
    }
    private var extensionBlockMessage: String {
        guard let nextBooking else {
            return "Không thể gia hạn vì lịch phòng đang được cập nhật."
        }
        let title = nextBooking.title.isEmpty ? "cuộc họp tiếp theo" : "“\(nextBooking.title)”"
        return "Không thể gia hạn vì \(displayedRoom.name) có \(title) lúc \(MeetingPresentation.time(nextBooking.startsAt))."
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
                    if canShowMeetingControls {
                        meetingControlCard
                    }

                    if canCancel {
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

    @ViewBuilder
    private var meetingControlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                meetingEnded ? "Cuộc họp đã kết thúc" : "Điều khiển cuộc họp",
                systemImage: meetingEnded ? "checkmark.circle.fill" : "slider.horizontal.3"
            )
            .font(.headline.weight(.bold))
            .foregroundStyle(.green)

            if meetingEnded {
                Text("Cuộc họp đã kết thúc. Bạn không thể gia hạn hoặc kết thúc lại.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                if let controlError {
                    Text(controlError)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if maximumExtensionMinutes >= 5 {
                    Text("Gia hạn thêm \(extensionMinutes) phút")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.green)

                    HStack(spacing: 10) {
                        Button("− 5 phút") {
                            extensionMinutes = max(5, extensionMinutes - 5)
                            controlError = nil
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSubmittingControl)

                        Button("+ 5 phút") {
                            extensionMinutes = min(maximumExtensionMinutes, extensionMinutes + 5)
                            controlError = nil
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSubmittingControl || extensionMinutes >= maximumExtensionMinutes)
                    }

                    Button {
                        Task { await submitMeetingControl("extend") }
                    } label: {
                        HStack(spacing: 8) {
                            if isSubmittingControl && controlAction == "extend" {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark")
                            }
                            Text(isSubmittingControl && controlAction == "extend" ? "Đang gia hạn…" : "Xác nhận gia hạn")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isSubmittingControl)
                } else {
                    Label("Gia hạn không khả dụng", systemImage: "clock.badge.exclamationmark")
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                        .foregroundStyle(.secondary)

                    Text(extensionBlockMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }

                Button(role: .destructive) {
                    // Irreversible: ask first.
                    confirmingEnd = true
                } label: {
                    HStack(spacing: 8) {
                        if isSubmittingControl && controlAction == "end" {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "stop.fill")
                        }
                        Text(isSubmittingControl && controlAction == "end" ? "Đang kết thúc…" : "Kết thúc cuộc họp")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmittingControl)
                .confirmationDialog("Kết thúc cuộc họp?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                    Button("Kết thúc", role: .destructive) { Task { await submitMeetingControl("end") } }
                    Button("Tiếp tục họp", role: .cancel) {}
                } message: {
                    Text("Phòng sẽ được giải phóng ngay để người khác có thể đặt. Không thể hoàn tác.")
                }
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @MainActor
    private func submitMeetingControl(_ action: String) async {
        guard !isSubmittingControl else { return }
        isSubmittingControl = true
        controlAction = action
        controlError = nil

        let error = await session.performMeetingControl(
            bookingID: currentBooking.id,
            action: action,
            extensionMinutes: extensionMinutes
        )

        controlError = error
        if error == nil {
            extensionMinutes = 5
        }
        controlAction = nil
        isSubmittingControl = false
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

struct MyMeetingsSheet: View {
    // Only calls session methods: must not redraw on every session change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @EnvironmentObject private var meetingStore: MeetingStore
    @Environment(\.dismiss) private var dismiss
    let day: Date
    @State private var showsUpcoming = true
    @State private var selectedMeeting: MeetingBooking?

    private var meetings: [MeetingBooking] {
        meetingStore.bookings
            .filter { $0.isMine ?? false }
            .filter { meeting in
                guard let end = meeting.endDate else { return showsUpcoming }
                return showsUpcoming ? end >= Date() : end < Date()
            }
            .sorted { $0.startsAt < $1.startsAt }
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
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        scheduleFilter

                        if meetings.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(Array(meetings.enumerated()), id: \.offset) { index, meeting in
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
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color(uiColor: .label))
                            .frame(width: 34, height: 34)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(Circle())
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

    private var header: some View {
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
                    Text("\(meetings.count)")
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
