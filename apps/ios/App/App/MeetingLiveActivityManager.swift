import ActivityKit
import Foundation

@available(iOS 17.0, *)
enum MeetingLiveActivityManager {
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
        Task {
            for activity in Activity<MeetingLiveActivityAttributes>.activities where activity.attributes.bookingID == bookingID {
                await activity.update(ActivityContent(state: state, staleDate: endsAt))
                return
            }
            do {
                _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: endsAt), pushType: nil)
            } catch {
                ConnectionDiagnostics.record("Meeting Live Activity failed: \(error.localizedDescription)")
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
