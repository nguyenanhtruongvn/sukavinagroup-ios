import UIKit
import SwiftUI
import Security
import UserNotifications
import Network
import LocalAuthentication
import WidgetKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import WebKit

struct MeetingRoom: Codable, Identifiable {
    let id: String
    let name: String
    let location: String
    let imageUrl: String
    let capacity: Int
    let equipment: [String]
    let active: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, location, imageUrl, capacity, equipment, active
    }

    /// Older API responses did not include `imageUrl`. Keep these rooms usable
    /// when they are embedded in a meeting-detail response instead of rejecting
    /// the entire response during decoding.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        location = try values.decodeIfPresent(String.self, forKey: .location) ?? ""
        imageUrl = try values.decodeIfPresent(String.self, forKey: .imageUrl) ?? ""
        capacity = try values.decode(Int.self, forKey: .capacity)
        equipment = try values.decodeIfPresent([String].self, forKey: .equipment) ?? []
        active = try values.decodeIfPresent(Bool.self, forKey: .active) ?? true
    }
}

struct MeetingBooking: Codable, Identifiable {
    let id: String
    let roomId: String
    let startsAt: String
    let endsAt: String
    let title: String
    let attendeeCount: Int
    let status: String
    let isMine: Bool?
    let isOwner: Bool?
    let organizerName: String?
}

struct MeetingScheduleResponse: Codable {
    let rooms: [MeetingRoom]
    let bookings: [MeetingBooking]
}

/// The schedule intentionally contains only the fields needed to draw a day.
/// Fetch this richer representation after the user opens a booking so employee
/// information is not disclosed for meetings they did not select.
struct MeetingBookingPerson: Codable, Identifiable {
    let id: String
    let fullName: String
    let employeeCode: String
    let department: String?
    let jobTitle: String?
}

struct MeetingBookingParticipant: Codable, Identifiable {
    let id: String
    let employee: MeetingBookingPerson
}

struct MeetingBookingDetails: Codable, Identifiable {
    let id: String
    let roomId: String
    let startsAt: String
    let endsAt: String
    let title: String
    let attendeeCount: Int
    let status: String
    let room: MeetingRoom
    let employee: MeetingBookingPerson
    let participants: [MeetingBookingParticipant]
    let isLimitedViewer: Bool?
}

struct MeetingInvitee: Codable, Identifiable {
    let id: String
    let fullName: String
    let employeeCode: String
    let department: String

    private enum CodingKeys: String, CodingKey {
        case id, fullName, employeeCode, department
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        fullName = try values.decodeIfPresent(String.self, forKey: .fullName) ?? ""
        employeeCode = try values.decodeIfPresent(String.self, forKey: .employeeCode) ?? ""
        department = try values.decodeIfPresent(String.self, forKey: .department) ?? ""
    }
}
struct CreateMeetingBookingBody: Encodable {
    let roomId: String
    let startsAt: String
    let endsAt: String
    let title: String
    let attendeeCount: Int
    let participantIds: [String]

    // The API expects employee UUIDs under these exact camel-case keys.
    // Keeping them explicit prevents a future encoder-wide key strategy from
    // silently dropping the invitee list.
    private enum CodingKeys: String, CodingKey {
        case roomId, startsAt, endsAt, title, attendeeCount, participantIds
    }
}

struct ExtendMeetingBookingBody: Encodable {
    let minutes: Int
}

struct UserSummary: Codable {
    let employeeCode: String
    let name: String
    let role: String
    let accountType: String
    let permissions: [String]
    let protected: Bool

    private enum CodingKeys: String, CodingKey {
        case employeeCode, name, role, accountType, permissions, protected
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        employeeCode = try values.decode(String.self, forKey: .employeeCode)
        name = try values.decode(String.self, forKey: .name)
        role = try values.decodeIfPresent(String.self, forKey: .role) ?? "Nhân viên"
        accountType = try values.decodeIfPresent(String.self, forKey: .accountType) ?? "EMPLOYEE"
        permissions = try values.decodeIfPresent([String].self, forKey: .permissions) ?? []
        protected = try values.decodeIfPresent(Bool.self, forKey: .protected) ?? false
    }
}

struct LoginResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let widgetToken: String
    let user: UserSummary

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, widgetToken, user
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        widgetToken = try values.decodeIfPresent(String.self, forKey: .widgetToken) ?? ""
        user = try values.decode(UserSummary.self, forKey: .user)
    }
}

struct RefreshSessionBody: Encodable {
    let refreshToken: String
}

struct Profile: Codable {
    let id: String
    let employeeCode: String
    let name: String
    let role: String
    let accountType: String
    let permissions: [String]
    let protected: Bool
    let email: String?
    let passwordChangedAt: Date?
}

enum SessionCache {
    private static let profileKey = "cached-session-profile-v1"
    private static let meetingRoomsPrefix = "cached-meeting-rooms-v1-"
    private static let meetingSchedulePrefix = "cached-meeting-schedule-v1-"
    private static let meetingScheduleSavedAtPrefix = "cached-meeting-schedule-saved-at-v1-"
    private static let meetingRoomOrderPrefix = "meeting-room-order-v1-"

    static func save(profile: Profile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: profileKey)
    }

    static func loadProfile() -> Profile? {
        guard let data = UserDefaults.standard.data(forKey: profileKey) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    static func saveMeetingRooms(_ rooms: [MeetingRoom], employeeCode: String) {
        guard let data = try? JSONEncoder().encode(rooms) else { return }
        UserDefaults.standard.set(data, forKey: meetingRoomsPrefix + employeeCode)
    }

    static func loadMeetingRooms(employeeCode: String) -> [MeetingRoom] {
        guard let data = UserDefaults.standard.data(forKey: meetingRoomsPrefix + employeeCode) else { return [] }
        return (try? JSONDecoder().decode([MeetingRoom].self, from: data)) ?? []
    }

    static func saveMeetingRoomOrder(_ roomIDs: [String], employeeCode: String) {
        var uniqueRoomIDs: [String] = []
        for roomID in roomIDs where !uniqueRoomIDs.contains(roomID) {
            uniqueRoomIDs.append(roomID)
        }
        UserDefaults.standard.set(uniqueRoomIDs, forKey: meetingRoomOrderPrefix + employeeCode)
    }

    static func loadMeetingRoomOrder(employeeCode: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: meetingRoomOrderPrefix + employeeCode) ?? []
    }

    static func saveMeetingSchedule(_ schedule: MeetingScheduleResponse, day: String, employeeCode: String) {
        guard let data = try? JSONEncoder().encode(schedule) else { return }
        let suffix = employeeCode + "-" + day
        UserDefaults.standard.set(data, forKey: meetingSchedulePrefix + suffix)
        UserDefaults.standard.set(Date(), forKey: meetingScheduleSavedAtPrefix + suffix)
    }

    static func loadMeetingSchedule(day: String, employeeCode: String) -> MeetingScheduleResponse? {
        guard let data = UserDefaults.standard.data(forKey: meetingSchedulePrefix + employeeCode + "-" + day) else { return nil }
        return try? JSONDecoder().decode(MeetingScheduleResponse.self, from: data)
    }

    static func meetingScheduleSavedAt(day: String, employeeCode: String) -> Date? {
        UserDefaults.standard.object(
            forKey: meetingScheduleSavedAtPrefix + employeeCode + "-" + day
        ) as? Date
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: profileKey)
    }
}

struct ContentItem: Codable, Identifiable {
    let id: String
    let page: String
    let key: String
    let title: String
    let body: String
    let sortOrder: Int
    let published: Bool
    let createdAt: Date
    let plainBody: String
    let articleBlocks: [ArticleBlock]
    let preview: String

    private enum CodingKeys: String, CodingKey {
        case id, page, key, title, body, sortOrder, published, createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        page = try values.decode(String.self, forKey: .page)
        key = try values.decode(String.self, forKey: .key)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        sortOrder = try values.decode(Int.self, forKey: .sortOrder)
        published = try values.decode(Bool.self, forKey: .published)
        createdAt = try values.decode(Date.self, forKey: .createdAt)

        let text = body.safeHTMLText
        plainBody = text
        articleBlocks = HTMLArticleParser.parse(body)
        preview = text.count > 145 ? String(text.prefix(145)) + "…" : text
    }
}

struct MenuDay: Codable {
    let dayIndex: Int
    let dayName: String
    let featured: String
    let savoryMain: String
    let savorySide: String
    let vegetable: String
    let soup: String
    let vegetarianMain: String
    let vegetarianSide: String
    let overtime: String
}

struct TodayMenu: Codable {
    let date: String
    let day: MenuDay
    let selection: String?
    let receivedAt: String?
    let orderingOpen: Bool
    let orderingCutoff: String
    let availableChoices: MealAvailability?
}

struct MealAvailability: Codable {
    let water: Bool
    let vegetarian: Bool
}

struct MealQrIssueResponse: Decodable {
    let token: String
    let expiresAt: String
    let expiresInSeconds: Int
}

struct MealScanResponse: Decodable {
    let valid: Bool
    let alreadyReceived: Bool
    let employeeCode: String
    let fullName: String
    let department: String
    let choice: String
    let mealName: String?
    let mealDate: String
    let receivedAt: String
}

struct MealSelectionBody: Encodable {
    let choice: String
}

struct MealQrScanBody: Encodable {
    let token: String
}

struct ArticleBlock: Identifiable {
    enum Kind {
        case heading(Int)
        case paragraph
        case listItem
        case image(URL?, String)
        case tableRow
        case question
    }

    let id: Int
    let kind: Kind
    let text: String
}

enum HTMLArticleParser {
    private static let blockRegex = try? NSRegularExpression(
        pattern: #"(?is)<(h[1-6]|p|li|blockquote|summary|tr)\b[^>]*>(.*?)</\1\s*>|<img\b[^>]*>"#
    )
    private static let sourceRegex = try? NSRegularExpression(pattern: #"(?i)\bsrc\s*=\s*["']([^"']+)["']"#)
    private static let altRegex = try? NSRegularExpression(pattern: #"(?i)\b(?:alt|title)\s*=\s*["']([^"']+)["']"#)

    static func parse(_ html: String) -> [ArticleBlock] {
        let source = html.count > 750_000 ? String(html.prefix(750_000)) : html
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let blockRegex else {
            return source.safeHTMLText.readingChunks.enumerated().map {
                ArticleBlock(id: $0.offset, kind: .paragraph, text: $0.element)
            }
        }
        let matches = blockRegex.matches(in: source, range: range)
        var blocks: [ArticleBlock] = []
        blocks.reserveCapacity(matches.count)

        for match in matches {
            guard let fullRange = Range(match.range, in: source) else { continue }
            let fragment = String(source[fullRange])
            if fragment.lowercased().hasPrefix("<img") {
                let src = attribute(in: fragment, regex: sourceRegex)
                let alt = attribute(in: fragment, regex: altRegex) ?? "Hình ảnh bài viết"
                blocks.append(ArticleBlock(id: blocks.count, kind: .image(articleURL(src), alt), text: alt))
                continue
            }

            guard let tagRange = Range(match.range(at: 1), in: source),
                  let bodyRange = Range(match.range(at: 2), in: source) else { continue }
            let tag = source[tagRange].lowercased()
            let text = String(source[bodyRange]).safeHTMLText
            guard !text.isEmpty else { continue }
            let kind: ArticleBlock.Kind
            if tag.hasPrefix("h"), let level = Int(tag.dropFirst()) {
                kind = .heading(level)
            } else if tag == "li" {
                kind = .listItem
            } else if tag == "tr" {
                kind = .tableRow
            } else if tag == "summary" {
                kind = .question
            } else {
                kind = .paragraph
            }

            for chunk in text.readingChunks {
                blocks.append(ArticleBlock(id: blocks.count, kind: kind, text: chunk))
            }
        }

        if blocks.isEmpty {
            return source.safeHTMLText.readingChunks.enumerated().map {
                ArticleBlock(id: $0.offset, kind: .paragraph, text: $0.element)
            }
        }
        return blocks
    }

    private static func attribute(in source: String, regex: NSRegularExpression?) -> String? {
        guard let regex else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let valueRange = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[valueRange])
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func articleURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("//") { return URL(string: "https:" + value) }
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        return URL(string: value, relativeTo: URL(string: "https://sukavinagroup.net"))?.absoluteURL
    }
}

@available(iOS 17.0, *)
final class NotificationManager {
    static let shared = NotificationManager()

    func requestAuthorizationIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func notifyNewArticles(_ items: [ContentItem], badge: Int) {
        for item in items.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = "Bài viết nội bộ mới"
            content.body = item.title
            content.sound = .default
            content.badge = NSNumber(value: badge)
            content.userInfo = ["articleId": item.id]
            let request = UNNotificationRequest(
                identifier: "article-\(item.id)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    func notifyAttendance(isCheckIn: Bool, time: String) {
        let action = isCheckIn ? "vào" : "ra"
        let content = UNMutableNotificationContent()
        content.title = "Chấm công \(action) thành công"
        content.body = "Giờ \(action) đã được ghi nhận lúc \(time)."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "attendance-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func clearBadge() {
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }
}

struct Dashboard: Codable {
    let employeeCode: String
    let fullName: String
    let role: String
    let remainingLeaveDays: Int
    let attendanceStatus: String
    let payrollStatus: String
    let name: String
    let workStartTime: String?
    let workEndTime: String?
    let attendanceCheckIn: String?
    let attendanceCheckOut: String?
    let attendanceClassification: String?
    let attendanceRecords: [AttendanceRecord]?
    let contentItems: [ContentItem]
}

struct AttendanceRecord: Codable, Identifiable {
    let id: String
    let punchedAt: String
    let source: String
    let originType: String?
    let machineNo: Int
}

enum AttendanceWidgetBridge {
    // Must match the App Group entitlement used by both the main app and the
    // widget extension. A mismatch prevents the widget from receiving the
    // WiseEye-backed attendance payload and its short-lived widget token.
    private static let originalAppGroup = "group.net.sukavinagroup.user"
    static let kind = "SukavinaAttendanceWidget"
    private static let stateKey = "attendance-widget-state"
    private static let tokenKey = "attendance-widget-token"

    private static var appGroup: String {
        let resignedGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
        return resignedGroups?.first(where: { $0.contains(originalAppGroup) }) ?? originalAppGroup
    }

    // Keep the App Group payload identical to the widget extension payload.
    // Extra dashboard metadata made older widget snapshots harder to invalidate.
    private struct State: Codable, Equatable {
        let checkIn: String?
        let checkOut: String?
    }

    static func update(from dashboard: Dashboard) {
        let state = State(
            checkIn: dashboard.attendanceCheckIn,
            checkOut: dashboard.attendanceCheckOut
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        let defaults = UserDefaults(suiteName: appGroup)
        if let existingData = defaults?.data(forKey: stateKey),
           let existing = try? JSONDecoder().decode(State.self, from: existingData),
           existing == state {
            return
        }
        defaults?.set(data, forKey: stateKey)
        defaults?.synchronize()
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    static func configure(token: String) {
        let defaults = UserDefaults(suiteName: appGroup)
        guard defaults?.string(forKey: tokenKey) != token else { return }
        defaults?.set(token, forKey: tokenKey)
        defaults?.synchronize()
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    static func clear() {
        let defaults = UserDefaults(suiteName: appGroup)
        let hasState = defaults?.object(forKey: stateKey) != nil
        let hasToken = defaults?.object(forKey: tokenKey) != nil
        guard hasState || hasToken else { return }
        defaults?.removeObject(forKey: stateKey)
        defaults?.removeObject(forKey: tokenKey)
        defaults?.synchronize()
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}

struct AttendanceMonth: Codable {
    let month: String
    let startTime: String?
    let endTime: String?
    let department: String?
    let days: [AttendanceDay]
}

struct AttendanceDay: Codable, Identifiable {
    let date: String
    let checkIn: String?
    let checkOut: String?
    let classification: String?
    let punchCount: Int
    let status: String?
    let statuses: [String]?
    let startTime: String?
    let endTime: String?
    let sources: [String]?
    let punches: [AttendancePunch]?
    var id: String { date }
}

struct AttendancePunch: Codable, Identifiable {
    let id: String
    let punchedAt: String
    let source: String
    let machineNo: Int
}

struct LoginBody: Encodable { let loginId: String; let password: String }
struct PushTokenRegistrationBody: Encodable { let token: String; let platform: String }
struct PushBadgeResetBody: Encodable { let token: String; let acknowledgedAt: Date }
struct ForgotPasswordRequestBody: Encodable { let employeeCode: String }
struct ForgotPasswordConfirmBody: Encodable {
    let employeeCode: String
    let code: String
    let newPassword: String
}
struct ForgotPasswordRequestResponse: Decodable {
    let message: String
    let maskedEmail: String?
    let expiresInMinutes: Int
}
struct RegisterBody: Encodable {
    let employeeCode: String
    let fullName: String
    let phoneNumber: String?
    let gmailEmail: String
    let password: String
}
struct VerifyBody: Encodable { let employeeCode: String; let gmailEmail: String; let code: String }
struct ResendBody: Encodable { let employeeCode: String; let gmailEmail: String }
struct DeleteAccountBody: Encodable { let confirmation: String }
struct PasswordChangeConfirmBody: Encodable { let code: String; let currentPassword: String?; let newPassword: String }
struct MessageResponse: Decodable { let message: String }
struct PasswordChangeRequestResponse: Decodable {
    let message: String
    let email: String
    let expiresInMinutes: Int
}
struct RegistrationResponse: Decodable {
    let id: String
    let employeeCode: String
    let message: String
    let requiresVerification: Bool
}
