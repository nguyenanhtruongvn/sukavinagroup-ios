import ActivityKit
import AppIntents
import Foundation
import Security

/// Runs in the app process when a Lock Screen Live Activity control is tapped.
/// It intentionally uses the existing API routes, so older mobile clients and
/// the server contract remain unchanged.
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

        // Publish the server-confirmed end time to the app process before
        // waiting for ActivityKit to animate/dismiss the island. The room
        // schedule can redraw immediately while the system finishes removing
        // the Live Activity.
        MeetingLiveActivityAction.saveEndedMeeting(bookingID: bookingID, endsAt: result.endsAt)
        MeetingLiveActivityAction.notifyAppOfMeetingStateChange()
        NotificationCenter.default.post(
            name: Notification.Name("net.sukavinagroup.meeting-changed"),
            object: nil
        )

        await MeetingLiveActivityAction.updateActivity(
            bookingID: bookingID,
            endsAt: result.endsAt,
            endNow: true
        )
        return .result()
    }
}

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
        do {
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
            MeetingLiveActivityAction.notifyAppOfMeetingStateChange()
            NotificationCenter.default.post(name: Notification.Name("net.sukavinagroup.meeting-changed"), object: nil)
        } catch {
            // Keep the selector visible so the organiser can reduce the
            // requested time after learning about the next meeting.
            await MeetingLiveActivityAction.showExtensionError(
                bookingID: bookingID,
                message: error.localizedDescription
            )
        }
        return .result()
    }
}

/// First tap on "Kết thúc": ask for confirmation in the activity itself.
/// Ending is irreversible and the button sits next to the extension controls.
struct RequestEndMeetingConfirmationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Xác nhận kết thúc cuộc họp"
    static var openAppWhenRun = false

    @Parameter(title: "Mã cuộc họp") var bookingID: String

    init(bookingID: String) { self.bookingID = bookingID }
    init() { bookingID = "" }

    func perform() async throws -> some IntentResult {
        await MeetingLiveActivityAction.setConfirmingEnd(bookingID: bookingID, true)
        return .result()
    }
}

/// "Hủy" on the end confirmation: back to the normal controls.
struct CancelEndMeetingConfirmationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Tiếp tục cuộc họp"
    static var openAppWhenRun = false

    @Parameter(title: "Mã cuộc họp") var bookingID: String

    init(bookingID: String) { self.bookingID = bookingID }
    init() { bookingID = "" }

    func perform() async throws -> some IntentResult {
        await MeetingLiveActivityAction.setConfirmingEnd(bookingID: bookingID, false)
        return .result()
    }
}

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

private enum MeetingLiveActivityAction {
    enum Action: Equatable { case end, extend(minutes: Int) }

    struct Response: Decodable {
        let endsAt: String
    }

    private struct EndedMeeting: Codable {
        let bookingID: String
        let endsAt: String
    }

    private struct ExtendBody: Encodable {
        let minutes: Int
    }

    private struct ErrorPayload: Decodable {
        let message: Message
    }

    private enum Message: Decodable {
        case text(String), list([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .list(try container.decode([String].self))
            }
        }

        var text: String {
            switch self {
            case .text(let value): value
            case .list(let values): values.joined(separator: " ")
            }
        }
    }

    private static let baseURL = URL(string: "https://sukavinagroup.net/api/")!
    private static var appGroup: String {
        let original = "group.net.sukavinagroup.user"
        let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
        return groups?.first(where: { $0.contains(original) }) ?? original
    }
    private static let endedMeetingKey = "meeting-live-activity-ended-booking"

    static func request(bookingID: String, action: Action) async throws -> Response {
        guard !bookingID.isEmpty, let token = keychainValue(account: "access-token") else {
            throw MeetingLiveActivityActionError.noSession
        }
        do {
            return try await send(bookingID: bookingID, action: action, token: token)
        } catch MeetingLiveActivityActionError.expiredToken {
            // The activity appears near the end of a meeting, often hours after
            // the app last ran, so the access token may have expired. Renew it
            // once, as the app does, then retry. (This file is also compiled
            // into the widget extension, so it cannot use APIClient.)
            guard let renewed = await renewAccessToken() else {
                throw MeetingLiveActivityActionError.noSession
            }
            return try await send(bookingID: bookingID, action: action, token: renewed)
        }
    }

    private static func send(bookingID: String, action: Action, token: String) async throws -> Response {
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
        if http.statusCode == 401 { throw MeetingLiveActivityActionError.expiredToken }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorPayload.self, from: data))?.message.text
            throw MeetingLiveActivityActionError.rejected(message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    static func updateActivity(
        bookingID: String,
        endsAt: String,
        endNow: Bool,
        extensionMinutes: Int = 0,
        isChoosingExtension: Bool = false
    ) async {
        guard let endDate = VietnamTime.date(fromISO8601: endsAt) else { return }
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
                MeetingLiveActivityExpiry.schedule(bookingID: bookingID, endsAt: endDate)
            }
        }
    }

    static func saveEndedMeeting(bookingID: String, endsAt: String) {
        let result = EndedMeeting(bookingID: bookingID, endsAt: endsAt)
        guard let data = try? JSONEncoder().encode(result) else { return }
        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.set(data, forKey: endedMeetingKey)
        // Flush before sending the cross-process notification; otherwise an
        // already-open room schedule can receive the signal before the shared
        // value is visible to it.
        defaults?.synchronize()
    }

    /// Widget/AppIntent code runs in a different process from the app.  A
    /// Darwin notification makes an already-open timeline re-read the shared
    /// server-confirmed end time immediately; the App Group value remains the
    /// fallback for older app builds and when the app is not running.
    static func notifyAppOfMeetingStateChange() {
        let notification = CFNotificationName(
            "net.sukavinagroup.meeting-live-activity-state-changed" as CFString
        )
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            notification,
            nil,
            nil,
            true
        )
    }

    static func setConfirmingEnd(bookingID: String, _ confirming: Bool) async {
        for activity in Activity<MeetingLiveActivityAttributes>.activities where activity.attributes.bookingID == bookingID {
            let current = activity.content.state
            let state = MeetingLiveActivityAttributes.ContentState(
                endsAt: current.endsAt,
                extensionMinutes: confirming ? 0 : current.extensionMinutes,
                isChoosingExtension: confirming ? false : current.isChoosingExtension,
                extensionError: nil,
                isConfirmingEnd: confirming
            )
            await activity.update(ActivityContent(state: state, staleDate: state.endsAt))
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
            let proposed = activity.content.state.extensionMinutes + delta
            let selected = min(max(proposed, 5), maximum)
            // The server supplied this ceiling when the warning was created.
            // Give immediate feedback at the +5 tap instead of waiting for the
            // confirmation request that would be rejected for the same reason.
            let extensionError: String?
            if delta > 0, proposed > maximum {
                let reason = activity.attributes.extensionLimitReason
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                extensionError = reason.isEmpty
                    ? "Đã đạt giới hạn gia hạn"
                    : reason.replacingOccurrences(
                        of: "cuộc họp tiếp theo lúc ",
                        with: "Họp sau ",
                        options: [.caseInsensitive]
                    )
            } else {
                extensionError = nil
            }
            let state = MeetingLiveActivityAttributes.ContentState(
                endsAt: activity.content.state.endsAt,
                extensionMinutes: selected,
                isChoosingExtension: true,
                extensionError: extensionError
            )
            await activity.update(ActivityContent(state: state, staleDate: state.endsAt))
        }
    }

    static func showExtensionError(bookingID: String, message: String) async {
        for activity in Activity<MeetingLiveActivityAttributes>.activities where activity.attributes.bookingID == bookingID {
            let limitReason = activity.attributes.extensionLimitReason.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayMessage = limitReason.isEmpty || message.localizedCaseInsensitiveContains(limitReason)
                ? message
                : "\(message) \(limitReason)"
            let state = MeetingLiveActivityAttributes.ContentState(
                endsAt: activity.content.state.endsAt,
                extensionMinutes: activity.content.state.extensionMinutes,
                isChoosingExtension: true,
                extensionError: displayMessage
            )
            await activity.update(ActivityContent(state: state, staleDate: state.endsAt))
        }
    }

    private struct RefreshBody: Encodable { let refreshToken: String }
    private struct RefreshedSession: Decodable {
        let accessToken: String
        let refreshToken: String?
    }

    /// Exchanges the stored refresh token for a new access token and stores
    /// it where the app reads it. Returns nil when signed out or rejected.
    private static func renewAccessToken() async -> String? {
        guard let refreshToken = keychainValue(account: "refresh-token") else { return nil }
        var request = URLRequest(url: URL(string: "auth/refresh", relativeTo: baseURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RefreshBody(refreshToken: refreshToken))
        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let session = try? JSONDecoder().decode(RefreshedSession.self, from: result.0) else { return nil }
        guard updateKeychainValue(session.accessToken, account: "access-token") else { return nil }
        // The server may rotate the refresh token, as APIClient expects: keep
        // the new one, or the app's next refresh would use a spent token and
        // sign the user out.
        if let rotated = session.refreshToken, !rotated.isEmpty {
            _ = updateKeychainValue(rotated, account: "refresh-token")
        }
        // In the app process SessionStore adopts the new tokens (and keeps
        // the Face ID copy of the refresh token current), as after an
        // APIClient refresh. Elsewhere nobody observes it.
        NotificationCenter.default.post(
            name: Notification.Name("net.sukavinagroup.session-refreshed"),
            object: nil,
            userInfo: ["accessToken": session.accessToken, "refreshToken": session.refreshToken ?? ""]
        )
        return session.accessToken
    }

    /// Replaces an existing item only: if the user signed out meanwhile the
    /// item is gone and must not be recreated.
    private static func updateKeychainValue(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.sukavinagroup.user",
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        return status == errSecSuccess
    }

    private static func keychainValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.sukavinagroup.user",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// `staleDate` only tells the system that content is stale; it does not end an
/// activity.  Schedule a best-effort close while the host process remains
/// alive, then validate the activity's *current* end time before closing so an
/// earlier timer cannot end a meeting that was subsequently extended.
enum MeetingLiveActivityExpiry {
    /// One pending close per booking: every update (extension, refresh)
    /// used to add another sleeping task for the same activity.
    private static var pending: [String: Task<Void, Never>] = [:]
    private static let lock = NSLock()

    static func schedule(bookingID: String, endsAt: Date) {
        let delay = max(0, endsAt.timeIntervalSinceNow)
        let task = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await endIfExpired(bookingID: bookingID)
        }
        lock.lock()
        let previous = pending.updateValue(task, forKey: bookingID)
        lock.unlock()
        previous?.cancel()
    }

    static func removeExpiredActivities() {
        Task { await endIfExpired() }
    }

    private static func endIfExpired(bookingID: String? = nil) async {
        let now = Date()
        for activity in Activity<MeetingLiveActivityAttributes>.activities {
            guard bookingID == nil || activity.attributes.bookingID == bookingID,
                  activity.content.state.endsAt <= now else {
                continue
            }
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

private enum MeetingLiveActivityActionError: LocalizedError {
    case noSession, unavailable, rejected(String?), expiredToken

    var errorDescription: String? {
        switch self {
        case .noSession, .expiredToken: "Phiên đăng nhập đã hết hạn. Hãy mở ứng dụng để đăng nhập lại."
        case .unavailable: "Không thể kết nối máy chủ."
        case .rejected(let message): message ?? "Không thể gia hạn vì có cuộc họp kế tiếp hoặc lịch đã thay đổi."
        }
    }
}
