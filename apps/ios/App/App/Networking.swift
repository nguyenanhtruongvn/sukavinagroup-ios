import UIKit
import os
import SwiftUI
import Security
import UserNotifications
import Network
import LocalAuthentication
import WidgetKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import WebKit

struct APIErrorPayload: Decodable {
    let message: APIMessage
}

enum APIMessage: Decodable {
    case text(String)
    case list([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .text(value)
        } else {
            self = .list(try container.decode([String].self))
        }
    }

    var text: String {
        switch self {
        case .text(let value): return value
        case .list(let values): return values.joined(separator: "\n")
        }
    }
}

enum NetworkError: LocalizedError {
    case invalidResponse
    case server(String)
    case offline
    case cellularRestricted
    case invalidCredentials
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Máy chủ trả về dữ liệu không hợp lệ."
        case .server(let message): return message
        case .offline: return "Không thể kết nối đến máy chủ. Hãy kiểm tra Wi-Fi hoặc dữ liệu di động rồi thử lại."
        case .cellularRestricted: return "iPhone đang không cấp đường truyền di động cho Sukavina. Vào Cài đặt > Di động, bật Sukavina rồi mở lại ứng dụng."
        case .invalidCredentials: return "MSNV hoặc mật khẩu không chính xác."
        case .unauthorized: return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại."
        }
    }
}

enum NetworkSessions {
    static let api: URLSession = makeSession(resourceTimeout: 90)
    static let events: URLSession = makeSession(resourceTimeout: 24 * 60 * 60)

    private static func makeSession(resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.default
        // Do not let requests sit invisibly in URLSession while iOS changes
        // interfaces. The API client already owns retry/fallback policy and
        // can recover faster from a Wi-Fi <-> cellular handoff.
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration)
    }
}

extension Notification.Name {
    /// Any HTTP response proves that URLSession has a working transport path,
    /// even when NWPathMonitor is briefly stale during Wi-Fi/cellular handoff.
    static let sukavinaTransportReachable = Notification.Name("net.sukavinagroup.transport-reachable")
    /// Posted with the new `LoginResponse` as `object` after APIClient renewed
    /// an expired access token, so SessionStore uses it for later requests.
    static let sukavinaSessionRefreshed = Notification.Name("net.sukavinagroup.session-refreshed")
}

/// Connection diagnostics for debugging transport problems.
///
/// Entries were previously appended to UserDefaults several times per HTTP
/// request. Nothing read them back, every write rewrote the whole array and
/// posted `UserDefaults.didChangeNotification` (which re-applies the app
/// appearance). They now go to the unified log, with details redacted outside
/// a debugger, plus a small in-memory ring buffer.
/// Connection events go to the unified log (Console.app) only. An in-memory
/// copy used to be kept for every request but was never read.
enum ConnectionDiagnostics {
    private static let legacyKey = "connection-diagnostics-v1"
    private static let logger = Logger(subsystem: "net.sukavinagroup.user", category: "connection")
    /// Removes what versions that persisted diagnostics left in UserDefaults.
    private static let removeLegacyEntries: Void = UserDefaults.standard.removeObject(forKey: legacyKey)

    static func record(_ message: String) {
        _ = removeLegacyEntries
        logger.debug("\(message, privacy: .private)")
    }
}

/// Temporary instrumentation for the "a sheet closes itself while the employee
/// is using it" report. `ConnectionDiagnostics` goes to the unified log at
/// debug level, which is not retained and needs a Mac to read; these lines go
/// to a file the employee exports from Tài khoản instead.
///
/// The exported file is handled by people, so record UI flow only: screen
/// names, lifecycle transitions and event kinds. Never a token, a password, an
/// employee name, a meeting title or a message body.
///
/// Remove this type and its call sites once the cause is confirmed.
enum UIFlowLog {
    static let fileName = "debug.log"
    private static let queue = DispatchQueue(label: "net.sukavinagroup.ui-flow-log")
    /// Roughly an hour of heavy use; halved when it fills so a long session
    /// keeps its most recent lines rather than its first ones.
    private static let maximumBytes = 512 * 1024

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(fileName)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func record(_ event: String, _ detail: String = "") {
        let line = "\(stamp.string(from: Date()))  \(event)\(detail.isEmpty ? "" : "  \(detail)")\n"
        queue.async { append(line) }
    }

    /// One header line per launch, so an exported file shows which build and
    /// which iOS produced it (the iOS 17 and iOS 18+ paths differ).
    static func recordLaunch() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        record("app.launch", "ios=\(UIDevice.current.systemVersion) app=\(version)(\(build))")
    }

    /// True when nothing has been recorded since the last clear, so the
    /// account screen can say so instead of exporting an empty file.
    static var isEmpty: Bool {
        queue.sync {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int else {
                return true
            }
            return size == 0
        }
    }

    /// `completion` runs on the main queue once the file is gone, so the
    /// caller can refresh what it shows.
    static func clear(completion: @escaping () -> Void = {}) {
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
            DispatchQueue.main.async(execute: completion)
        }
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
        trimIfNeeded(url)
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > maximumBytes,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let kept = String(contents.suffix(maximumBytes / 2))
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Records a SwiftUI sheet's own lifecycle. `onDisappear` without a matching
/// user action in the lines above it is the signal we are looking for.
struct SheetFlowLogger: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content
            .onAppear { UIFlowLog.record("sheet.appear", name) }
            .onDisappear { UIFlowLog.record("sheet.disappear", name) }
    }
}

extension View {
    func logsSheetFlow(_ name: String) -> some View {
        modifier(SheetFlowLogger(name: name))
    }
}

/// Monotonic sign-out counter. A token refresh that started before a sign-out
/// must not persist its result afterwards, or the signed-out account would be
/// restored on the next launch.
enum SessionGeneration {
    private static let lock = NSLock()
    private static var value = 0

    static var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    static func invalidate() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }
}

actor SessionRefreshCoordinator {
    private var running: Task<LoginResponse, Error>?

    func run(_ operation: @escaping () async throws -> LoginResponse) async throws -> LoginResponse {
        if let running { return try await running.value }
        let task = Task { try await operation() }
        running = task
        defer { running = nil }
        return try await task.value
    }
}

/// The last body and ETag of an authenticated GET, for `If-None-Match`.
private struct RevalidationEntry {
    let etag: String
    let body: Data

    init(etag: String, body: Data) {
        self.etag = etag
        self.body = body
    }

    init?(stored: Data) {
        guard let newline = stored.firstIndex(of: 0x0A),
              let etag = String(data: stored[stored.startIndex..<newline], encoding: .utf8),
              !etag.isEmpty else { return nil }
        self.etag = etag
        body = Data(stored[stored.index(after: newline)...])
    }

    var stored: Data { Data(etag.utf8) + Data([0x0A]) + body }
}

final class APIClient {
    static let shared = APIClient()
    /// Bodies kept for conditional GETs; one per path, most recent first.
    private static let revalidationLimit = 64
    private let baseURL = URL(string: "https://sukavinagroup.net/api/")
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let raw = try container.decode(String.self)
            // Shared, thread-safe formatters: creating them per decoded date
            // field was the most expensive part of decoding large responses.
            if let date = VietnamTime.date(fromISO8601: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(raw)"
            )
        }
        return decoder
    }()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let refreshCoordinator = SessionRefreshCoordinator()

    func request<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String = "GET",
        token: String? = nil,
        body: Body? = nil,
        allowSessionRefresh: Bool = true,
        allowTransportFallback: Bool = false
    ) async throws -> Response {
        guard let baseURL, let url = URL(string: path, relativeTo: baseURL) else {
            throw NetworkError.invalidResponse
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        if path == "auth/login" {
            urlRequest.timeoutInterval = 15
        } else if path == "me/ai-assistant/chat" {
            // The server may perform document lookup plus a local LLM request.
            // Give that single user-initiated call enough time to finish while
            // keeping ordinary API requests on the tighter transport timeout.
            urlRequest.timeoutInterval = 85
        } else {
            urlRequest.timeoutInterval = 20
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        // Authenticated reads are revalidated with the last body's ETag: the
        // server answers 304 without a body when nothing changed (the usual
        // case after returning to the app or a realtime event about another
        // area). The body is kept in the account's protected document store,
        // never in URLCache. A conditional request must not send no-cache,
        // which makes the server skip the comparison.
        let revalidationKey = method.uppercased() == "GET" && token != nil ? "revalidation-" + path : nil
        let revalidation = revalidationKey
            .flatMap { AccountDocumentStore.revalidation.data(forKey: $0) }
            .flatMap(RevalidationEntry.init(stored:))
        if let revalidation {
            urlRequest.setValue(revalidation.etag, forHTTPHeaderField: "If-None-Match")
        } else {
            urlRequest.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        }
        urlRequest.setValue("ios", forHTTPHeaderField: "X-Sukavina-Client")
        // The caller already owns the current in-memory session token.
        // Reading Keychain synchronously here can block CFNetwork requests on
        // re-signed/upgraded iOS installs and can also resurrect a stale token
        // during an account switch. Keychain is persistence, not live state.
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try encoder.encode(body)
        }

        var data: Data
        var response: URLResponse
        let retryable = ["GET", "HEAD"].contains(method.uppercased())
        // There is no alternate host any more: the former nip.io fallback
        // was a hostname whose DNS a third party controls, and sign-in
        // (password) and token refresh were sent there on network errors.
        let primaryHost = url.host ?? "unknown"
        ConnectionDiagnostics.record("API primary start: \(method) \(primaryHost)/\(path)")
        do {
            (data, response) = try await load(urlRequest, retryable: retryable, path: path, hostRole: "primary")
        } catch is CancellationError {
            // SwiftUI can cancel an obsolete refresh task. That is not a
            // connectivity failure and must not trigger a fallback request.
            ConnectionDiagnostics.record("API primary cancelled: \(method) \(primaryHost)/\(path)")
            throw CancellationError()
        } catch let error as URLError where error.code == .dataNotAllowed || error.code == .internationalRoamingOff {
            ConnectionDiagnostics.record("API primary cellular denied: \(error.code.rawValue) \(error.localizedDescription)")
            throw NetworkError.cellularRestricted
        } catch {
            let code = (error as? URLError)?.code.rawValue
            let codeText = code.map(String.init) ?? "n/a"
            ConnectionDiagnostics.record("API primary failed: code=\(codeText) \(error.localizedDescription)")
            throw NetworkError.offline
        }

        guard let http = response as? HTTPURLResponse else {
            ConnectionDiagnostics.record("API invalid non-HTTP response: \(path)")
            throw NetworkError.invalidResponse
        }
        // Treat the actual HTTP transport as authoritative. On some iOS/carrier
        // combinations NWPathMonitor can transiently report .unsatisfied while
        // CFNetwork is already sending and receiving normally over cellular.
        NotificationCenter.default.post(name: .sukavinaTransportReachable, object: nil)
        let responseHost = http.url?.host ?? "unknown"
        ConnectionDiagnostics.record("API response: \(http.statusCode) host=\(responseHost) path=\(path) bytes=\(data.count)")
        var status = http.statusCode
        if status == 304, let revalidation {
            // Not modified: the stored body is the current one.
            data = revalidation.body
            status = 200
        } else if (200..<300).contains(status),
                  let revalidationKey,
                  let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
            AccountDocumentStore.revalidation.set(RevalidationEntry(etag: etag, body: data).stored, forKey: revalidationKey)
            AccountDocumentStore.revalidation.trim(prefix: "revalidation-", keeping: Self.revalidationLimit)
        }
        guard (200..<300).contains(status) else {
            if token == nil && path == "auth/login" && (http.statusCode == 401 || http.statusCode == 403) {
                throw NetworkError.invalidCredentials
            }
            if token == nil && path == "auth/refresh" && (http.statusCode == 401 || http.statusCode == 403) {
                throw NetworkError.unauthorized
            }
            if token != nil,
               allowSessionRefresh,
               http.statusCode == 401,
               let refreshToken = KeychainStore.loadRefreshToken() {
                let generation = SessionGeneration.current
                let refreshed = try await refreshCoordinator.run {
                    try await self.request(
                        "auth/refresh",
                        method: "POST",
                        body: RefreshSessionBody(refreshToken: refreshToken),
                        allowSessionRefresh: false
                    )
                }
                // The user signed out while the refresh was in flight.
                guard generation == SessionGeneration.current else {
                    throw NetworkError.unauthorized
                }
                KeychainStore.save(token: refreshed.accessToken)
                if !refreshed.refreshToken.isEmpty {
                    KeychainStore.save(refreshToken: refreshed.refreshToken)
                }
                if !refreshed.widgetToken.isEmpty {
                    AttendanceWidgetBridge.configure(token: refreshed.widgetToken)
                }
                // Without this, SessionStore kept sending the expired token and
                // every later request paid for a 401 plus a refresh.
                NotificationCenter.default.post(name: .sukavinaSessionRefreshed, object: refreshed)
                return try await request(
                    path,
                    method: method,
                    token: refreshed.accessToken,
                    body: body,
                    allowSessionRefresh: false,
                    allowTransportFallback: allowTransportFallback
                )
            }
            if token != nil && http.statusCode == 401 {
                throw NetworkError.unauthorized
            }
            let payload = try? decoder.decode(APIErrorPayload.self, from: data)
            throw NetworkError.server(payload?.message.text ?? "Yêu cầu không thành công (\(http.statusCode)).")
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            ConnectionDiagnostics.record(
                "API decode failed: path=\(path) type=\(String(describing: Response.self)) bytes=\(data.count) error=\(error.localizedDescription)"
            )
            throw NetworkError.invalidResponse
        }
    }

    private func load(
        _ request: URLRequest,
        retryable: Bool,
        path: String,
        hostRole: String
    ) async throws -> (Data, URLResponse) {
        // One quick retry is enough before the alternate HTTPS host is tried.
        // Multiple 30-second waits made cellular failures look like a frozen app.
        let delays: [UInt64] = retryable ? [0, 400_000_000] : [0]
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            do {
                return try await NetworkSessions.api.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                // -999 is also emitted by CFNetwork during some interface
                // handoffs. Only treat it as task cancellation when Swift
                // actually cancelled the task; otherwise let fallback recover.
                if Task.isCancelled {
                    ConnectionDiagnostics.record("API \(hostRole) task cancelled: path=\(path)")
                    throw CancellationError()
                }
                ConnectionDiagnostics.record("API \(hostRole) transport cancelled during handoff: path=\(path)")
                guard attempt < delays.count - 1 else { throw error }
            } catch {
                guard attempt < delays.count - 1, shouldRetry(error) else { throw error }
                let code = (error as? URLError)?.code.rawValue
                ConnectionDiagnostics.record("API \(hostRole) retry \(attempt + 1)/\(delays.count - 1): code=\(code.map(String.init) ?? "n/a") path=\(path)")
            }
        }
        throw NetworkError.offline
    }

    private func shouldRetry(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .cancelled, .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .resourceUnavailable, .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }

    func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        token: String? = nil
    ) async throws -> Response {
        try await request(path, method: method, token: token, body: Optional<EmptyBody>.none)
    }
}

struct EmptyBody: Encodable {}

enum KeychainStore {
    private static let service = "net.sukavinagroup.user"
    private static let accessTokenAccount = "access-token"
    private static let refreshTokenAccount = "refresh-token"

    static func save(token: String) {
        save(token, account: accessTokenAccount)
    }

    static func save(refreshToken: String) {
        save(refreshToken, account: refreshTokenAccount)
    }

    private static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Updating an existing item is materially safer on upgraded/re-signed
        // installs than deleting it first. A Security.framework delete can
        // wait on protected-data services and leave a successful login stuck
        // before the app transitions to its signed-in screen.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus != errSecSuccess {
                ConnectionDiagnostics.record("Keychain add failed: status=\(addStatus) account=\(account)")
            }
            return
        }

        ConnectionDiagnostics.record("Keychain update failed: status=\(updateStatus) account=\(account)")
    }

    static func loadToken() -> String? {
        load(account: accessTokenAccount)
    }

    static func loadRefreshToken() -> String? {
        load(account: refreshTokenAccount)
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Token retrieval must never wait for a Keychain authentication
            // dialog while the app is restoring its session.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        clear(accessToken: nil)
    }

    /// Deletes only the signed-out session.  If a new sign-in writes a newer
    /// access token first, its credentials remain intact.
    static func clear(accessToken expectedAccessToken: String?) {
        if let expectedAccessToken,
           load(account: accessTokenAccount) != expectedAccessToken {
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum BiometricKeychain {
    private static let service = "net.sukavinagroup.biometric"
    private static let account = "biometric-refresh-token-v2"
    private static let legacyAccount = "biometric-access-token"

    static func save(refreshToken: String) -> Bool {
        clear()
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else { return false }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(refreshToken.utf8),
            kSecAttrAccessControl as String: access
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func load(prompt: String) -> String? {
        let context = LAContext()
        context.localizedCancelTitle = "Hủy"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            kSecUseOperationPrompt as String: prompt
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        let serviceQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(serviceQuery as CFDictionary)
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }
}

/// Keychain items survive uninstalling the app; UserDefaults do not. The
/// first launch of a new installation therefore removes the session,
/// biometric and widget items a previous installation left behind, so the
/// next person to install the app on this phone is not signed in as the
/// previous user. An app update keeps its UserDefaults and is unaffected.
enum InstallationGuard {
    private static let markerKey = "installation-marker-v1"

    static func forgetPreviousInstallationIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }
        // Before the first unlock after a reboot neither the Keychain nor
        // UserDefaults can be read reliably: decide on a later launch.
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        // Versions before this marker leave other keys behind: an update of
        // such a version is an existing installation, not a new one.
        let existing = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        if existing.isEmpty {
            KeychainStore.clear()
            BiometricKeychain.clear()
            WidgetTokenKeychain.delete()
        }
        defaults.set(true, forKey: markerKey)
    }
}

enum BiometricPreferences {
    private static let key = "biometric-login-enabled"
    private static let employeeCodeKey = "biometric-login-employee-code"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static var employeeCode: String? {
        get { UserDefaults.standard.string(forKey: employeeCodeKey) }
        set { UserDefaults.standard.set(newValue, forKey: employeeCodeKey) }
    }
}
