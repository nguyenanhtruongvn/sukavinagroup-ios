import SwiftUI
import UIKit
import WidgetKit
import ActivityKit

private enum WidgetStorage {
    private static let originalAppGroup = "group.net.sukavinagroup.user"
    static let stateKey = "attendance-widget-state"
    private static let tokenKey = "attendance-widget-token"
    private static let endpoint = "https://sukavinagroup.net/api/public/widget/attendance"

    private static var appGroup: String {
        let resignedGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
        return resignedGroups?.first(where: { $0.contains(originalAppGroup) }) ?? originalAppGroup
    }

    struct State: Codable {
        let checkIn: String?
        let checkOut: String?
    }

    static func load() -> State? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    static func fetchLatest() async -> State? {
        let defaults = UserDefaults(suiteName: appGroup)
        guard let token = defaults?.string(forKey: tokenKey), !token.isEmpty,
              var components = URLComponents(string: Self.endpoint) else { return load() }
        components.queryItems = [URLQueryItem(name: "refresh", value: String(Int(Date().timeIntervalSince1970)))]
        guard let endpoint = components.url else { return load() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try? JSONEncoder().encode(TokenBody(widgetToken: token))
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let payload = try? JSONDecoder().decode(AttendancePayload.self, from: data) else {
                return load()
            }
            let records = payload.attendanceRecords.sorted { $0.punchedAt < $1.punchedAt }
            let state = State(
                checkIn: records.first?.punchedAt,
                checkOut: records.count > 1 ? records.last?.punchedAt : nil
            )
            if let encoded = try? JSONEncoder().encode(state) {
                defaults?.set(encoded, forKey: stateKey)
                defaults?.synchronize()
            }
            return state
        } catch {
            return load()
        }
    }

    private struct TokenBody: Encodable {
        let widgetToken: String
    }

    private struct AttendancePayload: Decodable {
        let attendanceRecords: [AttendanceRecord]
    }

    private struct AttendanceRecord: Decodable {
        let punchedAt: String
    }
}

private struct AttendanceEntry: TimelineEntry {
    let date: Date
    let state: WidgetStorage.State?
}

private struct AttendanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> AttendanceEntry {
        AttendanceEntry(
            date: Date(),
            state: .init(
                checkIn: "2026-07-23T08:00:00+07:00",
                checkOut: "2026-07-23T17:00:00+07:00"
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (AttendanceEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : AttendanceEntry(date: Date(), state: WidgetStorage.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AttendanceEntry>) -> Void) {
        Task {
            let entry = AttendanceEntry(date: Date(), state: await WidgetStorage.fetchLatest())
            let nextRefresh = Calendar.current.date(byAdding: .minute, value: 1, to: Date()) ?? Date().addingTimeInterval(60)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

private struct AttendanceWidgetView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground

    let entry: AttendanceEntry

    private struct WeekDay: Identifiable {
        let id: Date
        let label: String
        let number: String
        let isToday: Bool
    }

    private struct MonthDay: Identifiable {
        let id: Int
        let number: String
        let isInMonth: Bool
        let isToday: Bool
    }

    private var usesGlassSurfaces: Bool {
        showsWidgetContainerBackground && renderingMode == .fullColor
    }

    var body: some View {
        ZStack {
            if widgetFamily == .systemLarge {
                largeLayout
            } else {
                mediumLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .containerBackground(for: .widget) {
            if usesGlassSurfaces {
                stripedWhiteBackground
            } else {
                Color.clear
            }
        }
    }

    private var mediumLayout: some View {
        VStack(spacing: 6) {
            weekStrip
            attendanceTimes
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var largeLayout: some View {
        VStack(spacing: 8) {
            monthCalendar
                .frame(maxHeight: .infinity)
            attendanceTimes
                .frame(height: 58)
        }
        .padding(12)
    }

    private var attendanceTimes: some View {
        HStack(spacing: 8) {
            timeValue(
                title: "GIỜ VÀO",
                value: timeLabel(entry.state?.checkIn),
                symbol: "arrow.right.to.line",
                tint: Color(red: 0.55, green: 0.90, blue: 0.70)
            )
            Rectangle()
                .fill(Color(red: 0.18, green: 0.25, blue: 0.30).opacity(0.22))
                .frame(width: 1, height: 48)
            timeValue(
                title: "GIỜ RA",
                value: timeLabel(entry.state?.checkOut),
                symbol: "arrow.left.to.line",
                tint: Color(red: 1.00, green: 0.52, blue: 0.55)
            )
        }
    }

    @ViewBuilder
    private var widgetArtwork: some View {
        if let url = Bundle.main.url(forResource: "WidgetBackground", withExtension: "jpg"),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [
                    Color(red: 1.00, green: 0.34, blue: 0.02),
                    Color(red: 0.95, green: 0.02, blue: 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var stripedWhiteBackground: some View {
        ZStack {
            Color(red: 0.97, green: 0.985, blue: 0.99)
            Canvas { context, size in
                var x: CGFloat = 4
                while x < size.width {
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: x, y: 0))
                    stripe.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(
                        stripe,
                        with: .color(Color(red: 0.18, green: 0.25, blue: 0.30).opacity(0.09)),
                        lineWidth: 1
                    )
                    x += 8
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var weekStrip: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 7),
            alignment: .center,
            spacing: 2
        ) {
            ForEach(weekDays) { day in
                VStack(spacing: 2) {
                    Text(day.label)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color(red: 0.35, green: 0.40, blue: 0.45))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                    Text(day.number)
                        .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(day.isToday ? Color.white : Color(red: 0.12, green: 0.16, blue: 0.20))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: 28, height: 28)
                        .background {
                            if day.isToday {
                                Circle()
                                    .fill(
                                        renderingMode == .fullColor
                                            ? Color(red: 0.92, green: 0.12, blue: 0.18)
                                            : Color.white.opacity(0.92)
                                    )
                                    .overlay {
                                        Circle()
                                            .stroke(Color.white.opacity(0.95), lineWidth: 2)
                                    }
                                    .shadow(color: .black.opacity(0.26), radius: 6, y: 2)
                            }
                        }
                }
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(height: 58)
        .clipped()
        .background {
            ZStack {
                if usesGlassSurfaces {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.96),
                                    Color(red: 0.88, green: 0.93, blue: 0.95).opacity(0.92),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.92), lineWidth: 1)
                }
            }
        }
    }

    private var monthCalendar: some View {
        VStack(spacing: 6) {
            Text(monthTitle)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.20))
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 7),
                spacing: 4
            ) {
                ForEach(["T2", "T3", "T4", "T5", "T6", "T7", "CN"], id: \.self) { label in
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.35, green: 0.40, blue: 0.45))
                        .frame(maxWidth: .infinity, minHeight: 18)
                }
                ForEach(monthDays) { day in
                    Text(day.number)
                        .font(.system(size: 13, weight: day.isToday ? .bold : .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(
                            day.isToday
                                ? Color.white
                                : Color(red: 0.12, green: 0.16, blue: 0.20).opacity(day.isInMonth ? 1 : 0.28)
                        )
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background {
                            if day.isToday {
                                Circle()
                                    .fill(Color(red: 0.92, green: 0.12, blue: 0.18))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        Circle().stroke(Color.white.opacity(0.95), lineWidth: 1.5)
                                    }
                            }
                        }
                }
            }
        }
        .padding(12)
        .background {
            if usesGlassSurfaces {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.82))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.96), lineWidth: 1)
                    }
            }
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = "'Tháng' M • yyyy"
        return formatter.string(from: entry.date)
    }

    private var monthDays: [MonthDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "vi_VN")
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        let today = calendar.startOfDay(for: entry.date)
        let components = calendar.dateComponents([.year, .month], from: today)
        guard let firstDay = calendar.date(from: components) else { return [] }
        let mondayOffset = (calendar.component(.weekday, from: firstDay) + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -mondayOffset, to: firstDay) else { return [] }
        return (0..<42).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index, to: gridStart) else { return nil }
            return MonthDay(
                id: index,
                number: String(calendar.component(.day, from: date)),
                isInMonth: calendar.isDate(date, equalTo: firstDay, toGranularity: .month),
                isToday: calendar.isDate(date, inSameDayAs: today)
            )
        }
    }

    private var weekDays: [WeekDay] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        let today = calendar.startOfDay(for: entry.date)
        let interval = calendar.dateInterval(of: .weekOfYear, for: today)
        let monday = interval?.start ?? today
        let labels = ["T2", "T3", "T4", "T5", "T6", "T7", "CN"]
        return labels.enumerated().compactMap { index, label in
            guard let date = calendar.date(byAdding: .day, value: index, to: monday) else { return nil }
            return WeekDay(
                id: date,
                label: label,
                number: date.formatted(.dateTime.day()),
                isToday: calendar.isDate(date, inSameDayAs: today)
            )
        }
    }

    private func timeValue(title: String, value: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.42), in: Circle())
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(Color(red: 0.35, green: 0.40, blue: 0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.20))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func timeLabel(_ value: String?) -> String {
        guard let value else { return "--:--" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return "--:--" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct SukavinaAttendanceWidget: Widget {
    let kind = "SukavinaAttendanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AttendanceProvider()) { entry in
            AttendanceWidgetView(entry: entry)
        }
        .configurationDisplayName("Chấm công hôm nay")
        .description("Xem nhanh giờ vào và giờ ra hôm nay.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
        .containerBackgroundRemovable(true)
    }
}

@available(iOS 17.0, *)
private struct MeetingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingLiveActivityAttributes.self) { context in
            MeetingLiveActivityView(context: context)
                .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.12))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "building.2.fill").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.endsAt, style: .timer).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MeetingLiveActivityControls(context: context)
                }
            } compactLeading: {
                Image(systemName: "building.2.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text(context.state.endsAt, style: .timer).monospacedDigit()
            } minimal: {
                Image(systemName: "clock.fill").foregroundStyle(.red)
            }
        }
    }
}

@available(iOS 17.0, *)
private struct MeetingLiveActivityView: View {
    let context: ActivityViewContext<MeetingLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "calendar.badge.clock").foregroundStyle(.red)
                Text(context.attributes.title).font(.headline).lineLimit(1)
                Spacer()
                Text(context.state.endsAt, style: .timer).font(.headline.monospacedDigit())
            }
            Text("\(context.attributes.roomName) · Còn lại \(context.state.endsAt, style: .timer)")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            ProgressView(timerInterval: context.attributes.startsAt...context.state.endsAt, countsDown: false)
                .tint(.red)
            MeetingLiveActivityControls(context: context)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

@available(iOS 17.0, *)
private struct MeetingLiveActivityControls: View {
    let context: ActivityViewContext<MeetingLiveActivityAttributes>

    var body: some View {
        HStack(spacing: 10) {
            Link(destination: actionURL("end")) {
                Text("Kết thúc").font(.caption.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Color.red, in: Capsule()).foregroundStyle(.white)
            }
            Link(destination: actionURL("extend")) {
                Text("Gia hạn +5 phút").font(.caption.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Color.white.opacity(0.18), in: Capsule()).foregroundStyle(.primary)
            }
        }
    }

    private func actionURL(_ action: String) -> URL {
        URL(string: "sukavina://meeting/\(context.attributes.bookingID)/\(action)")!
    }
}

@main
struct SukavinaAttendanceWidgetBundle: WidgetBundle {
    var body: some Widget {
        SukavinaAttendanceWidget()
        if #available(iOS 17.0, *) {
            MeetingLiveActivityWidget()
        }
    }
}
