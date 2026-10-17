import Foundation

/// Splits the reason of a submitted late / early / overtime request back into
/// its duration and free text. Those requests were sent with the duration
/// prepended ("Đi trễ: 30 phút. Kẹt xe"), so a resubmitted request must not
/// repeat it. Pure Foundation so it is unit-tested; mirrors Android
/// `requestPrefill`.
///
/// The duration is written by `DurationClock.title`: "30 phút", "2 giờ" or
/// "1 giờ 30 phút". Older requests, sent before the duration was chosen as
/// hours and minutes, used only the first two, with up to 60 minutes and
/// 24 hours; those still read back.
struct RequestReasonPrefill: Equatable {
    let reason: String
    /// The duration in minutes; nil when the reason has no duration prefix.
    let durationMinutes: Int?

    /// - Parameters:
    ///   - kindTitle: the request kind's display title ("Đi trễ").
    ///   - usesDuration: whether that kind carries a duration.
    init(reason rawReason: String, kindTitle: String, usesDuration: Bool) {
        let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = kindTitle + ": "
        guard usesDuration, reason.hasPrefix(prefix) else {
            self.init(reason: reason, durationMinutes: nil)
            return
        }
        let rest = reason.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: "."),
              let minutes = Self.minutes(in: String(rest[..<dot])) else {
            self.init(reason: reason, durationMinutes: nil)
            return
        }
        self.init(
            reason: rest[rest.index(after: dot)...].trimmingCharacters(in: .whitespacesAndNewlines),
            durationMinutes: minutes
        )
    }

    private init(reason: String, durationMinutes: Int?) {
        self.reason = reason
        self.durationMinutes = durationMinutes
    }

    /// "30 phút" (1...60), "2 giờ" (1...24) or "1 giờ 30 phút" (1...23 hours
    /// and 1...59 minutes), in minutes; nil for anything else.
    private static func minutes(in text: String) -> Int? {
        let words = text.split(separator: " ").map(String.init)
        switch words.count {
        case 2:
            guard let value = Int(words[0]) else { return nil }
            if words[1] == "phút", (1...60).contains(value) { return value }
            if words[1] == "giờ", (1...24).contains(value) { return value * 60 }
            return nil
        case 4:
            guard let hours = Int(words[0]), words[1] == "giờ", (1...23).contains(hours),
                  let minutes = Int(words[2]), words[3] == "phút", (1...59).contains(minutes) else { return nil }
            return hours * 60 + minutes
        default:
            return nil
        }
    }
}
