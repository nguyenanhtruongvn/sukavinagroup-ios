import XCTest
@testable import SukavinaShared

final class MeetingBookingDeduplicationTests: XCTestCase {
    private let nine = Date(timeIntervalSince1970: 1_792_000_000)

    func testAnonymousCopyOfAnIdentifiedBookingIsDropped() {
        let entries: [MeetingBookingDeduplication.Entry] = [
            .init(id: "", roomId: "a", start: nine.addingTimeInterval(0.4)),
            .init(id: "b1", roomId: "a", start: nine),
            .init(id: "", roomId: "b", start: nine),
            .init(id: "", roomId: "a", start: nine.addingTimeInterval(3600)),
        ]
        // Same room and start: dropped. Other room or other time: kept.
        XCTAssertEqual(MeetingBookingDeduplication.keptIndices(entries), [1, 2, 3])
    }

    func testIdentifiedBookingsAreAlwaysKept() {
        let entries: [MeetingBookingDeduplication.Entry] = [
            .init(id: "b1", roomId: "a", start: nine),
            .init(id: "b2", roomId: "a", start: nine),
            .init(id: "", roomId: "a", start: nil),
        ]
        XCTAssertEqual(MeetingBookingDeduplication.keptIndices(entries), [0, 1, 2])
    }
}
