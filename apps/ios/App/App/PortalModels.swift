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

struct MeetingRoom: Codable, Identifiable, Equatable {
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

struct MeetingBooking: Codable, Identifiable, Equatable {
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
    /// `startsAt`/`endsAt` parsed once. Room cards, the timeline and the
    /// notification sheet compare them every minute; parsing the ISO strings
    /// there repeated the work for every booking on every redraw.
    let startDate: Date?
    let endDate: Date?

    private enum CodingKeys: String, CodingKey {
        case id, roomId, startsAt, endsAt, title, attendeeCount, status, isMine, isOwner, organizerName
    }

    init(
        id: String,
        roomId: String,
        startsAt: String,
        endsAt: String,
        title: String,
        attendeeCount: Int,
        status: String,
        isMine: Bool?,
        isOwner: Bool?,
        organizerName: String?
    ) {
        self.id = id
        self.roomId = roomId
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.title = title
        self.attendeeCount = attendeeCount
        self.status = status
        self.isMine = isMine
        self.isOwner = isOwner
        self.organizerName = organizerName
        startDate = VietnamTime.date(fromISO8601: startsAt)
        endDate = VietnamTime.date(fromISO8601: endsAt)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            roomId: try values.decode(String.self, forKey: .roomId),
            startsAt: try values.decode(String.self, forKey: .startsAt),
            endsAt: try values.decode(String.self, forKey: .endsAt),
            title: try values.decode(String.self, forKey: .title),
            attendeeCount: try values.decode(Int.self, forKey: .attendeeCount),
            status: try values.decode(String.self, forKey: .status),
            isMine: try values.decodeIfPresent(Bool.self, forKey: .isMine),
            isOwner: try values.decodeIfPresent(Bool.self, forKey: .isOwner),
            organizerName: try values.decodeIfPresent(String.self, forKey: .organizerName)
        )
    }
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

    /// Same names as on `MeetingBooking`; details are fetched one at a time.
    var startDate: Date? { VietnamTime.date(fromISO8601: startsAt) }
    var endDate: Date? { VietnamTime.date(fromISO8601: endsAt) }
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
    /// The default password is in use (absent in older server responses).
    let mustChangePassword: Bool

    private enum CodingKeys: String, CodingKey {
        case employeeCode, name, role, accountType, permissions, protected, mustChangePassword
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        employeeCode = try values.decode(String.self, forKey: .employeeCode)
        name = try values.decode(String.self, forKey: .name)
        role = try values.decodeIfPresent(String.self, forKey: .role) ?? "Nhân viên"
        accountType = try values.decodeIfPresent(String.self, forKey: .accountType) ?? "EMPLOYEE"
        permissions = try values.decodeIfPresent([String].self, forKey: .permissions) ?? []
        protected = try values.decodeIfPresent(Bool.self, forKey: .protected) ?? false
        mustChangePassword = try values.decodeIfPresent(Bool.self, forKey: .mustChangePassword) ?? false
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

struct Profile: Codable, Equatable {
    let id: String
    let employeeCode: String
    let name: String
    let role: String
    let accountType: String
    let permissions: [String]
    let protected: Bool
    let email: String?
    let managerFullName: String?
    let passwordChangedAt: Date?
    /// The company default password is in use: the server accepts nothing
    /// but changing it (or signing out) until it is changed.
    let mustChangePassword: Bool?
}

extension Profile {
    /// The demo account: it has no email, so its codes arrive in Notifications.
    var isDemoAccount: Bool {
        accountType == "DEMO" || employeeCode.uppercased() == "DEMO"
    }
}

enum SessionCache {
    private static let profileKey = "cached-session-profile-v1"
    private static let meetingRoomsPrefix = "cached-meeting-rooms-v1-"
    private static let meetingSchedulePrefix = "cached-meeting-schedule-v1-"
    private static let meetingScheduleSavedAtPrefix = "cached-meeting-schedule-saved-at-v1-"
    private static let meetingRoomOrderPrefix = "meeting-room-order-v1-"

    static func save(profile: Profile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        AccountDocumentStore.shared.set(data, forKey: profileKey)
    }

    static func loadProfile() -> Profile? {
        guard let data = AccountDocumentStore.shared.data(forKey: profileKey) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    static func saveMeetingRooms(_ rooms: [MeetingRoom], employeeCode: String) {
        guard let data = try? JSONEncoder().encode(rooms) else { return }
        AccountDocumentStore.shared.set(data, forKey: meetingRoomsPrefix + employeeCode)
    }

    static func loadMeetingRooms(employeeCode: String) -> [MeetingRoom] {
        guard let data = AccountDocumentStore.shared.data(forKey: meetingRoomsPrefix + employeeCode) else { return [] }
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
        AccountDocumentStore.shared.set(data, forKey: meetingSchedulePrefix + suffix)
        UserDefaults.standard.set(Date(), forKey: meetingScheduleSavedAtPrefix + suffix)
        pruneMeetingSchedulesOnce()
    }

    private static var didPruneMeetingSchedules = false

    /// One pair of keys is written per viewed day and nothing removed them.
    /// Once per launch, drop days more than 7 days in the past or 60 days in
    /// the future. Mirrors the Android meeting cache pruning.
    private static func pruneMeetingSchedulesOnce() {
        guard !didPruneMeetingSchedules else { return }
        didPruneMeetingSchedules = true
        let formatter = VietnamTime.dayKey
        let now = Date()
        let oldest = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let newest = now.addingTimeInterval(60 * 24 * 60 * 60)
        func outOfRange(_ key: String) -> Bool {
            // Keys end with "-yyyy-MM-dd".
            guard key.count > 10, let day = formatter.date(from: String(key.suffix(10))) else { return false }
            return day < oldest || day > newest
        }
        AccountDocumentStore.shared.removeAll { $0.hasPrefix(meetingSchedulePrefix) && outOfRange($0) }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where (key.hasPrefix(meetingSchedulePrefix) || key.hasPrefix(meetingScheduleSavedAtPrefix)) && outOfRange(key) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Removes the account's cached room catalogue and day schedules. The
    /// personal room order is a device preference and is kept.
    static func clearAccount(employeeCode: String) {
        AccountDocumentStore.shared.removeAll { key in
            key == meetingRoomsPrefix + employeeCode || key.hasPrefix(meetingSchedulePrefix + employeeCode + "-")
        }
        let defaults = UserDefaults.standard
        let dayPrefixes = [
            meetingSchedulePrefix + employeeCode + "-",
            meetingScheduleSavedAtPrefix + employeeCode + "-",
        ]
        for key in defaults.dictionaryRepresentation().keys
            where key == meetingRoomsPrefix + employeeCode || dayPrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
    }

    static func loadMeetingSchedule(day: String, employeeCode: String) -> MeetingScheduleResponse? {
        guard let data = AccountDocumentStore.shared.data(forKey: meetingSchedulePrefix + employeeCode + "-" + day) else { return nil }
        return try? JSONDecoder().decode(MeetingScheduleResponse.self, from: data)
    }

    static func meetingScheduleSavedAt(day: String, employeeCode: String) -> Date? {
        UserDefaults.standard.object(
            forKey: meetingScheduleSavedAtPrefix + employeeCode + "-" + day
        ) as? Date
    }

    static func clear() {
        AccountDocumentStore.shared.removeObject(forKey: profileKey)
    }
}

struct ContentItem: Codable, Identifiable, Equatable {
    let id: String
    let page: String
    let key: String
    let title: String
    let body: String
    let sortOrder: Int
    let published: Bool
    let createdAt: Date
    /// Short plain-text teaser for lists.
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

        // Only the teaser is needed for lists. The article's blocks are parsed
        // when it is opened; parsing every article on every dashboard decode
        // (including the launch cache restore) was wasted work.
        let text = body.safeHTMLText
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
    // Optional so older servers and cached menu JSON remain decodable.
    let managedEmployees: [ManagedMealEmployee]?
}

struct ManagedMealEmployee: Codable, Identifiable {
    let id: String
    let employeeCode: String
    let fullName: String
    let department: String
    let selection: String?
    let orderedByEmployeeId: String?
    let receivedAt: String?
}

struct MealAvailability: Codable {
    let water: Bool
    let vegetarian: Bool
}

struct MealQrIssueResponse: Decodable {
    let token: String
    let expiresAt: String
    let expiresInSeconds: Int
    let selectionCount: Int?
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
    // Additive fields: old single-portion QR responses do not contain these.
    let group: Bool?
    let confirmedCount: Int?
    let selectionCount: Int?
    let confirmedEmployees: [MealConfirmedEmployee]?
}

struct MealConfirmedEmployee: Decodable, Identifiable {
    var id: String { employeeCode }
    let employeeCode: String
    let fullName: String
    let department: String
    let choice: String
    let mealName: String
    let mealDate: String
    let receivedAt: String?
    let alreadyReceived: Bool?
}

struct MealSelectionBody: Encodable {
    let choice: String
}

struct MealSelectionWithManagedBody: Encodable {
    let choice: String
    let employeeIds: [String]
    let includeSelf: Bool
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
        return URL(string: value, relativeTo: URL(string: SukavinaServer.origin))?.absoluteURL
    }
}

/// Plain text from article HTML, for the parser's fallback (no block tags).
extension String {
    var safeHTMLText: String {
        let maximumCharacters = 750_000
        var output = String()
        output.reserveCapacity(Swift.min(count, maximumCharacters))
        var tag = String()
        var isInsideTag = false
        var written = 0

        for character in self {
            if written >= maximumCharacters {
                output.append("\n\n[Nội dung đã được rút gọn để bảo đảm ứng dụng hoạt động ổn định.]")
                break
            }
            if character == "<" {
                isInsideTag = true
                tag.removeAll(keepingCapacity: true)
                continue
            }
            if isInsideTag {
                if character == ">" {
                    isInsideTag = false
                    let name = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if name.hasPrefix("br") || name.hasPrefix("/p") || name.hasPrefix("/div") ||
                        name.hasPrefix("/li") || name.hasPrefix("/h") || name.hasPrefix("hr") {
                        if output.last != "\n" { output.append("\n") }
                    } else if name.hasPrefix("/td") || name.hasPrefix("/th") {
                        output.append(" | ")
                    } else if name.hasPrefix("li") {
                        if output.last != "\n" { output.append("\n") }
                        output.append("• ")
                    }
                } else if tag.count < 80 {
                    tag.append(character)
                }
                continue
            }
            output.append(character)
            written += 1
        }

        let decoded = output
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        var lines: [String] = []
        var previousWasEmpty = false
        for rawLine in decoded.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !previousWasEmpty && !lines.isEmpty { lines.append("") }
                previousWasEmpty = true
            } else {
                lines.append(line)
                previousWasEmpty = false
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var readingChunks: [String] {
        let maximumChunkLength = 1_800
        var chunks: [String] = []
        for paragraph in components(separatedBy: "\n\n") where !paragraph.isEmpty {
            var remainder = paragraph[...]
            while remainder.count > maximumChunkLength {
                let tentativeEnd = remainder.index(remainder.startIndex, offsetBy: maximumChunkLength)
                let split = remainder[..<tentativeEnd].lastIndex(of: " ") ?? tentativeEnd
                chunks.append(String(remainder[..<split]))
                remainder = remainder[split...].drop(while: { $0 == " " })
            }
            if !remainder.isEmpty { chunks.append(String(remainder)) }
        }
        return chunks.isEmpty ? [self] : chunks
    }
}

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

    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
    }
}

struct Dashboard: Codable {
    let employeeCode: String
    let fullName: String
    let role: String
    /// The employee's job title (chức vụ). Optional: `role` carries the same
    /// title for employees but "Quản trị viên" for administrators.
    var jobTitle: String? = nil
    let remainingLeaveDays: Double
    let remainingLeaveDaysExact: Double?
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
    /// Read by the widget: state this recent is used without a network request.
    private static let savedAtKey = "attendance-widget-state-saved-at"
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
        moveTokenToKeychainIfNeeded()
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
        defaults?.set(Date(), forKey: savedAtKey)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    /// The widget token lives in the shared Keychain group; the App Group
    /// copy is only a fallback for a build signed without that group.
    static func configure(token: String) {
        let defaults = UserDefaults(suiteName: appGroup)
        let current = WidgetTokenKeychain.load() ?? defaults?.string(forKey: tokenKey)
        if WidgetTokenKeychain.save(token) {
            defaults?.removeObject(forKey: tokenKey)
        } else {
            defaults?.set(token, forKey: tokenKey)
        }
        guard current != token else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    /// Versions before the Keychain group kept the token in the App Group plist.
    private static func moveTokenToKeychainIfNeeded() {
        guard WidgetTokenKeychain.isAvailable,
              let defaults = UserDefaults(suiteName: appGroup),
              let token = defaults.string(forKey: tokenKey), !token.isEmpty,
              WidgetTokenKeychain.save(token) else { return }
        defaults.removeObject(forKey: tokenKey)
    }

    static func clear() {
        let defaults = UserDefaults(suiteName: appGroup)
        let hasState = defaults?.object(forKey: stateKey) != nil
        let hasToken = defaults?.object(forKey: tokenKey) != nil || WidgetTokenKeychain.load() != nil
        guard hasState || hasToken else { return }
        WidgetTokenKeychain.delete()
        defaults?.removeObject(forKey: stateKey)
        defaults?.removeObject(forKey: savedAtKey)
        defaults?.removeObject(forKey: tokenKey)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}

struct AttendanceReport: Codable, Identifiable {
    let month: String
    let releasedAt: String?
    var id: String { month }
}

struct AiAssistantSettings: Codable {
    let mobileEnabled: Bool
    let updatedAt: String?
}

struct AiAssistantChatBody: Encodable {
    let message: String
    let contextId: String?
}

struct AiAssistantChatResponse: Decodable {
    let answer: String
    let contextId: String?
}

struct AiAssistantHistoryItem: Decodable {
    let role: String
    let content: String
    let contextId: String?
    let createdAt: String?
}

struct LoginBody: Encodable { let loginId: String; let password: String }
struct PushTokenRegistrationBody: Encodable { let token: String; let platform: String }
/// `POST auth/logout`: revokes this device's server session and detaches its
/// APNs and Live Activity push-to-start registrations. Nil fields are omitted.
struct LogoutBody: Encodable {
    let refreshToken: String?
    let pushToken: String?
    let liveActivityInstallationId: String?
}
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
struct DeleteAccountBody: Encodable { let confirmation: String }
struct PasswordChangeConfirmBody: Encodable { let code: String; let currentPassword: String?; let newPassword: String }
struct MessageResponse: Decodable { let message: String }
struct PasswordChangeRequestResponse: Decodable {
    let message: String
    let email: String
    let expiresInMinutes: Int
}
