import ActivityKit
import Foundation

/// Kept in both the app and WidgetKit extension targets.  The attributes are
/// intentionally small so an APNs-triggered warning can be rendered reliably
/// on the Lock Screen and Dynamic Island.
@available(iOS 17.0, *)
struct MeetingLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let endsAt: Date
        let extensionMinutes: Int
    }

    let bookingID: String
    let title: String
    let roomName: String
    let startsAt: Date
    let maximumExtensionMinutes: Int
    let extensionLimitReason: String
}
