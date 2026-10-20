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

// Only non-zero numeric quantities and their units receive an accent.
// The string values here are formatted locally as "0 ngày", "1.5 giờ", etc.
enum AttendanceReportValueStyle {
    static func hasData(_ value: String) -> Bool {
        guard let first = value.split(separator: " ").first,
              let amount = Double(String(first).replacingOccurrences(of: ",", with: ".")) else {
            return false
        }
        return abs(amount) > 0.000_001
    }
}

struct AttendanceStatementListView: View {
    @Environment(\.sessionActions) private var actions
    /// Methods and non-published values only; observing the whole session
    /// redrew this screen on every unrelated session change.
    private var session: SessionStore { actions.store }
    @EnvironmentObject private var revisions: DataRevisions
    @State private var reports: [AttendanceReport] = []
    @State private var isLoading = true

    var body: some View {
        // Read the persisted snapshot during the first body evaluation, before
        // SwiftUI starts the asynchronous refresh task. This avoids a visible
        // loading flash when the employee has already opened this screen.
        let displayedReports = reports.isEmpty ? session.cachedAttendanceReports() : reports
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                if isLoading && displayedReports.isEmpty {
                    ProgressView("Đang tải bảng công...")
                        .tint(AppTheme.red)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if displayedReports.isEmpty {
                    ContentUnavailableView(
                        "Chưa có bảng công",
                        systemImage: "calendar.badge.clock",
                        description: Text("Bảng công đã phát hành sẽ hiển thị tại đây.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(displayedReports.sorted { $0.month > $1.month }) { report in
                        NavigationLink(destination: ModernAttendanceHistoryView(initialMonth: report.month, releasedStatementMonths: displayedReports.map(\.month))) {
                            HStack(spacing: 14) {
                                Text(AttendanceMetrics.monthTitle(report.month))
                                    .font(.headline)
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppTheme.muted)
                            }
                            .padding(17)
                            .background(AppTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .background(AppTheme.ink.ignoresSafeArea())
        .navigationTitle("Bảng công")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: revisions.attendance) {
            let cached = session.cachedAttendanceReports()
            if !cached.isEmpty {
                reports = cached
            }
            isLoading = reports.isEmpty
            let refreshed = await session.loadAttendanceReports()
            if !refreshed.isEmpty || reports.isEmpty {
                reports = refreshed
            }
            isLoading = false
        }
    }
}

// The overtime bar and its numeric value use the same accent.
struct AttendanceOvertimeProgressRow: View {
    let title: String
    let hours: Double
    let total: Double
    let color: Color

    private var fraction: CGFloat {
        guard total > 0, hours > 0 else { return 0 }
        return CGFloat(min(1, max(0, hours / total)))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .frame(width: 116, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            ProgressView(value: fraction)
                .tint(color)
                .accessibilityHidden(true)

            Text("\(AttendanceMetrics.hourText(hours)) giờ")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(hours > 0 ? color : Color.primary)
                .frame(minWidth: 51, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct AttendanceCodeLegend: View {
    // Shared across current attendance and released monthly statements.
    // Explanations reflect the HR-approved meaning of each payroll code.
    private static let notes: [(code: String, meaning: String)] = [
        ("1", "Làm đủ 1 ngày công 8h"),
        ("NP/2", "Nửa ngày công, nửa ngày hưởng lương phép năm"),
        ("RO", "Nghỉ có xin phép không hưởng lương"),
        ("RO/2", "Nửa ngày công, nửa ngày có xin phép và không hưởng lương"),
        ("B", "Nghỉ bệnh hưởng lương BHXH chi trả"),
        ("NP", "Nghỉ phép hưởng lương phép năm"),
        ("P/2", "Nghỉ cả ngày có đơn, 0,5 ngày hưởng phép năm, 0,5 ngày không lương"),
        ("NTL", "Nghỉ trừ lương (do nhân sự xác nhận)"),
        ("CT", "Công tác"),
        ("CĐ", "Ca đêm (công và giờ tăng ca do nhân sự nhập, hiện ở nửa phải ô ngày)"),
        ("NN", "Ngày nghỉ (nghỉ hưởng chế độ, nghỉ bù)"),
        ("NVP", "Nghỉ văn phòng"),
        ("V", "Vắng"),
        ("NL", "Nghỉ lễ")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Ghi chú:")
                .font(.subheadline.bold())
                .italic()
                .foregroundStyle(Color.primary)

            ForEach(Self.notes.indices, id: \.self) { index in
                (Text("\(Self.notes[index].code): ").bold()
                 + Text(Self.notes[index].meaning).italic())
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(
                        "\(Self.notes[index].code): \(Self.notes[index].meaning)"
                    )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
