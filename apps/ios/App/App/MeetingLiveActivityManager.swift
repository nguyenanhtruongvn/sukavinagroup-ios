import ActivityKit
import Foundation
import Security

@available(iOS 17.0, *)
enum MeetingLiveActivityManager {
    private static var activityUpdatesTask: Task<Void, Never>?
    static func start(from userInfo: [AnyHashable: Any]) {
        guard userInfo["type"] as? String == "meeting_ending_soon",
              userInfo["is_owner"] as? String == "true",
              let bookingID = userInfo["booking_id"] as? String,
              let endsAt = date(userInfo["ends_at"] as? String),
              let startsAt = date(userInfo["starts_at"] as? String),
              endsAt > Date() else { return }

        let attributes = MeetingLiveActivityAttributes(
            bookingID: bookingID,
            title: nonEmpty(userInfo["meeting_title"] as? String) ?? "Cuộc họp",
            roomName: nonEmpty(userInfo["room_name"] as? String) ?? "Phòng họp",
            startsAt: startsAt,
            maximumExtensionMinutes: Int(userInfo["maximum_extension_minutes"] as? String ?? "") ?? 0,
            extensionLimitReason: userInfo["extension_limit_reason"] as? String ?? ""
        )
        let state = MeetingLiveActivityAttributes.ContentState(
            endsAt: endsAt,
            extensionMinutes: 0,
            isChoosingExtension: false
        )

        // iOS 17.2+ receives the same warning through ActivityKit
        // Push-to-Start. Creating another Activity from the ordinary APNs
        // reminder races that remote start and produces two lock-screen cards
        // for the same booking. On these systems the ordinary notification is
        // data/UI refresh only; ActivityKit owns creation.
        if #available(iOS 17.2, *) {
            Task {
                await removeDuplicateActivities(for: bookingID)
            }
            return
        }

        Task {
            for activity in Activity<MeetingLiveActivityAttributes>.activities where activity.attributes.bookingID == bookingID {
                await activity.update(ActivityContent(state: state, staleDate: endsAt))
                MeetingLiveActivityPushRegistration.observe(activity)
                MeetingLiveActivityExpiry.schedule(bookingID: bookingID, endsAt: endsAt)
                return
            }
            do {
                // A device-specific ActivityKit token lets the server end the
                // activity even while this app process is suspended or killed.
                let activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: endsAt),
                    pushType: .token
                )
                MeetingLiveActivityPushRegistration.observe(activity)
                MeetingLiveActivityExpiry.schedule(bookingID: bookingID, endsAt: endsAt)
            } catch {
                ConnectionDiagnostics.record("Meeting Live Activity failed: \(error.localizedDescription)")
            }
        }
    }

    static func update(bookingID: String, endsAt: Date) {
        Task {
            for activity in Activity<MeetingLiveActivityAttributes>.activities where activity.attributes.bookingID == bookingID {
                let current = activity.content.state
                let state = MeetingLiveActivityAttributes.ContentState(
                    endsAt: endsAt,
                    extensionMinutes: current.extensionMinutes,
                    isChoosingExtension: false
                )
                await activity.update(
                    ActivityContent(state: state, staleDate: endsAt)
                )
                MeetingLiveActivityExpiry.schedule(
                    bookingID: bookingID,
                    endsAt: endsAt
                )
            }
        }
    }

    static func end(bookingID: String) {
        Task {
            for activity in Activity<MeetingLiveActivityAttributes>.activities where activity.attributes.bookingID == bookingID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    static func restorePushTokenObservers() {
        Task {
            await removeAllDuplicateActivities()
        }

        for activity in Activity<MeetingLiveActivityAttributes>.activities {
            MeetingLiveActivityPushRegistration.observe(activity)
        }

        // A push-to-start notification can launch the process in the
        // background without making the app active. Observe ActivityKit's
        // activity stream from launch so remotely started activities can
        // immediately upload their per-activity update/end token.
        guard activityUpdatesTask == nil else { return }
        activityUpdatesTask = Task {
            for await activity in Activity<MeetingLiveActivityAttributes>.activityUpdates {
                await removeDuplicateActivities(
                    for: activity.attributes.bookingID,
                    keeping: activity.id
                )
                MeetingLiveActivityPushRegistration.observe(activity)
                MeetingLiveActivityExpiry.schedule(
                    bookingID: activity.attributes.bookingID,
                    endsAt: activity.content.state.endsAt
                )
            }
        }
    }

    private static func removeAllDuplicateActivities() async {
        let activities = Activity<MeetingLiveActivityAttributes>.activities
        let grouped = Dictionary(grouping: activities) { $0.attributes.bookingID }
        for (bookingID, matches) in grouped where matches.count > 1 {
            let keepID = matches.first?.id
            await removeDuplicateActivities(for: bookingID, keeping: keepID)
        }
    }

    private static func removeDuplicateActivities(
        for bookingID: String,
        keeping keepID: String? = nil
    ) async {
        let matches = Activity<MeetingLiveActivityAttributes>.activities.filter {
            $0.attributes.bookingID == bookingID
        }
        guard matches.count > 1 else { return }

        let canonicalID = keepID ?? matches.first?.id
        for activity in matches where activity.id != canonicalID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// ActivityKit tokens are distinct from ordinary APNs device tokens and are
/// scoped to one Live Activity.  The stream can provide a rotated token, so it
/// remains observed for the lifetime of each active activity.
@available(iOS 17.0, *)
private enum MeetingLiveActivityPushRegistration {
    private static let baseURL = URL(string: "https://sukavinagroup.net/api/")!
    private static var observedActivityIDs = Set<String>()

    static func observe(_ activity: Activity<MeetingLiveActivityAttributes>) {
        // Re-upload the current token whenever lifecycle/session restoration
        // asks us to reconcile. A previous attempt may have happened before
        // the authenticated Keychain session was available.
        if let token = activity.pushToken {
            Task {
                await upload(token: token, bookingID: activity.attributes.bookingID)
            }
        }

        // Only the long-lived async stream needs de-duplication.
        guard observedActivityIDs.insert(activity.id).inserted else { return }
        Task {
            for await token in activity.pushTokenUpdates {
                await upload(token: token, bookingID: activity.attributes.bookingID)
            }
        }
    }

    private static func upload(token: Data, bookingID: String) async {
        guard !bookingID.isEmpty, let accessToken = accessToken() else { return }
        let tokenValue = token.map { String(format: "%02x", $0) }.joined()
        guard !tokenValue.isEmpty else { return }

        var request = URLRequest(
            url: URL(string: "me/meeting-bookings/\(bookingID)/live-activity-token", relativeTo: baseURL)!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": tokenValue])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                ConnectionDiagnostics.record("Live Activity push token upload was rejected")
                return
            }
        } catch {
            ConnectionDiagnostics.record("Live Activity push token upload failed: \(error.localizedDescription)")
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
}
