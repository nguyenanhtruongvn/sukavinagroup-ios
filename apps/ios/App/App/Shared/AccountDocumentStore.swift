import Foundation

/// The signed-in account's cached documents (dashboard, attendance, requests,
/// notifications, menu, meetings, profile, revalidation bodies), one file each.
///
/// They used to live in `UserDefaults.standard`: one plist that iOS loads
/// whole into memory and rewrites on every save (the dashboard alone carries
/// article HTML), that is included in iCloud/computer backups, and that keeps
/// whatever a sign-out could not name by employee code. Here each document is
/// - a file under Application Support excluded from backups, written
///   atomically with `completeUntilFirstUserAuthentication` protection (the
///   widget and push handling also run while the device is locked),
/// - mirrored in memory after its first read when `keepsInMemory` is set
///   (callers read on the main thread), and written on a serial queue,
/// - moved over from `UserDefaults` on first read of its key (legacy data).
///
/// Everything belongs to one account, so sign-out calls `removeAll()`.
/// Mirrors the Android `DocumentStore`.
final class AccountDocumentStore: @unchecked Sendable {
    static let shared = AccountDocumentStore(name: "AccountDocuments", keepsInMemory: true)
    /// Last response body and ETag per URL for conditional GETs (304).
    static let revalidation = AccountDocumentStore(name: "Revalidation", keepsInMemory: false, legacy: nil)

    private let directory: URL
    private let keepsInMemory: Bool
    private let legacy: UserDefaults?
    private let lock = NSLock()
    private var memory: [String: Data] = [:]
    /// Keys known to have no document (avoids repeated disk lookups).
    private var absent: Set<String> = []
    /// Bumped by `removeAll()` so writes queued before it are dropped.
    private var generation = 0
    private let writer: DispatchQueue

    init(directory: URL, keepsInMemory: Bool, legacy: UserDefaults?) {
        self.directory = directory
        self.keepsInMemory = keepsInMemory
        self.legacy = legacy
        writer = DispatchQueue(label: "net.sukavinagroup.documents.\(directory.lastPathComponent)", qos: .utility)
    }

    convenience init(name: String, keepsInMemory: Bool, legacy: UserDefaults? = .standard) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(directory: base.appendingPathComponent(name, isDirectory: true), keepsInMemory: keepsInMemory, legacy: legacy)
    }

    func data(forKey key: String) -> Data? {
        lock.lock()
        if let value = memory[key] { lock.unlock(); return value }
        if absent.contains(key) { lock.unlock(); return nil }
        lock.unlock()

        if let value = try? Data(contentsOf: fileURL(for: key)) {
            remember(value, forKey: key)
            return value
        }
        // A document from a version that kept it in UserDefaults: move it.
        if let legacy, let value = legacy.data(forKey: key) {
            set(value, forKey: key)
            legacy.removeObject(forKey: key)
            return value
        }
        lock.lock()
        absent.insert(key)
        lock.unlock()
        return nil
    }

    func set(_ value: Data, forKey key: String) {
        lock.lock()
        if keepsInMemory { memory[key] = value }
        absent.remove(key)
        let generation = generation
        lock.unlock()
        writer.async { [self] in
            guard isCurrent(generation) else { return }
            write(value, to: fileURL(for: key))
        }
    }

    func removeObject(forKey key: String) {
        removeAll { $0 == key }
        legacy?.removeObject(forKey: key)
    }

    func removeAll(where shouldRemove: (String) -> Bool) {
        let keys = allKeys().filter(shouldRemove)
        guard !keys.isEmpty else { return }
        lock.lock()
        keys.forEach { memory[$0] = nil; absent.insert($0) }
        let generation = generation
        lock.unlock()
        writer.async { [self] in
            guard isCurrent(generation) else { return }
            keys.forEach { try? FileManager.default.removeItem(at: fileURL(for: $0)) }
        }
    }

    /// Sign-out: every document belongs to the account that is leaving.
    func removeAll() {
        lock.lock()
        memory.removeAll()
        absent.removeAll()
        generation += 1
        lock.unlock()
        // Synchronous: a read right after sign-out must not find the files.
        writer.sync { try? FileManager.default.removeItem(at: directory) }
    }

    /// Keeps the `keeping` most recently written documents whose key has `prefix`.
    func trim(prefix: String, keeping: Int) {
        writer.async { [self] in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            let matching = files.filter { key(for: $0)?.hasPrefix(prefix) == true }
            guard matching.count > keeping else { return }
            let sorted = matching.sorted { modified($0) > modified($1) }
            for url in sorted.dropFirst(keeping) {
                try? FileManager.default.removeItem(at: url)
                if let key = key(for: url) {
                    lock.lock(); memory[key] = nil; absent.insert(key); lock.unlock()
                }
            }
        }
    }

    /// Keys of every stored document (files plus pending in-memory writes).
    func allKeys() -> [String] {
        var keys = Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .compactMap { $0.removingPercentEncoding })
        lock.lock()
        keys.formUnion(memory.keys)
        keys.subtract(absent)
        lock.unlock()
        return Array(keys)
    }

    /// Waits for queued writes (tests, and before reading files directly).
    func flush() {
        writer.sync {}
    }

    private func remember(_ value: Data, forKey key: String) {
        guard keepsInMemory else { return }
        lock.lock()
        memory[key] = value
        lock.unlock()
    }

    private func isCurrent(_ value: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }

    private func write(_ value: Data, to url: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var directoryURL = directory
            try? directoryURL.setResourceValues(excluded)
        }
        #if os(iOS)
        try? value.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? value.write(to: url, options: .atomic)
        #endif
    }

    private func fileURL(for key: String) -> URL {
        let name = key.addingPercentEncoding(withAllowedCharacters: Self.fileNameCharacters) ?? key
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    private func key(for url: URL) -> String? {
        url.lastPathComponent.removingPercentEncoding
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static let fileNameCharacters: CharacterSet = {
        var characters = CharacterSet.alphanumerics
        characters.insert(charactersIn: "-_.")
        return characters
    }()
}
