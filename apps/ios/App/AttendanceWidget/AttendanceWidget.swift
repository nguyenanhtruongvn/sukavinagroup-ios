import SwiftUI
import UIKit
import WidgetKit

private enum WidgetStorage {
    private static let originalAppGroup = "group.net.sukavinagroup.portal"
    static let stateKey = "attendance-widget-state"
    private static let tokenKey = "attendance-widget-token"
    private static let endpoint = URL(string: "https://sukavinagroup.net/api/public/widget/attendance")!

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
        guard let token = defaults?.string(forKey: tokenKey), !token.isEmpty else { return load() }
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
            let records = payload.attendanceRecords
            let state = State(
                checkIn: records.last?.punchedAt,
                checkOut: records.count > 1 ? records.first?.punchedAt : nil
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

    let entry: AttendanceEntry

    private struct WeekDay: Identifiable {
        let id: Date
        let label: String
        let number: String
        let isToday: Bool
    }

    var body: some View {
        ZStack {
            stripedWhiteBackground

            VStack(spacing: 8) {
                weekStrip
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
                .frame(height: 54)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .containerBackground(for: .widget) {
            Color.clear
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
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct SukavinaAttendanceWidgetBundle: WidgetBundle {
    var body: some Widget {
        SukavinaAttendanceWidget()
    }
}
