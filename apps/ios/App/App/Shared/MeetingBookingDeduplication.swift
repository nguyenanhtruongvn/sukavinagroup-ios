import Foundation

/// An optimistic booking is shown without an id until the server confirms
/// it. Once the identified booking for the same room and start time exists,
/// the anonymous copy is dropped. Indexed by room and second, so it is linear
/// in the number of bookings. Pure Foundation so it is unit-tested.
enum MeetingBookingDeduplication {
    struct Entry {
        let id: String
        let roomId: String
        let start: Date?
    }

    /// Indices of the entries to keep, in their original order.
    static func keptIndices(_ entries: [Entry]) -> [Int] {
        var identifiedStarts = Set<String>()
        for known in entries where !known.id.isEmpty {
            guard let start = known.start else { continue }
            let second = Int(start.timeIntervalSince1970.rounded())
            // Neighbouring seconds keep the "less than one second apart" tolerance.
            for offset in -1...1 { identifiedStarts.insert("\(known.roomId)|\(second + offset)") }
        }
        return entries.indices.filter { index in
            let entry = entries[index]
            guard entry.id.isEmpty, let start = entry.start else { return true }
            return !identifiedStarts.contains("\(entry.roomId)|\(Int(start.timeIntervalSince1970.rounded()))")
        }
    }
}
