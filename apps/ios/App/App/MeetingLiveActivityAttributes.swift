import ActivityKit
import Foundation

/// Kept in both the app and WidgetKit extension targets.  The attributes are
/// intentionally small so an APNs-triggered warning can be rendered reliably
/// on the Lock Screen and Dynamic Island.
struct MeetingLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let endsAt: Date
        let extensionMinutes: Int
        let isChoosingExtension: Bool
        let extensionError: String?
        /// "Kết thúc" was tapped once: show the confirmation instead of ending.
        let isConfirmingEnd: Bool

        init(
            endsAt: Date,
            extensionMinutes: Int,
            isChoosingExtension: Bool,
            extensionError: String? = nil,
            isConfirmingEnd: Bool = false
        ) {
            self.endsAt = endsAt
            self.extensionMinutes = extensionMinutes
            self.isChoosingExtension = isChoosingExtension
            self.extensionError = extensionError
            self.isConfirmingEnd = isConfirmingEnd
        }

        private enum CodingKeys: String, CodingKey {
            case endsAt, extensionMinutes, isChoosingExtension, extensionError, isConfirmingEnd
        }

        // Activities started by an older app did not encode this flag.  Default
        // it to false so updating the app never makes an in-progress activity
        // fail to render.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            endsAt = try values.decode(Date.self, forKey: .endsAt)
            extensionMinutes = try values.decodeIfPresent(Int.self, forKey: .extensionMinutes) ?? 0
            isChoosingExtension = try values.decodeIfPresent(Bool.self, forKey: .isChoosingExtension) ?? false
            extensionError = try values.decodeIfPresent(String.self, forKey: .extensionError)
            // Server pushes and older activities never carry it.
            isConfirmingEnd = try values.decodeIfPresent(Bool.self, forKey: .isConfirmingEnd) ?? false
        }
    }

    let bookingID: String
    let title: String
    let roomName: String
    let startsAt: Date
    let maximumExtensionMinutes: Int
    let extensionLimitReason: String
}
