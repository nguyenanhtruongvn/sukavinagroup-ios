import SwiftUI
import WidgetKit

private enum WidgetStorage {
    static let appGroup = "group.net.sukavinagroup.portal"
    static let stateKey = "attendance-widget-state"

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
        let entry = AttendanceEntry(date: Date(), state: WidgetStorage.load())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

private struct AttendanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AttendanceEntry

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
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.05, blue: 0.06), Color(red: 0.06, green: 0.07, blue: 0.09)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock.badge.checkmark.fill")
                .foregroundStyle(Color(red: 1, green: 0.32, blue: 0.32))
            Text("CHẤM CÔNG HÔM NAY")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.72))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func attendanceContent(_ state: WidgetStorage.State) -> some View {
        if family == .systemSmall {
            HStack(spacing: 10) {
                compactTime(title: "Vào", value: timeLabel(state.checkIn), color: .green)
                compactTime(title: "Ra", value: timeLabel(state.checkOut), color: Color(red: 1, green: 0.32, blue: 0.32))
            }
            Spacer(minLength: 0)
            statusLabel(state.status)
        } else {
            HStack(spacing: 12) {
                timeCard(title: "GIỜ VÀO", value: timeLabel(state.checkIn), icon: "arrow.down.right", color: .green)
                timeCard(title: "GIỜ RA", value: timeLabel(state.checkOut), icon: "arrow.up.right", color: Color(red: 1, green: 0.32, blue: 0.32))
            }
            HStack {
                statusLabel(state.status)
                Spacer()
                Text("Cập nhật \(state.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
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
                .foregroundStyle(.white)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .foregroundStyle(.white.opacity(0.55))
                Text(value)
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusLabel(_ status: String) -> some View {
        Label(status.isEmpty ? "Chưa chấm công" : status, systemImage: statusSymbol(status))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text("--:--")
                .font(.title2.monospacedDigit().bold())
                .foregroundStyle(.white)
            Text("Mở Sukavina để cập nhật dữ liệu chấm công.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
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
