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
        let isChoosingExtension: Bool

        init(endsAt: Date, extensionMinutes: Int, isChoosingExtension: Bool) {
            self.endsAt = endsAt
            self.extensionMinutes = extensionMinutes
            self.isChoosingExtension = isChoosingExtension
        }

        private enum CodingKeys: String, CodingKey {
            case endsAt, extensionMinutes, isChoosingExtension
        }

        // Activities started by an older app did not encode this flag.  Default
        // it to false so updating the app never makes an in-progress activity
        // fail to render.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            endsAt = try values.decode(Date.self, forKey: .endsAt)
            extensionMinutes = try values.decodeIfPresent(Int.self, forKey: .extensionMinutes) ?? 0
            isChoosingExtension = try values.decodeIfPresent(Bool.self, forKey: .isChoosingExtension) ?? false
        }
    }

    let bookingID: String
    let title: String
    let roomName: String
    let startsAt: Date
    let maximumExtensionMinutes: Int
    let extensionLimitReason: String
}
