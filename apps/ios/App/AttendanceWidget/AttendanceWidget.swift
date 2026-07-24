import SwiftUI
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
        let employeeName: String
        let status: String
        let checkIn: String?
        let checkOut: String?
        let updatedAt: Date
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
            let cachedName = load()?.employeeName ?? "Sukavina"
            let state = State(
                employeeName: cachedName,
                status: payload.attendanceStatus,
                checkIn: records.last?.punchedAt,
                checkOut: records.count > 1 ? records.first?.punchedAt : nil,
                updatedAt: ISO8601DateFormatter().date(from: payload.updatedAt) ?? Date()
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
        let attendanceStatus: String
        let attendanceRecords: [AttendanceRecord]
        let updatedAt: String
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
                employeeName: "Sukavina",
                status: "Đã chấm công",
                checkIn: "2026-07-23T08:00:00+07:00",
                checkOut: "2026-07-23T17:00:00+07:00",
                updatedAt: Date()
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
    @Environment(\.widgetFamily) private var family
    let entry: AttendanceEntry

    private let inkColor = Color(red: 0.16, green: 0.11, blue: 0.14)
    private let checkInColor = Color(red: 0.03, green: 0.48, blue: 0.37)
    private let checkOutColor = Color(red: 0.78, green: 0.34, blue: 0.03)

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 10 : 12) {
            header
            if let state = entry.state {
                attendanceContent(state)
            } else {
                emptyContent
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 1.00, green: 0.97, blue: 0.91),
                        Color(red: 1.00, green: 0.90, blue: 0.82),
                        Color(red: 1.00, green: 0.83, blue: 0.77),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color.white.opacity(0.62))
                    .frame(width: family == .systemSmall ? 140 : 220)
                    .blur(radius: 18)
                    .offset(x: family == .systemSmall ? 78 : 155, y: -82)
                Circle()
                    .fill(Color(red: 1.00, green: 0.48, blue: 0.34).opacity(0.16))
                    .frame(width: family == .systemSmall ? 115 : 190)
                    .blur(radius: 20)
                    .offset(x: family == .systemSmall ? -80 : -165, y: 88)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.checkmark.fill")
                .font(.caption.bold())
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 1.00, green: 0.84, blue: 0.48)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 25, height: 25)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("CHẤM CÔNG HÔM NAY")
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.78, green: 0.04, blue: 0.12),
                    Color(red: 0.96, green: 0.20, blue: 0.17),
                ],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.white.opacity(0.42), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private func attendanceContent(_ state: WidgetStorage.State) -> some View {
        if family == .systemSmall {
            HStack(spacing: 10) {
                compactTime(title: "Vào", value: timeLabel(state.checkIn), color: checkInColor)
                compactTime(title: "Ra", value: timeLabel(state.checkOut), color: checkOutColor)
            }
            Spacer(minLength: 0)
            statusLabel(state.status)
        } else {
            HStack(spacing: 12) {
                timeCard(title: "GIỜ VÀO", value: timeLabel(state.checkIn), icon: "arrow.down.right", color: checkInColor)
                timeCard(title: "GIỜ RA", value: timeLabel(state.checkOut), icon: "arrow.up.right", color: checkOutColor)
            }
            HStack {
                statusLabel(state.status)
                Spacer()
                Text("Cập nhật \(state.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(inkColor.opacity(0.62))
            }
        }
    }

    private func compactTime(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(inkColor)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.98), color.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(color.opacity(0.32), lineWidth: 1)
        }
    }

    private func timeCard(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.bold())
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                Text(value)
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(inkColor)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.98), color.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(color.opacity(0.3), lineWidth: 1)
        }
    }

    private func statusLabel(_ status: String) -> some View {
        Label(status.isEmpty ? "Chưa chấm công" : status, systemImage: statusSymbol(status))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(red: 0.62, green: 0.04, blue: 0.10))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.82), in: Capsule())
            .overlay {
                Capsule().stroke(Color(red: 0.76, green: 0.06, blue: 0.12).opacity(0.2), lineWidth: 0.8)
            }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text("--:--")
                .font(.title2.monospacedDigit().bold())
                .foregroundStyle(inkColor)
            Text("Mở Sukavina để cập nhật dữ liệu chấm công.")
                .font(.caption)
                .foregroundStyle(inkColor.opacity(0.68))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func timeLabel(_ value: String?) -> String {
        guard let value else { return "--:--" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return "--:--" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func statusSymbol(_ status: String) -> String {
        status.localizedCaseInsensitiveContains("chưa") ? "clock" : "checkmark.circle.fill"
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct SukavinaAttendanceWidgetBundle: WidgetBundle {
    var body: some Widget {
        SukavinaAttendanceWidget()
    }
}
