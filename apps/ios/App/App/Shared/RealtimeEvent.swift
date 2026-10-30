import Foundation

/// One line of the server's change stream (`public/news/events`, SSE):
/// `data: {"type": "...", "employeeCodes": ["NV001", ...]}`.
///
/// Pure Foundation so it is unit-tested (see Package.swift). Mirrors Android
/// `RealtimeEventStream.changes`.
struct RealtimeEvent: Equatable {
    enum Change: String, CaseIterable {
        case attendance = "attendance_changed"
        case employee = "employee_changed"
        case ownProfile = "own_profile_changed"
        case managedRecipients = "managed_recipients_changed"
        case request = "request_changed"
        case meal = "meal_changed"
        case meeting = "meeting_changed"
        case content = "content_changed"
        /// This user read or deleted notifications on another device.
        case inbox = "inbox_changed"
    }

    /// The change kinds this event announces to the signed-in employee.
    let changes: Set<Change>
    /// `true`/`false` for an AI-assistant settings event, otherwise nil.
    let aiAssistantEnabled: Bool?

    private struct Payload: Decodable {
        let type: String?
        let employeeCodes: [String]?
    }

    /// Nil when the line carries nothing for this employee: not a change, or
    /// a change scoped (`employeeCodes`) to other employees. No scope means a
    /// company-wide change.
    init?(line: String, employeeCode: String?) {
        let body = line.hasPrefix("data:")
            ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            : line
        let payload = body.data(using: .utf8).flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
        if let scope = payload?.employeeCodes {
            guard let employeeCode, !employeeCode.isEmpty,
                  scope.contains(where: { $0.caseInsensitiveCompare(employeeCode) == .orderedSame }) else { return nil }
        }
        let type = payload?.type ?? body

        if type.contains("ai_assistant_settings_changed_disabled") {
            self.init(changes: [], aiAssistantEnabled: false)
            return
        }
        if type.contains("ai_assistant_settings_changed_enabled") {
            self.init(changes: [], aiAssistantEnabled: true)
            return
        }

        var changes = Set<Change>()
        for change in Change.allCases where change != .ownProfile && type.contains(change.rawValue) {
            changes.insert(change)
        }
        if changes.contains(.employee), Self.targetsEmployee(type, employeeCode: employeeCode) {
            changes.insert(.ownProfile)
        }
        guard !changes.isEmpty else { return nil }
        self.init(changes: changes, aiAssistantEnabled: nil)
    }

    init(changes: Set<Change>, aiAssistantEnabled: Bool?) {
        self.changes = changes
        self.aiAssistantEnabled = aiAssistantEnabled
    }

    /// Employee broadcasts are normally company-wide. Only an event addressed
    /// to the signed-in employee (`employee_changed:<code>`) reloads their own
    /// profile, keeping the direct-manager field stable during unrelated edits.
    private static func targetsEmployee(_ type: String, employeeCode: String?) -> Bool {
        guard let employeeCode, !employeeCode.isEmpty,
              let marker = type.range(of: "employee_changed:") else { return false }
        let target = String(type[marker.upperBound...])
            .components(separatedBy: CharacterSet(charactersIn: ",; \r\n\"}"))
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return target?.caseInsensitiveCompare(employeeCode) == .orderedSame
    }
}
