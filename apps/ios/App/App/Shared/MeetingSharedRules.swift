import Foundation

// Non-UI meeting rules shared by the iOS 18+ SwiftUI screens and the iOS 17
// UIKit screens (LegacyMeetingRoomsUIKit.swift). Both UIs stay: iOS 17
// aborts building the SwiftUI meeting views. Only the logic is one copy, so a
// fix applies to both and is unit-tested here (Foundation only).

/// What the booking form searches (`MeetingInvitee` conforms in the app).
protocol MeetingInviteeSearchable {
    var id: String { get }
    var fullName: String { get }
    var employeeCode: String { get }
    var department: String { get }
}

/// The booking form's derived values.
enum MeetingBookingForm {
    /// "Nội bộ · Họp giao ban", or just the type without a title.
    static func title(type: String, text: String) -> String {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? type : "\(type) · \(content)"
    }

    /// A typed title or chosen invitees would be lost by closing.
    static func hasUnsavedInput(title: String, selectedCount: Int) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedCount > 0
    }

    static func endTime(start: Date, durationMinutes: Int) -> Date {
        start.addingTimeInterval(Double(durationMinutes * 60))
    }

    /// Invitees matching the name/code query within the chosen departments;
    /// nothing until a query or a department is given.
    static func people<Invitee: MeetingInviteeSearchable>(
        _ invitees: [Invitee], query: String, departments: Set<String>
    ) -> [Invitee] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || !departments.isEmpty else { return [] }
        return invitees.filter {
            (departments.isEmpty || departments.contains($0.department))
                && (query.isEmpty
                    || $0.fullName.localizedCaseInsensitiveContains(query)
                    || $0.employeeCode.localizedCaseInsensitiveContains(query))
        }
    }

    /// Distinct non-empty department names, sorted for Vietnamese readers.
    static func departments<Invitee: MeetingInviteeSearchable>(_ invitees: [Invitee]) -> [String] {
        Array(Set(invitees.map(\.department)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func matchingDepartments(_ departments: [String], query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return departments.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    /// The chosen departments' people not invited yet ("Mời tất cả …").
    static func uninvited<Invitee: MeetingInviteeSearchable>(
        _ invitees: [Invitee], departments: Set<String>, selected: Set<String>
    ) -> [Invitee] {
        guard !departments.isEmpty else { return [] }
        return invitees.filter { departments.contains($0.department) && !selected.contains($0.id) }
    }
}

/// The booking detail's texts and the organiser's actions.
enum MeetingDetailRules {
    static func roleTitle(isOwner: Bool, isLimitedViewer: Bool) -> String {
        if isLimitedViewer { return "Thông tin giới hạn dành cho Phòng Nhân sự" }
        return isOwner ? "Bạn là người tổ chức" : "Bạn được mời tham dự"
    }

    /// SF Symbol name for the role line.
    static func roleIcon(isOwner: Bool, isLimitedViewer: Bool) -> String {
        isLimitedViewer ? "lock.shield.fill" : isOwner ? "person.badge.key.fill" : "person.2.badge.gearshape.fill"
    }

    static func dateTitle(start: Date?) -> String {
        guard let start else { return "Chưa xác định" }
        return VietnamTime.weekdayLongDate.string(from: start).capitalized
    }

    static func durationTitle(start: Date?, end: Date?) -> String {
        guard let start, let end else { return "—" }
        return DurationClock.title(minutes: max(0, Int(end.timeIntervalSince(start) / 60)))
    }

    /// A confirmed booking's organiser can cancel it before it starts…
    static func canCancel(isOwner: Bool, status: String, start: Date?, now: Date) -> Bool {
        guard isOwner, status == "confirmed", let start else { return false }
        return MeetingBookingTime.phase(start: start, end: nil, now: now) == .upcoming
    }

    /// …and end or extend it once it has started.
    static func showsControls(isOwner: Bool, status: String, start: Date?, now: Date) -> Bool {
        guard isOwner, status == "confirmed", let start else { return false }
        return MeetingBookingTime.phase(start: start, end: nil, now: now) != .upcoming
    }

    /// Why "Gia hạn" is unavailable. `next`: the room's next booking, its
    /// title and its start as shown ("HH:mm"); nil while the schedule loads.
    static func extensionBlockMessage(roomName: String, next: (title: String, startText: String)?) -> String {
        guard let next else { return "Không thể gia hạn vì lịch phòng đang được cập nhật." }
        let title = next.title.isEmpty ? "cuộc họp tiếp theo" : "“\(next.title)”"
        return "Không thể gia hạn vì \(roomName) có \(title) lúc \(next.startText)."
    }

    /// A booking added meanwhile can lower the limit below the chosen value.
    static func extensionToSend(chosen: Int, maximum: Int) -> Int {
        min(chosen, maximum)
    }

    /// "Sắp tới" vs "Đã qua" in My meetings: ended exactly at its end time.
    static func isUpcoming(end: Date?, now: Date) -> Bool {
        !MeetingBookingTime.hasEnded(end: end, now: now)
    }
}
