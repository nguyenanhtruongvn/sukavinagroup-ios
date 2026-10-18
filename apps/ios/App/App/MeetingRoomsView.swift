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

enum MeetingPresentation {
    static let timezone = VietnamTime.timeZone
    static let calendar = VietnamTime.calendar
    /// The shared Vietnam-time "HH:mm" formatter.
    static var clock: DateFormatter { VietnamTime.clock }

    static func date(from value: String) -> Date? {
        VietnamTime.date(fromISO8601: value)
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

// One active presentation at a time. On iOS 17 competing sheet modifiers
// cause SwiftUI to resolve several complex generic destination trees together.
enum MeetingRoomsDestination: Identifiable {
    case booking(room: MeetingRoom, day: Date)
    case schedule(room: MeetingRoom, day: Date)
    case mine(day: Date)

    var id: String {
        switch self {
        case .booking(let room, _): return "booking-\(room.id)"
        case .schedule(let room, _): return "schedule-\(room.id)"
        case .mine: return "my-meetings"
        }
    }
}

enum MeetingScheduleDestination: Identifiable {
    case booking
    case detail(MeetingBooking)

    var id: String {
        switch self {
        case .booking: return "booking"
        case .detail(let booking): return "detail-\(booking.id)"
        }
    }
}

struct MeetingRoomsView: View {
    // Only calls session methods: must not redraw on every session change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @EnvironmentObject private var meetingStore: MeetingStore
    @Environment(\.scenePhase) private var scenePhase
    let isActive: Bool
    @State private var day = Date()
    @State private var presentedDestination: MeetingRoomsDestination?
    @State private var draggingRoom: MeetingRoom?

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

    private func refreshForCalendarChange() {
        let today = MeetingPresentation.calendar.startOfDay(for: .now)
        let selectedDay = MeetingPresentation.calendar.startOfDay(for: day)
        if selectedDay < today {
            day = .now
        } else if isActive {
            Task { await session.refreshMeetingSchedule(date: day) }
        }
    }

    /// Now, then each moment a room's status can change.
    private var statusChangeTimes: [Date] {
        let now = Date()
        let boundaries = meetingStore.bookingsByRoom.values.joined().flatMap { [$0.startDate, $0.endDate] }.compactMap { $0 }
        return [now] + MeetingBookingTime.statusChangeTimes(after: now, boundaries: boundaries, calendar: MeetingPresentation.calendar)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        // "No rooms configured" only once the schedule is known;
                        // before that show loading, or the failure with a retry.
                        if meetingStore.rooms.isEmpty {
                            if let scheduleError = meetingStore.scheduleError {
                                ContentUnavailableView {
                                    Label("Không tải được phòng họp", systemImage: "wifi.exclamationmark")
                                } description: {
                                    Text(scheduleError)
                                } actions: {
                                    Button("Thử lại") { Task { await session.refreshMeetingSchedule(date: day, force: true) } }
                                        .buttonStyle(.borderedProminent)
                                        .tint(AppTheme.red)
                                }
                                .padding(.top, 40)
                            } else if !meetingStore.scheduleLoaded {
                                ProgressView("Đang tải phòng họp…")
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 60)
                            } else {
                                ContentUnavailableView(
                                    "Chưa có phòng họp",
                                    systemImage: "building.2",
                                    description: Text("Quản trị viên cần cấu hình phòng trước khi nhân viên có thể đặt lịch.")
                                )
                                .padding(.top, 40)
                            }
                        }

                        // "Trống" / "Đang họp" change when a meeting starts or
                        // ends (or at midnight): redraw exactly then, not every minute.
                        TimelineView(.explicit(statusChangeTimes)) { clock in
                        ForEach(meetingStore.rooms) { room in
                            MeetingRoomCard(
                                room: room,
                                bookings: meetingStore.bookingsByRoom[room.id] ?? [],
                                day: day,
                                now: clock.date,
                                onBook: { presentedDestination = .booking(room: room, day: day) },
                                onSchedule: { presentedDestination = .schedule(room: room, day: day) }
                            )
                            // A smaller row boundary avoids eager expansion of the
                            // drag/drop generic tree by the iOS 17 SwiftUI runtime.
                            .modifier(MeetingRoomOrderingModifier(
                                room: room,
                                rooms: meetingStore.rooms,
                                draggingRoom: $draggingRoom,
                                saveOrder: { session.reorderMeetingRooms($0) }
                            ))
                        }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                // Title and day buttons stay put; only the rooms scroll.
                .safeAreaInset(edge: .top, spacing: 0) {
                    MeetingRoomsHeader(day: $day, onShowMine: {
                        presentedDestination = .mine(day: day)
                    })
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { switchMeetingDay(for: $0.translation) }
                )
                .modifier(MeetingRoomDragResetModifier(draggingRoom: $draggingRoom))
            }
            // Like every other tab: no navigation bar above the page header.
            .toolbar(.hidden, for: .navigationBar)
            .task(id: isActive) {
                guard isActive else { return }
                await session.refreshMeetingSchedule(date: day)
            }
            .onChange(of: day) { _, date in
                Task { await session.refreshMeetingSchedule(date: date) }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSCalendarDayChanged)) { _ in
                refreshForCalendarChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                refreshForCalendarChange()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                refreshForCalendarChange()
            }
            .refreshable {
                await session.refreshMeetingSchedule(date: day, force: true)
            }
            .sheet(item: $presentedDestination, onDismiss: {
                // The schedule sheet can switch to another date and a booking can
                // be made for another day; both reload the one shared schedule.
                // Show this list's own day again.
                Task { await session.refreshMeetingSchedule(date: day) }
            }) { destination in
                // Erase the concrete destination type at the sheet boundary.
                // Only the selected destination is mounted (iOS 17 safe).
                switch destination {
                case .booking(let room, let selectedDay):
                    AnyView(MeetingBookingSheet(room: room, day: selectedDay)
                        .sessionEnvironment(session))
                case .schedule(let room, let selectedDay):
                    AnyView(MeetingRoomScheduleSheet(room: room, day: selectedDay)
                        .sessionEnvironment(session))
                case .mine(let selectedDay):
                    AnyView(MyMeetingsSheet(day: selectedDay)
                        .sessionEnvironment(session))
                }
            }
        }
    }
}

// Keep the iOS 17 room card's SwiftUI type small and its navigation gestures
// predictable. The context-menu move buttons exist on every version (they are
// also the accessible, non-drag way to reorder); iOS 18 and later add native
// drag and drop on top of them.
struct MeetingRoomOrderingModifier: ViewModifier {
    let room: MeetingRoom
    let rooms: [MeetingRoom]
    @Binding var draggingRoom: MeetingRoom?
    let saveOrder: ([MeetingRoom]) -> Void

    private var roomIndex: Int? { rooms.firstIndex(where: { $0.id == room.id }) }

    func body(content: Content) -> AnyView {
        let reorderable = content.contextMenu { moveMenu }
        if #available(iOS 18.0, *) {
            return AnyView(
                reorderable
                    .opacity(draggingRoom?.id == room.id ? 0.72 : 1)
                    .onDrag {
                        draggingRoom = room
                        return NSItemProvider(object: room.id as NSString)
                    }
                    .onDrop(
                        of: [UTType.plainText.identifier],
                        delegate: MeetingRoomOrderDropDelegate(
                            target: room,
                            rooms: rooms,
                            draggingRoom: $draggingRoom,
                            saveOrder: saveOrder
                        )
                    )
            )
        }
        // The iOS 17 runtime sees only AnyView rather than the unavailable
        // drag/drop view's nested generic metadata.
        return AnyView(reorderable)
    }

    @ViewBuilder
    private var moveMenu: some View {
        Button {
            move(by: -1)
        } label: {
            Label("Chuyển phòng lên trên", systemImage: "arrow.up")
        }
        .disabled((roomIndex ?? 0) <= 0)

        Button {
            move(by: 1)
        } label: {
            Label("Chuyển phòng xuống dưới", systemImage: "arrow.down")
        }
        .disabled((roomIndex ?? (rooms.count - 1)) >= rooms.count - 1)
    }

    private func move(by offset: Int) {
        guard let index = roomIndex, rooms.indices.contains(index + offset) else { return }
        var reordered = rooms
        reordered.swapAt(index, index + offset)
        withAnimation(.snappy) { saveOrder(reordered) }
    }
}

/// Card drop targets reset the drag state themselves. A room released between
/// or outside the cards lands on this list-wide target instead, so the dragged
/// card never stays faded. Drag and drop exists only on iOS 18+, and the iOS 17
/// runtime must not see drop-target generics (see MeetingRoomOrderingModifier).
struct MeetingRoomDragResetModifier: ViewModifier {
    @Binding var draggingRoom: MeetingRoom?

    func body(content: Content) -> AnyView {
        if #available(iOS 18.0, *) {
            return AnyView(
                content.onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { _ in
                    draggingRoom = nil
                    return false
                }
            )
        }
        return AnyView(content)
    }
}

struct MeetingRoomOrderDropDelegate: DropDelegate {
    let target: MeetingRoom
    let rooms: [MeetingRoom]
    @Binding var draggingRoom: MeetingRoom?
    let saveOrder: ([MeetingRoom]) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingRoom,
              draggingRoom.id != target.id,
              let fromIndex = rooms.firstIndex(where: { $0.id == draggingRoom.id }),
              let targetIndex = rooms.firstIndex(where: { $0.id == target.id })
        else { return }

        var reordered = rooms
        reordered.move(
            fromOffsets: IndexSet(integer: fromIndex),
            toOffset: targetIndex > fromIndex ? targetIndex + 1 : targetIndex
        )
        withAnimation(.snappy) {
            saveOrder(reordered)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingRoom = nil
        return true
    }
}

struct MeetingRoomsHeader: View {
    @Binding var day: Date
    let onShowMine: () -> Void

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
        PortalPinnedHeader("Phòng họp", background: Color(uiColor: .systemGroupedBackground)) {
            HStack(spacing: 10) {
                Button {
                    day = .now
                } label: {
                    Text("Hôm nay")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(isToday ? .white : Color(uiColor: .label))
                        .padding(.horizontal, 16)
                        .frame(height: 38)
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
                        .frame(height: 38)
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
                    onShowMine()
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(uiColor: .label))
                        .frame(width: 38, height: 38)
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

struct MeetingRoomCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let room: MeetingRoom
    let bookings: [MeetingBooking]
    let day: Date
    /// Supplied by the list's minute timeline so the status stays current.
    let now: Date
    let onBook: () -> Void
    let onSchedule: () -> Void

    private var currentBooking: MeetingBooking? {
        guard MeetingPresentation.calendar.isDate(day, inSameDayAs: now) else { return nil }
        return bookings.first {
            guard let start = $0.startDate,
                  let end = $0.endDate else { return false }
            return now >= start && now < end
        }
    }

    private var nextBooking: MeetingBooking? {
        // Another day counts from its start: "day" carries the time it was
        // chosen, so tomorrow at 10:00 used to skip meetings before 10:00.
        let point = MeetingPresentation.calendar.isDate(day, inSameDayAs: now)
            ? now
            : MeetingPresentation.calendar.startOfDay(for: day)
        return bookings.first {
            guard let start = $0.startDate else { return false }
            return start > point
        }
    }

    private var isAvailable: Bool { currentBooking == nil }
    private var statusColor: Color { isAvailable ? Color.green : Color.red }
    private var cardBackground: Color {
        // Match the notification-card surface on each supported iOS design.
        if #available(iOS 26.0, *) {
            return AppTheme.card
        }
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
                : .white
        })
    }

    private var unavailableButtonFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.07)
    }

    private var unavailableButtonForeground: Color {
        Color(uiColor: .label)
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
                        .foregroundStyle(AppTheme.text(statusColor, chipAlpha: 0.12))
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
                        .foregroundStyle(AppTheme.text(statusColor))
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
                .foregroundStyle(isAvailable ? .white : unavailableButtonForeground)
                .background(isAvailable ? Color.red : unavailableButtonFill)
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

struct MeetingRoomImage: View {
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

struct MeetingRoomScheduleSheet: View {
    // Only calls session methods: must not redraw on every session change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @EnvironmentObject private var meetingStore: MeetingStore
    @Environment(\.dismiss) private var dismiss
    let room: MeetingRoom
    let day: Date
    @State private var selectedDay: Date
    @State private var presentedDestination: MeetingScheduleDestination?

    init(room: MeetingRoom, day: Date) {
        self.room = room
        self.day = day
        _selectedDay = State(initialValue: day)
    }

    private var bookings: [MeetingBooking] {
        meetingStore.bookingsByRoom[room.id] ?? []
    }

    // Meeting days are Vietnam days (AGENTS.md), not the device's time zone.
    private var isToday: Bool {
        MeetingPresentation.calendar.isDateInToday(selectedDay)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Past days cannot be booked; showing them only confused the list.
                        // Laid out as a labelled DatePicker is, the picker at
                        // its full date; see `SystemCompactDatePicker`.
                        CompactDateRow(label: "Ngày") {
                            SystemCompactDatePicker(
                                selection: $selectedDay,
                                mode: .date,
                                minimum: VietnamTime.calendar.startOfDay(for: .now),
                                accessibilityLabel: "Ngày"
                            )
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                        .onChange(of: selectedDay) { _, value in
                            Task { await session.refreshMeetingSchedule(date: value) }
                        }
                        // Type erase the heavy timeline separately from the
                        // enclosing NavigationStack on iOS 17.
                        AnyView(MeetingTimeline(bookings: bookings, date: selectedDay) {
                            presentedDestination = .detail($0)
                        })
                    }
                }
                    .scrollIndicators(.hidden)
                .task {
                    await session.refreshMeetingSchedule(date: selectedDay)
                    if isToday {
                        proxy.scrollTo(MeetingPresentation.calendar.component(.hour, from: .now), anchor: .center)
                    }
                }
            }
            .navigationTitle(room.name)
            .toolbar {
                Button("Đóng") { dismiss() }
            }
            .overlay(alignment: .bottomTrailing) {
                Button { presentedDestination = .booking } label: {
                    Image(systemName: "plus")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Color.green)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }
                .accessibilityLabel("Đặt phòng \(room.name)")
                .padding(22)
            }
            .sheet(item: $presentedDestination) { destination in
                switch destination {
                case .booking:
                    AnyView(MeetingBookingSheet(room: room, day: selectedDay)
                        .sessionEnvironment(session))
                case .detail(let booking):
                    AnyView(MeetingBookingDetailSheet(booking: booking, room: room)
                        .sessionEnvironment(session))
                }
            }
        }
    }
}
