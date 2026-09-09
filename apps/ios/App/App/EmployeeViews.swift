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

/// Applies the label preference to the UIKit tab bar already on screen.
/// This preserves the selected tab instead of recreating SwiftUI's TabView.
private struct TabBarLabelVisibilityUpdater: UIViewRepresentable {
    let showsLabels: Bool
    private static let tabTitles = ["Trang chủ", "Đơn từ", "Phòng họp", "Thông báo", "Tài khoản"]

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let window = uiView.window, let tabBar = findTabBar(from: window) else { return }
            for (index, item) in (tabBar.items ?? []).enumerated() {
                guard Self.tabTitles.indices.contains(index) else { continue }
                let title = Self.tabTitles[index]
                item.title = showsLabels ? title : nil
                item.accessibilityLabel = title
                item.titlePositionAdjustment = .zero
                item.imageInsets = showsLabels ? .zero : UIEdgeInsets(top: 6, left: 0, bottom: -6, right: 0)
            }
            tabBar.items?.forEach { $0.setTitleTextAttributes(nil, for: .normal) }
            tabBar.setNeedsLayout()
        }
    }

    private func findTabBar(from window: UIWindow) -> UITabBar? {
        if let root = window.rootViewController, let tabBar = findTabBar(in: root) { return tabBar }
        return findTabBar(in: window)
    }

    private func findTabBar(in controller: UIViewController) -> UITabBar? {
        if let tabController = controller as? UITabBarController { return tabController.tabBar }
        for child in controller.children {
            if let tabBar = findTabBar(in: child) { return tabBar }
        }
        if let presented = controller.presentedViewController { return findTabBar(in: presented) }
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

    private var tomorrow: Date {
        MeetingPresentation.calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
    }

    private func switchMeetingDay(for translation: CGSize) {
        guard abs(translation.width) > abs(translation.height), abs(translation.width) > 48 else { return }
        let isToday = MeetingPresentation.calendar.isDateInToday(day)
        let isTomorrow = MeetingPresentation.calendar.isDate(day, inSameDayAs: tomorrow)
        withAnimation(.snappy) {
            if translation.width < 0, isToday { day = tomorrow }
            if translation.width > 0, isTomorrow { day = .now }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
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
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { switchMeetingDay(for: $0.translation) }
                )
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
                MyMeetingsSheet(day: day)
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

    private var isToday: Bool {
        MeetingPresentation.calendar.isDateInToday(day)
    }

    private var isTomorrow: Bool {
        MeetingPresentation.calendar.isDate(
            day,
            inSameDayAs: MeetingPresentation.calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Phòng họp")
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(Color(uiColor: .label))

            HStack(spacing: 10) {
                Button {
                    day = .now
                } label: {
                    Text("Hôm nay")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(isToday ? .white : Color(uiColor: .label))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(isToday ? Color.red : Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            if !isToday {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Color(uiColor: .separator), lineWidth: 0.8)
                            }
                        }
                }
                .buttonStyle(.plain)

                Button {
                    day = MeetingPresentation.calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
                } label: {
                    Text("Ngày mai")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isTomorrow ? .white : Color(uiColor: .label))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(isTomorrow ? Color.red : Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            if !isTomorrow {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Color(uiColor: .separator), lineWidth: 0.8)
                            }
                        }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    showMine = true
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(uiColor: .label))
                        .frame(width: 40, height: 40)
                        .background(Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Color(uiColor: .separator), lineWidth: 0.8)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Lịch của tôi")
            }
        }
    }
}

@available(iOS 17.0, *)
private struct MeetingRoomCard: View {
    @Environment(\.colorScheme) private var colorScheme

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
    private var statusColor: Color { isAvailable ? Color.green : Color.red }
    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.13, green: 0.15, blue: 0.19)
            : Color(uiColor: .systemBackground)
    }

    private var cardShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.black.opacity(0.05)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MeetingRoomImage(room: room)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(room.name)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color(uiColor: .label))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                            Text(isAvailable ? "Trống" : "Đang họp")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(statusColor.opacity(0.12))
                        .clipShape(Capsule())
                    }

                    Text("\(room.capacity) chỗ · \(room.equipment.isEmpty ? "Thiết bị đang cập nhật" : room.equipment.joined(separator: " · "))")
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .lineLimit(2)

                    Text(availabilityText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSchedule)

            Button(action: isAvailable ? onBook : onSchedule) {
                HStack(spacing: 7) {
                    Image(systemName: isAvailable ? "calendar.badge.plus" : "calendar")
                        .font(.subheadline.weight(.bold))
                    Text(isAvailable ? "Đặt phòng" : "Xem lịch")
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(.white)
                .background(isAvailable ? Color.red : Color(uiColor: .label))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(
            color: cardShadow,
            radius: colorScheme == .dark ? 14 : 8,
            y: colorScheme == .dark ? 6 : 3
        )
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
        .frame(width: 88, height: 108)
        .background(Color.green.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .font(.system(size: 31, weight: .bold))
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
                        MeetingTimeline(bookings: bookings, date: selectedDay) { selectedBooking = $0 }
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
private struct MeetingTimelineBookingStyle {
    let fill: Color
    let accent: Color
    let foreground: Color
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
                            .fill(Color.secondary.opacity(0.045))
                            .frame(height: hourHeight)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.14))
                                    .frame(height: 1)
                            }
                    }
                }

                ForEach(Array(bookings.enumerated()), id: \.element.id) { index, booking in
                    if let position = bookingPosition(booking) {
                        let style = bookingStyle(at: index)
                        Button { onSelect(booking) } label: {
                            MeetingTimelineBlock(
                                booking: booking,
                                style: style,
                                showsTime: position.height >= 38
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(booking.id.isEmpty)
                        .accessibilityLabel(booking.id.isEmpty
                            ? "Khung giờ đã được đặt"
                            : "Xem chi tiết cuộc họp \(booking.title.isEmpty ? "đã có lịch" : booking.title)")
                        .frame(
                            maxWidth: .infinity,
                            minHeight: position.height,
                            maxHeight: position.height,
                            alignment: .topLeading
                        )
                        .offset(y: position.top)
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
            .frame(
                maxWidth: .infinity,
                minHeight: hourHeight * CGFloat(lastHour - firstHour + 1),
                alignment: .topLeading
            )
            .clipped()
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

        let startMinute = MeetingPresentation.calendar.component(.hour, from: start) * 60
            + MeetingPresentation.calendar.component(.minute, from: start)
        let endMinute = MeetingPresentation.calendar.component(.hour, from: end) * 60
            + MeetingPresentation.calendar.component(.minute, from: end)
        let visibleStart = max(startMinute, firstHour * 60)
        let visibleEnd = min(endMinute, (lastHour + 1) * 60)

        guard visibleEnd > visibleStart else { return nil }

        return (
            CGFloat(visibleStart - firstHour * 60) / 60 * hourHeight,
            max(CGFloat(visibleEnd - visibleStart) / 60 * hourHeight, 24)
        )
    }

    private func bookingStyle(at index: Int) -> MeetingTimelineBookingStyle {
        let palette: [MeetingTimelineBookingStyle] = [
            .init(fill: Color(red: 0.98, green: 0.82, blue: 0.80), accent: Color(red: 0.83, green: 0.22, blue: 0.18), foreground: Color(red: 0.39, green: 0.08, blue: 0.06)),
            .init(fill: Color(red: 0.82, green: 0.86, blue: 1.00), accent: Color(red: 0.19, green: 0.34, blue: 0.82), foreground: Color(red: 0.06, green: 0.14, blue: 0.42)),
            .init(fill: Color(red: 0.79, green: 0.94, blue: 0.86), accent: Color(red: 0.05, green: 0.53, blue: 0.31), foreground: Color(red: 0.02, green: 0.29, blue: 0.15)),
            .init(fill: Color(red: 1.00, green: 0.90, blue: 0.68), accent: Color(red: 0.80, green: 0.40, blue: 0.03), foreground: Color(red: 0.39, green: 0.18, blue: 0.01)),
            .init(fill: Color(red: 0.91, green: 0.82, blue: 0.99), accent: Color(red: 0.48, green: 0.21, blue: 0.74), foreground: Color(red: 0.24, green: 0.08, blue: 0.40)),
            .init(fill: Color(red: 0.77, green: 0.92, blue: 0.96), accent: Color(red: 0.03, green: 0.48, blue: 0.64), foreground: Color(red: 0.02, green: 0.24, blue: 0.34))
        ]
        return palette[index % palette.count]
    }
}

@available(iOS 17.0, *)
private struct MeetingTimelineBlock: View {
    let booking: MeetingBooking
    let style: MeetingTimelineBookingStyle
    let showsTime: Bool

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(style.accent)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(booking.title.isEmpty ? "Đã có lịch" : booking.title)
                    .font(.caption.bold())
                    .lineLimit(1)

                if showsTime {
                    Text(MeetingPresentation.range(booking))
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)

            Spacer(minLength: 0)
        }
        .foregroundStyle(style.foreground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(style.fill)
        .overlay {
            Rectangle()
                .stroke(style.accent.opacity(0.30), lineWidth: 1)
        }
    }
}


@available(iOS 17.0, *)
struct MeetingBookingDetailSheet: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    let booking: MeetingBooking
    let room: MeetingRoom
    @State private var details: MeetingBookingDetails?

    // Role color is shared with Android: organiser green, invitee blue.
    private var accent: Color { booking.isOwner == true ? Color(red: 0.13, green: 0.71, blue: 0.45) : .blue }
    private var roleTitle: String { booking.isOwner == true ? "Bạn là người tổ chức" : "Bạn được mời tham dự" }
    private var roleIcon: String { booking.isOwner == true ? "person.badge.key.fill" : "person.2.badge.gearshape.fill" }
    private var dateTitle: String {
        guard let start = MeetingPresentation.date(from: booking.startsAt) else { return "Chưa xác định" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.timeZone = MeetingPresentation.timezone
        formatter.dateFormat = "EEEE, dd 'tháng' MM, yyyy"
        return formatter.string(from: start).capitalized
    }
    private var durationTitle: String {
        guard let start = MeetingPresentation.date(from: booking.startsAt), let end = MeetingPresentation.date(from: booking.endsAt) else { return "—" }
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        return minutes >= 60 ? "\(minutes / 60) giờ\(minutes % 60 == 0 ? "" : " \(minutes % 60) phút")" : "\(minutes) phút"
    }
    private var displayedRoom: MeetingRoom { details?.room ?? room }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(alignment: .top) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.title2.bold()).foregroundStyle(.white)
                                .frame(width: 54, height: 54).background(accent.gradient)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            Spacer()
                            Label(booking.status == "confirmed" ? "Đã xác nhận" : booking.status, systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.bold)).foregroundStyle(accent)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(accent.opacity(0.12)).clipShape(Capsule())
                        }
                        Text(booking.title.isEmpty ? "Cuộc họp" : booking.title)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                        Label(roleTitle, systemImage: roleIcon)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [accent.opacity(0.18), Color(uiColor: .secondarySystemBackground)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                    detailCard(title: "Thời gian", icon: "clock.fill") {
                        Text(MeetingPresentation.range(booking)).font(.title3.weight(.bold).monospacedDigit())
                        Text(dateTitle).font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            detailPill(durationTitle, icon: "timer")
                            detailPill("\(booking.attendeeCount) người", icon: "person.2.fill")
                        }
                    }
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
                    if let details {
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
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Đang tải thông tin người tham gia…").font(.caption).foregroundStyle(.secondary)
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
                details = await session.meetingBookingDetails(id: booking.id)
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
    @State private var selectedDepartments = Set<String>()
    @State private var selected = Set<String>()
    @State private var inviteesError: String?
    @State private var showStartPicker = false
    @State private var showDurationPicker = false
    @FocusState private var focusedInviteeField: InviteeSearchField?

    private enum InviteeSearchField: Hashable {
        case people
        case departments
    }

    private var people: [MeetingInvitee] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty || !selectedDepartments.isEmpty else { return [] }
        return session.meetingInvitees.filter {
            (selectedDepartments.isEmpty || selectedDepartments.contains($0.department))
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

    private var matchingDepartments: [String] {
        let value = departmentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        return departments.filter { $0.localizedCaseInsensitiveContains(value) }
    }

    private var unselectedDepartmentInvitees: [MeetingInvitee] {
        guard !selectedDepartments.isEmpty else { return [] }
        return session.meetingInvitees.filter {
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
        title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
            && selected.count + 1 <= room.capacity
    }

    private var canConfirmBooking: Bool {
        isValid && session.isNetworkAvailable
    }

    private var endTime: Date {
        start.addingTimeInterval(Double(durationMinutes * 60))
    }

    private var dayLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "EEEE, dd/MM/yyyy"
        return formatter.string(from: day).capitalized
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            bookingHeader
                            meetingDetailsCard
                            inviteesCard
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 110)
                    }
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
                }
            }
            .safeAreaInset(edge: .bottom) {
                confirmButton
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
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
            // Selected departments show their people as normal card content.
            // Typed lookup results are instead presented as an overlay below.
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !selectedDepartments.isEmpty {
                peopleSearchResults
            }

            searchField(
                icon: "magnifyingglass",
                placeholder: "Tìm tên hoặc mã nhân viên",
                text: $query,
                focus: .people
            )
            .overlay(alignment: .bottom) {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    peopleSearchResults
                        .offset(y: -54)
                        .zIndex(2)
                }
            }
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
                // An overlay does not receive a proposed height from its text
                // field. Keep this row explicit so its two-line chips cannot be
                // compressed or drawn on top of the search field.
                .frame(height: 54)
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
        searchField(
            icon: "building.2",
            placeholder: "Tìm phòng ban",
            text: $departmentQuery,
            focus: .departments
        )
        .overlay(alignment: .bottom) {
            if !departmentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                departmentAutocompleteResults
                    .offset(y: -54)
                    .zIndex(2)
            }
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
                // This panel is presented above the field. Its horizontal row
                // must keep a real height instead of inheriting the field's
                // height from the overlay layout.
                .frame(height: 44)
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
                Image(systemName: "checkmark.circle.fill")
                Text("Xác nhận đặt phòng")
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
    @Environment(\.dismiss) private var dismiss
    let day: Date
    @State private var showsUpcoming = true
    @State private var selectedMeeting: MeetingBooking?

    private var meetings: [MeetingBooking] {
        session.meetingBookings
            .filter { $0.isMine ?? false }
            .filter { meeting in
                guard let end = MeetingPresentation.date(from: meeting.endsAt) else { return showsUpcoming }
                return showsUpcoming ? end >= Date() : end < Date()
            }
            .sorted { $0.startsAt < $1.startsAt }
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.timeZone = MeetingPresentation.timezone
        formatter.dateFormat = "EEEE, dd 'tháng' MM"
        return formatter.string(from: day).capitalized
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
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
                                            roomName: session.meetingRooms.first(where: { $0.id == meeting.roomId })?.name ?? "Phòng họp",
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
                if let room = session.meetingRooms.first(where: { $0.id == meeting.roomId }) {
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

@available(iOS 17.0, *)
private struct MeetingSummaryCard: View {
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

@available(iOS 17.0, *)
struct EmployeePortalView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var notificationRouter: APNsNotificationRouter
    @AppStorage("sukavina.showTabLabels") private var showTabLabels = true
    @State private var selectedTab = 0
    @State private var requestInitialFilter: EmployeeRequestStatus?








    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(isActive: selectedTab == 0) {
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
        .background(TabBarLabelVisibilityUpdater(showsLabels: showTabLabels))
        .accentColor(AppTheme.red)
        .adaptivePortalTabBarBackground()
        .onChange(of: notificationRouter.pendingRoute) { _, route in
            if route != nil { selectedTab = 3 }
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
    @State private var showTodayMenu = false
    let isActive: Bool
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

                    Button {
                        showTodayMenu = true
                    } label: {
                        todayMenuCard
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Xem thực đơn hôm nay")








                }
                .padding(20)
                .padding(.bottom, 92)
            }
            .hidesPortalBottomScrollEdgeEffect()
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .task { await requestStore.load(session.token) }
            .task { await session.refreshTodayMenu() }
            // Realtime events update attendance immediately when available.
            // This bounded fallback keeps the Home card current if an SSE
            // connection is briefly interrupted while the user remains here.
            .task(id: isActive) {
                guard isActive else { return }
                await session.refreshDashboard()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    await session.refreshDashboard()
                }
            }
            .task(id: session.requestRevision) {
                guard session.requestRevision > 0 else { return }
                await requestStore.load(session.token)
            }
            .refreshable {
                await session.refreshDashboard()
                await requestStore.load(session.token)
                await session.refreshTodayMenu()
            }
            .sheet(isPresented: $showTodayMenu) {
                TodayMenuView()
                    .environmentObject(session)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
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

    private var todayMenuCard: some View {
        let menu = session.todayMenu
        let mainDishes = [menu?.day.savoryMain, menu?.day.savorySide, menu?.day.vegetable, menu?.day.soup]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let vegetarianDishes = [menu?.day.vegetarianMain, menu?.day.vegetarianSide]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 38, height: 38)
                    .background(Color.orange.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Thực đơn hôm nay")
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text(menu?.day.dayName ?? "Đang cập nhật")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.muted)
            }

            Divider().overlay(Color.primary.opacity(0.07))

            if menu == nil {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Đang tải thực đơn hôm nay…")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                }
            } else {
                menuSummaryLine("Món chính", detail: mainDishes.isEmpty ? "Đang cập nhật" : mainDishes, color: .orange)
                if !vegetarianDishes.isEmpty {
                    menuSummaryLine("Món chay", detail: vegetarianDishes, color: .green)
                }
                if let featured = menu?.day.featured, !featured.isEmpty {
                    menuSummaryLine("Món nước", detail: featured, color: .cyan)
                }
                if let overtime = menu?.day.overtime, !overtime.isEmpty {
                    menuSummaryLine("Tăng ca", detail: overtime, color: .purple)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func menuSummaryLine(_ title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.muted)
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
            }
        }
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

    private var showsFullMonthCells: Bool {
        attendanceMonthDisplayMode == AttendanceMonthDisplayMode.full.rawValue
    }








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
                    if !showsFullMonthCells, let day = selectedDay(in: data, month: month) {
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
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(.xSmall ... .accessibility1)
    }








    private func preloadedCalendarCard(_ data: AttendanceMonth, month: String) -> some View {
        let cellHeight: CGFloat = showsFullMonthCells ? 78 : 50
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
                        VStack(spacing: showsFullMonthCells ? 3 : 0) {
                            Text(String(Int(day.date.suffix(2)) ?? 0))
                                .font(.subheadline.weight(selected ? .bold : .medium))
                            if showsFullMonthCells {
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
                            .foregroundStyle(dayStatuses(day).contains("absent") ? Self.absentColor : Color.primary)
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
        if cache[month] == nil, let cached = session.cachedAttendanceMonth(month) {
            cache[month] = cached
            selectedDates[month] = cached.days.first(where: { $0.date == Self.dayValue(Date()) })?.date
                ?? cached.days.last?.date
        }
        guard let token = session.token else { return }
        do {
            let loaded = try await session.loadAttendanceMonth(month, token: token)
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
