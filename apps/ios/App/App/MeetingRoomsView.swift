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
    /// Set on a calendar change (midnight, clock change, return to the app)
    /// so the status timeline is rebuilt (see refreshForCalendarChange).
    @State private var calendarEpoch = Date()

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
        // Rebuilds the status timeline: its times end at midnight, and an
        // unchanged schedule no longer redraws this screen to renew them.
        calendarEpoch = .now
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
        let now = max(Date(), calendarEpoch)
        let boundaries = meetingStore.bookingsByRoom.values.joined().flatMap { [$0.startDate, $0.endDate] }.compactMap { $0 }
        return [now] + MeetingBookingTime.statusChangeTimes(after: now, boundaries: boundaries, calendar: MeetingPresentation.calendar)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                // "Trống" / "Đang họp" change when a meeting starts or ends
                // (or at midnight): redraw exactly then, not every minute.
                TimelineView(.explicit(statusChangeTimes)) { clock in
                    List {
                        // "No rooms configured" only once the schedule is known;
                        // before that show loading, or the failure with a retry.
                        Group {
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
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                        // Apple's list reordering: touch and hold a card, then
                        // drag it; the others make room, the list scrolls at its
                        // edges, and the order is saved once, on release. (It
                        // was drag-and-drop between cards, which saved and
                        // redrew on every card passed.) The context menu keeps
                        // "Chuyển lên / xuống" as the non-drag way.
                        ForEach(meetingStore.rooms) { room in
                            MeetingRoomCard(
                                room: room,
                                bookings: meetingStore.bookingsByRoom[room.id] ?? [],
                                day: day,
                                now: clock.date,
                                onBook: { presentedDestination = .booking(room: room, day: day) },
                                onSchedule: { presentedDestination = .schedule(room: room, day: day) }
                            )
                            // Long-press preview and lifted card in the card's own shape,
                            // not the row's rectangle.
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .modifier(MeetingRoomMoveMenu(
                                room: room,
                                rooms: meetingStore.rooms,
                                saveOrder: { session.reorderMeetingRooms($0) }
                            ))
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        .onMove { source, destination in
                            var reordered = meetingStore.rooms
                            reordered.move(fromOffsets: source, toOffset: destination)
                            session.reorderMeetingRooms(reordered)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                    .contentMargins(.top, 6, for: .scrollContent)
                    .contentMargins(.bottom, 8, for: .scrollContent)
                }
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

/// "Chuyển phòng lên trên / xuống dưới" in the card's context menu: the
/// non-drag, VoiceOver-friendly way to reorder (the list's own drag reorders
/// too, see MeetingRoomsView).
struct MeetingRoomMoveMenu: ViewModifier {
    let room: MeetingRoom
    let rooms: [MeetingRoom]
    let saveOrder: ([MeetingRoom]) -> Void

    private var roomIndex: Int? { rooms.firstIndex(where: { $0.id == room.id }) }

    func body(content: Content) -> some View {
        content.contextMenu {
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
    }

    private func move(by offset: Int) {
        guard let index = roomIndex, rooms.indices.contains(index + offset) else { return }
        var reordered = rooms
        reordered.swapAt(index, index + offset)
        withAnimation(.snappy) { saveOrder(reordered) }
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
                    // Title and badge share their first line. The badge
                    // stays pinned to the right, even when the title wraps
                    // onto a second line; never squeeze or wrap the badge.
                    HStack(alignment: .top, spacing: 8) {
                        Text(room.name)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color(uiColor: .label))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

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
                        .fixedSize(horizontal: true, vertical: true)
                    }

                    // Directly below the title: row two for a short name,
                    // row three when its name spans two lines.
                    Text(availabilityText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.text(statusColor))
                        .fixedSize(horizontal: false, vertical: true)
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

/// Decoded room photos, shared by the SwiftUI cards (iOS 18+) and the UIKit
/// cards (iOS 17). AsyncImage kept no decoded copy: every time a card was
/// rebuilt (opening the tab, scrolling back, a schedule refresh) the photo
/// was fetched again and the placeholder flashed in between.
enum MeetingRoomPhotos {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// The room's photo URL (site-relative paths on the Sukavina server).
    static func url(for room: MeetingRoom) -> URL? {
        let value = room.imageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.hasPrefix("/") ? SukavinaServer.origin + value : value),
              url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    static func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// The card photo's size, 88 × 108 pt, in pixels at up to 3×.
    private static let thumbnailPixels = CGSize(width: 88 * 3, height: 108 * 3)

    /// The cached photo, or downloads it and decodes it off the main thread,
    /// scaled down to fill the card (a full-size camera photo decodes to tens
    /// of megabytes), and keeps it. Nil when it cannot be loaded.
    static func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = UIImage(data: data) else { return nil }
        let pixels = CGSize(width: decoded.size.width * decoded.scale, height: decoded.size.height * decoded.scale)
        let fill = max(thumbnailPixels.width / max(pixels.width, 1), thumbnailPixels.height / max(pixels.height, 1))
        let prepared: UIImage?
        if fill < 1 {
            // Aspect ratio kept: both sides scaled by the same factor.
            prepared = await decoded.byPreparingThumbnail(
                ofSize: CGSize(width: (pixels.width * fill).rounded(.up), height: (pixels.height * fill).rounded(.up))
            )
        } else {
            prepared = await decoded.byPreparingForDisplay()
        }
        let image = prepared ?? decoded
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }
}

struct MeetingRoomImage: View {
    let room: MeetingRoom
    /// The photo this card loaded, with the URL it belongs to.
    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        let url = MeetingRoomPhotos.url(for: room)
        // A photo already decoded shows at once, with no placeholder frame.
        let image = (loaded?.url == url ? loaded?.image : nil) ?? url.flatMap(MeetingRoomPhotos.cached)
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: 88, height: 108)
        .background(Color.green.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: url) {
            // Kept here too: the shared cache may drop it (memory, limits).
            guard let url else { return }
            if let image = await MeetingRoomPhotos.load(url) { loaded = (url, image) }
        }
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
                        // Laid out as a labelled DatePicker is; see
                        // `DatePopoverField`.
                        CompactDateRow(label: "Ngày") {
                            DatePopoverField(
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
                // The current minute in the middle from the first frame: the
                // timeline's geometry does not depend on the bookings, so
                // this need not wait for the network (it centred the hour
                // after the refresh, then jumped).
                .onAppear {
                    if isToday { proxy.scrollTo(MeetingTimeline.nowAnchorID, anchor: .center) }
                }
                .task {
                    await session.refreshMeetingSchedule(date: selectedDay)
                }
            }
            .navigationTitle(room.name)
            // Inline, as it shows once scrolled: a large title collapses
            // while the schedule is centred on now and shifts the middle.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Đóng") { dismiss() }
            }
            .overlay(alignment: .bottomTrailing) {
                // Apple's prominent circle button, as "Tạo đơn mới" in
                // Requests (it was a drawn green circle with a shadow).
                Button { presentedDestination = .booking } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(.green)
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
