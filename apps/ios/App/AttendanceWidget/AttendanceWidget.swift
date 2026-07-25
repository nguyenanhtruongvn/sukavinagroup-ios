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
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(TokenBody(widgetToken: token))
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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
            if renderingMode == .fullColor {
                widgetArtwork
                Color.black.opacity(0.18)
            } else {
                Color.clear
            }

            VStack(spacing: 12) {
                weekStrip
                HStack(spacing: 0) {
                    timeValue(
                        title: "GIỜ VÀO",
                        value: timeLabel(entry.state?.checkIn),
                        symbol: "arrow.right.to.line",
                        tint: Color(red: 0.55, green: 0.90, blue: 0.70)
                    )
                    Rectangle()
                        .fill(.white.opacity(0.38))
                        .frame(width: 1, height: 54)
                        .padding(.horizontal, 18)
                    timeValue(
                        title: "GIỜ RA",
                        value: timeLabel(entry.state?.checkOut),
                        symbol: "arrow.left.to.line",
                        tint: Color(red: 1.00, green: 0.52, blue: 0.55)
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var weekStrip: some View {
        HStack(spacing: 0) {
            ForEach(weekDays) { day in
                VStack(spacing: 5) {
                    Text(day.label)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Color.white)
                    Text(day.number)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(day.isToday && renderingMode != .fullColor ? Color.black.opacity(0.76) : Color.white)
                        .frame(width: 27, height: 27)
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
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
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
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.34), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(Color.white)
            Text(value)
                    .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.white)
                .minimumScaleFactor(0.75)
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
