import UIKit
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
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration)
    }
}

enum ConnectionDiagnostics {
    private static let key = "connection-diagnostics-v1"
    private static let lock = NSLock()
    private static let maximumEntries = 160

    static func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        var entries = UserDefaults.standard.stringArray(forKey: key) ?? []
        let timestamp = ISO8601DateFormatter().string(from: Date())
        entries.append("[\(timestamp)] \(message)")
        UserDefaults.standard.set(Array(entries.suffix(maximumEntries)), forKey: key)
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

@available(iOS 17.0, *)
final class APIClient {
    static let shared = APIClient()
    private let baseURL = URL(string: "https://sukavinagroup.net/api/")
    private let fallbackBaseURL = URL(string: "https://157-10-201-110.nip.io/api/")
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let raw = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) {
                return date
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: raw) {
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
        allowSessionRefresh: Bool = true
    ) async throws -> Response {
        guard let baseURL, let url = URL(string: path, relativeTo: baseURL) else {
            throw NetworkError.invalidResponse
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 25
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        let effectiveToken = token.flatMap { _ in KeychainStore.loadToken() } ?? token
        if let effectiveToken {
            urlRequest.setValue("Bearer \(effectiveToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try encoder.encode(body)
        }

        var data: Data
        var response: URLResponse
        let primaryHost = url.host ?? "unknown"
        ConnectionDiagnostics.record("API primary start: \(method) \(primaryHost)/\(path)")
        do {
            (data, response) = try await NetworkSessions.api.data(for: urlRequest)
        } catch let error as URLError where error.code == .dataNotAllowed || error.code == .internationalRoamingOff {
            ConnectionDiagnostics.record("API primary cellular denied: \(error.code.rawValue) \(error.localizedDescription)")
            throw NetworkError.cellularRestricted
        } catch {
            let code = (error as? URLError)?.code.rawValue
            let codeText = code.map(String.init) ?? "n/a"
            ConnectionDiagnostics.record("API primary failed: code=\(codeText) \(error.localizedDescription)")
            guard let fallbackBaseURL,
                  let fallbackURL = URL(string: path, relativeTo: fallbackBaseURL) else {
                throw NetworkError.offline
            }
            urlRequest.url = fallbackURL
            let fallbackHost = fallbackURL.host ?? "unknown"
            ConnectionDiagnostics.record("API fallback start: \(method) \(fallbackHost)/\(path)")
            do {
                (data, response) = try await NetworkSessions.api.data(for: urlRequest)
            } catch let fallbackError as URLError where fallbackError.code == .dataNotAllowed || fallbackError.code == .internationalRoamingOff {
                ConnectionDiagnostics.record("API fallback cellular denied: \(fallbackError.code.rawValue) \(fallbackError.localizedDescription)")
                throw NetworkError.cellularRestricted
            } catch {
                let code = (error as? URLError)?.code.rawValue
                let codeText = code.map(String.init) ?? "n/a"
                ConnectionDiagnostics.record("API fallback failed: code=\(codeText) \(error.localizedDescription)")
                throw NetworkError.offline
            }
        }

        guard let http = response as? HTTPURLResponse else {
            ConnectionDiagnostics.record("API invalid non-HTTP response: \(path)")
            throw NetworkError.invalidResponse
        }
        let responseHost = http.url?.host ?? "unknown"
        ConnectionDiagnostics.record("API response: \(http.statusCode) host=\(responseHost) path=\(path) bytes=\(data.count)")
        guard (200..<300).contains(http.statusCode) else {
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
                let refreshed = try await refreshCoordinator.run {
                    try await self.request(
                        "auth/refresh",
                        method: "POST",
                        body: RefreshSessionBody(refreshToken: refreshToken),
                        allowSessionRefresh: false
                    )
                }
                KeychainStore.save(token: refreshed.accessToken)
                if !refreshed.refreshToken.isEmpty {
                    KeychainStore.save(refreshToken: refreshed.refreshToken)
                }
                if !refreshed.widgetToken.isEmpty {
                    AttendanceWidgetBridge.configure(token: refreshed.widgetToken)
                }
                return try await request(
                    path,
                    method: method,
                    token: refreshed.accessToken,
                    body: body,
                    allowSessionRefresh: false
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
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
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
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
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
