import ActivityKit
import AppIntents
import Foundation
import Security

/// Runs in the app process when a Lock Screen Live Activity control is tapped.
/// It intentionally uses the existing API routes, so older mobile clients and
/// the server contract remain unchanged.
@available(iOS 17.0, *)
struct EndMeetingLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Kết thúc cuộc họp"
    static var openAppWhenRun = false

    @Parameter(title: "Mã cuộc họp") var bookingID: String

    init(bookingID: String) {
        self.bookingID = bookingID
    }

    init() {
        bookingID = ""
    }

    func perform() async throws -> some IntentResult {
        let result = try await MeetingLiveActivityAction.request(bookingID: bookingID, action: .end)
        await MeetingLiveActivityAction.updateActivity(bookingID: bookingID, endsAt: result.endsAt, endNow: true)
        NotificationCenter.default.post(name: Notification.Name("net.sukavinagroup.meeting-changed"), object: nil)
        return .result()
    }
}

@available(iOS 17.0, *)
struct ExtendMeetingLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Gia hạn cuộc họp"
    static var openAppWhenRun = false

    @Parameter(title: "Mã cuộc họp") var bookingID: String
    @Parameter(title: "Số phút gia hạn") var minutes: Int

    init(bookingID: String, minutes: Int) {
        self.bookingID = bookingID
        self.minutes = minutes
    }

    init() {
        bookingID = ""
        minutes = 5
    }

    func perform() async throws -> some IntentResult {
        let result = try await MeetingLiveActivityAction.request(
            bookingID: bookingID,
            action: .extend(minutes: minutes)
        )
        await MeetingLiveActivityAction.updateActivity(
            bookingID: bookingID,
            endsAt: result.endsAt,
            endNow: false,
            extensionMinutes: 0,
            isChoosingExtension: false
        )
        NotificationCenter.default.post(name: Notification.Name("net.sukavinagroup.meeting-changed"), object: nil)
        return .result()
    }
}

@available(iOS 17.0, *)
struct StartMeetingExtensionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Chọn thời gian gia hạn"
    static var openAppWhenRun = false

    @Parameter(title: "Mã cuộc họp") var bookingID: String

    init(bookingID: String) { self.bookingID = bookingID }
    init() { bookingID = "" }

    func perform() async throws -> some IntentResult {
        await MeetingLiveActivityAction.openExtensionChooser(bookingID: bookingID)
        return .result()
    }
}

@available(iOS 17.0, *)
struct AdjustMeetingExtensionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Điều chỉnh gia hạn"
    static var openAppWhenRun = false

    @Parameter(title: "Mã cuộc họp") var bookingID: String
    @Parameter(title: "Điều chỉnh") var delta: Int

    init(bookingID: String, delta: Int) {
        self.bookingID = bookingID
        self.delta = delta
    }

    init() {
        bookingID = ""
        delta = 0
    }

    func perform() async throws -> some IntentResult {
        await MeetingLiveActivityAction.adjustExtension(bookingID: bookingID, delta: delta)
        return .result()
    }
}

@available(iOS 17.0, *)
private enum MeetingLiveActivityAction {
    enum Action: Equatable { case end, extend(minutes: Int) }

    private struct Response: Decodable {
        let endsAt: String
    }

    private struct ExtendBody: Encodable {
        let minutes: Int
    }

    private static let baseURL = URL(string: "https://sukavinagroup.net/api/")!

    static func request(bookingID: String, action: Action) async throws -> Response {
        guard !bookingID.isEmpty, let token = accessToken() else {
            throw MeetingLiveActivityActionError.noSession
        }
        let path: String
        switch action {
        case .end: path = "me/meeting-bookings/\(bookingID)/end"
        case .extend: path = "me/meeting-bookings/\(bookingID)/extend"
        }
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if case let .extend(minutes) = action {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(ExtendBody(minutes: minutes))
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MeetingLiveActivityActionError.unavailable }
        guard (200..<300).contains(http.statusCode) else { throw MeetingLiveActivityActionError.rejected }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    static func updateActivity(
        bookingID: String,
        endsAt: String,
        endNow: Bool,
        extensionMinutes: Int = 0,
        isChoosingExtension: Bool = false
    ) async {
        guard let endDate = meetingDate(endsAt) else { return }
        for activity in Activity<MeetingLiveActivityAttributes>.activities where activity.attributes.bookingID == bookingID {
            if endNow {
                await activity.end(nil, dismissalPolicy: .immediate)
            } else {
                let state = MeetingLiveActivityAttributes.ContentState(
                    endsAt: endDate,
                    extensionMinutes: extensionMinutes,
                    isChoosingExtension: isChoosingExtension
                )
                await activity.update(ActivityContent(state: state, staleDate: endDate))
            }
        }
    }

    static func openExtensionChooser(bookingID: String) async {
        for activity in Activity<MeetingLiveActivityAttributes>.activities where activity.attributes.bookingID == bookingID {
            guard activity.attributes.maximumExtensionMinutes >= 5 else { continue }
            let state = MeetingLiveActivityAttributes.ContentState(
                endsAt: activity.content.state.endsAt,
                extensionMinutes: 5,
                isChoosingExtension: true
            )
            await activity.update(ActivityContent(state: state, staleDate: state.endsAt))
        }
    }

    static func adjustExtension(bookingID: String, delta: Int) async {
        for activity in Activity<MeetingLiveActivityAttributes>.activities where activity.attributes.bookingID == bookingID {
            let maximum = activity.attributes.maximumExtensionMinutes
            guard maximum >= 5 else { continue }
            let selected = min(max(activity.content.state.extensionMinutes + delta, 5), maximum)
            let state = MeetingLiveActivityAttributes.ContentState(
                endsAt: activity.content.state.endsAt,
                extensionMinutes: selected,
                isChoosingExtension: true
            )
            await activity.update(ActivityContent(state: state, staleDate: state.endsAt))
        }
    }

    private static func accessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.sukavinagroup.user",
            kSecAttrAccount as String: "access-token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func meetingDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

@available(iOS 17.0, *)
private enum MeetingLiveActivityActionError: LocalizedError {
    case noSession, unavailable, rejected

    var errorDescription: String? {
        switch self {
        case .noSession: "Không có phiên đăng nhập hợp lệ."
        case .unavailable: "Không thể kết nối máy chủ."
        case .rejected: "Không thể cập nhật cuộc họp."
        }
    }
}
