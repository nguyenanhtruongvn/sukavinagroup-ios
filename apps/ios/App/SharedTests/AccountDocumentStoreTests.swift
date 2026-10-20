import XCTest
@testable import SukavinaShared

final class AccountDocumentStoreTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private let suiteName = "AccountDocumentStoreTests"

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountDocumentStoreTests-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(keepsInMemory: Bool = true) -> AccountDocumentStore {
        AccountDocumentStore(directory: directory, keepsInMemory: keepsInMemory, legacy: defaults)
    }

    func testStoredDocumentIsReadBackByANewInstance() {
        let store = makeStore()
        store.set(Data("dashboard".utf8), forKey: "native-dashboard-cache-00010")
        store.flush()
        XCTAssertEqual(makeStore().data(forKey: "native-dashboard-cache-00010"), Data("dashboard".utf8))
    }

    func testLegacyUserDefaultsDocumentIsMovedOnFirstRead() {
        defaults.set(Data("legacy".utf8), forKey: "cached-session-profile-v1")
        let store = makeStore()
        XCTAssertEqual(store.data(forKey: "cached-session-profile-v1"), Data("legacy".utf8))
        XCTAssertNil(defaults.data(forKey: "cached-session-profile-v1"))
        store.flush()
        XCTAssertEqual(makeStore().data(forKey: "cached-session-profile-v1"), Data("legacy".utf8))
    }

    func testRemoveAllDropsDocumentsAndQueuedWrites() {
        let store = makeStore()
        store.set(Data("a".utf8), forKey: "native-attendance-month-cache-v2-00010-2026-09")
        store.removeAll()
        store.flush()
        XCTAssertNil(store.data(forKey: "native-attendance-month-cache-v2-00010-2026-09"))
        XCTAssertNil(makeStore().data(forKey: "native-attendance-month-cache-v2-00010-2026-09"))
        XCTAssertTrue(store.allKeys().isEmpty)
    }

    func testRemoveWherePredicateKeepsOtherDocuments() {
        let store = makeStore()
        store.set(Data("1".utf8), forKey: "month-2025-01")
        store.set(Data("2".utf8), forKey: "month-2026-09")
        store.removeAll { $0 == "month-2025-01" }
        store.flush()
        XCTAssertNil(makeStore().data(forKey: "month-2025-01"))
        XCTAssertEqual(makeStore().data(forKey: "month-2026-09"), Data("2".utf8))
    }

    func testTrimKeepsTheMostRecentDocuments() {
        let store = makeStore(keepsInMemory: false)
        for index in 0..<5 {
            store.set(Data("\(index)".utf8), forKey: "revalidation-\(index)")
            store.flush()
            let url = directory.appendingPathComponent("revalidation-\(index)")
            try? FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000 + index))],
                ofItemAtPath: url.path
            )
        }
        store.trim(prefix: "revalidation-", keeping: 2)
        store.flush()
        XCTAssertEqual(Set(store.allKeys()), ["revalidation-3", "revalidation-4"])
    }
}
