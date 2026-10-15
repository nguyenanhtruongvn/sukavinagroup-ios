import Foundation

/// Splits the reason of a submitted late / early / overtime request back into
/// its duration and free text. Those requests were sent with the duration
/// prepended ("Đi trễ: 30 phút. Kẹt xe"), so a resubmitted request must not
/// repeat it. Pure Foundation so it is unit-tested; mirrors Android
/// `requestPrefill`.
struct RequestReasonPrefill: Equatable {
    let reason: String
    /// Nil when the reason has no duration prefix.
    let durationValue: Int?
    let durationIsHours: Bool

    /// - Parameters:
    ///   - kindTitle: the request kind's display title ("Đi trễ").
    ///   - usesDuration: whether that kind carries a duration.
    init(reason rawReason: String, kindTitle: String, usesDuration: Bool) {
        let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = kindTitle + ": "
        guard usesDuration, reason.hasPrefix(prefix) else {
            self.init(reason: reason, durationValue: nil, durationIsHours: false)
            return
        }
        let parts = reason.dropFirst(prefix.count).split(separator: " ", maxSplits: 1)
        let unitAndReason = parts.count == 2 ? String(parts[1]) : ""
        let isHours = unitAndReason.hasPrefix("giờ.")
        guard let value = parts.first.flatMap({ Int($0) }),
              isHours || unitAndReason.hasPrefix("phút."),
              value >= 1, value <= (isHours ? 24 : 60) else {
            self.init(reason: reason, durationValue: nil, durationIsHours: false)
            return
        }
        let text = unitAndReason.drop(while: { $0 != "." }).dropFirst()
        self.init(
            reason: text.trimmingCharacters(in: .whitespacesAndNewlines),
            durationValue: value,
            durationIsHours: isHours
        )
    }

    private init(reason: String, durationValue: Int?, durationIsHours: Bool) {
        self.reason = reason
        self.durationValue = durationValue
        self.durationIsHours = durationIsHours
    }
}
