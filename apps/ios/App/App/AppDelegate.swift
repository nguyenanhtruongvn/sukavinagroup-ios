import UIKit
import SwiftUI
import Security
import UserNotifications
import Network
import LocalAuthentication
import WidgetKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: SukavinaAppView())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

private enum AppTheme {
    static let red = Color(red: 0.91, green: 0.12, blue: 0.16)
    static let deepRed = Color(red: 0.45, green: 0.04, blue: 0.07)
    static let ink = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1) : UIColor(red: 0.906, green: 0.914, blue: 0.929, alpha: 1)
    })
    static let card = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1) : UIColor.white
    })
    static let muted = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.66, green: 0.65, blue: 0.68, alpha: 1) : UIColor(red: 0.36, green: 0.35, blue: 0.38, alpha: 1)
    })
    static let loginAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.45, green: 0.04, blue: 0.07, alpha: 0.72) : UIColor.white
    })
    static let field = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.055) : UIColor.white
    })
    static let fieldBorder = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor(red: 0.63, green: 0.66, blue: 0.71, alpha: 0.42)
    })
    static let cardBorder = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor(red: 0.31, green: 0.34, blue: 0.39, alpha: 0.12)
    })
    static let biometricFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.075) : UIColor.white
    })
    static let biometricForeground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white : UIColor(red: 0.68, green: 0.07, blue: 0.10, alpha: 1)
    })
}

private struct AdaptiveGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    var tint: Color? = nil
    var interactive = false
    var legacyFill = AppTheme.card
    var legacyOpacity = 1.0

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint).interactive(interactive),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background(legacyFill.opacity(legacyOpacity))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

private extension View {
    func adaptiveGlassSurface(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        interactive: Bool = false,
        legacyFill: Color = AppTheme.card,
        legacyOpacity: Double = 1
    ) -> some View {
        modifier(
            AdaptiveGlassSurface(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive,
                legacyFill: legacyFill,
                legacyOpacity: legacyOpacity
            )
        )
    }

}

private struct APIErrorPayload: Decodable {
    let message: APIMessage
}

private enum APIMessage: Decodable {
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

private enum NetworkError: LocalizedError {
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
        case .offline: return "Không thể kết nối máy chủ. Vui lòng kiểm tra Internet."
        case .cellularRestricted: return "iPhone đang không cấp đường truyền di động cho Sukavina. Vào Cài đặt > Di động, bật Sukavina rồi mở lại ứng dụng."
        case .invalidCredentials: return "Mã nhân viên hoặc mật khẩu không chính xác."
        case .unauthorized: return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại."
        }
    }
}

private enum NetworkSessions {
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

private enum ConnectionDiagnostics {
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

private final class APIClient {
    static let shared = APIClient()
    private let baseURL = URL(string: "https://sukavinagroup.net/api/")!
    private let fallbackBaseURL = URL(string: "https://157-10-201-110.nip.io/api/")!
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func request<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String = "GET",
        token: String? = nil,
        body: Body? = nil,
        allowSessionRefresh: Bool = true
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
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
            guard let fallbackURL = URL(string: path, relativeTo: fallbackBaseURL) else {
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
               (http.statusCode == 401 || http.statusCode == 403),
               let refreshToken = KeychainStore.loadRefreshToken() {
                let refreshed: LoginResponse = try await request(
                    "auth/refresh",
                    method: "POST",
                    body: RefreshSessionBody(refreshToken: refreshToken),
                    allowSessionRefresh: false
                )
                KeychainStore.save(token: refreshed.accessToken)
                KeychainStore.save(refreshToken: refreshed.refreshToken)
                AttendanceWidgetBridge.configure(token: refreshed.widgetToken)
                return try await request(
                    path,
                    method: method,
                    token: refreshed.accessToken,
                    body: body,
                    allowSessionRefresh: false
                )
            }
            if token != nil && (http.statusCode == 401 || http.statusCode == 403) {
                throw NetworkError.unauthorized
            }
            let payload = try? decoder.decode(APIErrorPayload.self, from: data)
            throw NetworkError.server(payload?.message.text ?? "Yêu cầu không thành công (\(http.statusCode)).")
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
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

private struct EmptyBody: Encodable {}

private enum KeychainStore {
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

private enum BiometricKeychain {
    private static let service = "net.sukavinagroup.biometric"
    private static let account = "biometric-access-token"

    static func save(token: String) -> Bool {
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
            kSecValueData as String: Data(token.utf8),
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum BiometricPreferences {
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

private struct UserSummary: Codable {
    let employeeCode: String
    let name: String
    let role: String
    let accountType: String
    let permissions: [String]
    let protected: Bool
}

private struct LoginResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let widgetToken: String
    let user: UserSummary
}

private struct RefreshSessionBody: Encodable {
    let refreshToken: String
}

private struct Profile: Decodable {
    let id: String
    let employeeCode: String
    let name: String
    let role: String
    let accountType: String
    let permissions: [String]
    let protected: Bool
    let email: String?
    let passwordChangedAt: Date?
}

private struct ContentItem: Decodable, Identifiable {
    let id: String
    let page: String
    let key: String
    let title: String
    let body: String
    let sortOrder: Int
    let published: Bool
    let createdAt: Date
    let plainBody: String
    let articleBlocks: [ArticleBlock]
    let preview: String

    private enum CodingKeys: String, CodingKey {
        case id, page, key, title, body, sortOrder, published, createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        page = try values.decode(String.self, forKey: .page)
        key = try values.decode(String.self, forKey: .key)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        sortOrder = try values.decode(Int.self, forKey: .sortOrder)
        published = try values.decode(Bool.self, forKey: .published)
        createdAt = try values.decode(Date.self, forKey: .createdAt)

        let text = body.safeHTMLText
        plainBody = text
        articleBlocks = HTMLArticleParser.parse(body)
        preview = text.count > 145 ? String(text.prefix(145)) + "…" : text
    }
}

private struct MenuDay: Decodable {
    let dayIndex: Int
    let dayName: String
    let featured: String
    let savoryMain: String
    let savorySide: String
    let vegetable: String
    let soup: String
    let vegetarianMain: String
    let vegetarianSide: String
    let overtime: String
}

private struct TodayMenu: Decodable {
    let date: String
    let day: MenuDay
    let selection: String?
    let receivedAt: String?
    let orderingOpen: Bool
    let orderingCutoff: String
}

private struct MealSelectionBody: Encodable {
    let choice: String
}

private struct ArticleBlock: Identifiable {
    enum Kind {
        case heading(Int)
        case paragraph
        case listItem
        case image(URL?, String)
        case tableRow
        case question
    }

    let id: Int
    let kind: Kind
    let text: String
}

private enum HTMLArticleParser {
    private static let blockRegex = try! NSRegularExpression(
        pattern: #"(?is)<(h[1-6]|p|li|blockquote|summary|tr)\b[^>]*>(.*?)</\1\s*>|<img\b[^>]*>"#
    )
    private static let sourceRegex = try! NSRegularExpression(pattern: #"(?i)\bsrc\s*=\s*["']([^"']+)["']"#)
    private static let altRegex = try! NSRegularExpression(pattern: #"(?i)\b(?:alt|title)\s*=\s*["']([^"']+)["']"#)

    static func parse(_ html: String) -> [ArticleBlock] {
        let source = html.count > 750_000 ? String(html.prefix(750_000)) : html
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = blockRegex.matches(in: source, range: range)
        var blocks: [ArticleBlock] = []
        blocks.reserveCapacity(matches.count)

        for match in matches {
            guard let fullRange = Range(match.range, in: source) else { continue }
            let fragment = String(source[fullRange])
            if fragment.lowercased().hasPrefix("<img") {
                let src = attribute(in: fragment, regex: sourceRegex)
                let alt = attribute(in: fragment, regex: altRegex) ?? "Hình ảnh bài viết"
                blocks.append(ArticleBlock(id: blocks.count, kind: .image(articleURL(src), alt), text: alt))
                continue
            }

            guard let tagRange = Range(match.range(at: 1), in: source),
                  let bodyRange = Range(match.range(at: 2), in: source) else { continue }
            let tag = source[tagRange].lowercased()
            let text = String(source[bodyRange]).safeHTMLText
            guard !text.isEmpty else { continue }
            let kind: ArticleBlock.Kind
            if tag.hasPrefix("h"), let level = Int(tag.dropFirst()) {
                kind = .heading(level)
            } else if tag == "li" {
                kind = .listItem
            } else if tag == "tr" {
                kind = .tableRow
            } else if tag == "summary" {
                kind = .question
            } else {
                kind = .paragraph
            }

            for chunk in text.readingChunks {
                blocks.append(ArticleBlock(id: blocks.count, kind: kind, text: chunk))
            }
        }

        if blocks.isEmpty {
            return source.safeHTMLText.readingChunks.enumerated().map {
                ArticleBlock(id: $0.offset, kind: .paragraph, text: $0.element)
            }
        }
        return blocks
    }

    private static func attribute(in source: String, regex: NSRegularExpression) -> String? {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let valueRange = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[valueRange])
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func articleURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("//") { return URL(string: "https:" + value) }
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        return URL(string: value, relativeTo: URL(string: "https://sukavinagroup.net"))?.absoluteURL
    }
}

private final class NotificationManager {
    static let shared = NotificationManager()

    func requestAuthorizationIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func notifyNewArticles(_ items: [ContentItem]) {
        for item in items.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = "Bài viết nội bộ mới"
            content.body = item.title
            content.sound = .default
            content.badge = NSNumber(value: items.count)
            content.userInfo = ["articleId": item.id]
            let request = UNNotificationRequest(
                identifier: "article-\(item.id)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    func clearBadge() {
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }
}

private struct Dashboard: Decodable {
    let employeeCode: String
    let fullName: String
    let role: String
    let remainingLeaveDays: Int
    let attendanceStatus: String
    let payrollStatus: String
    let name: String
    let attendanceRecords: [AttendanceRecord]?
    let contentItems: [ContentItem]
}

private struct AttendanceRecord: Decodable, Identifiable {
    let id: String
    let punchedAt: String
    let source: String
    let originType: String?
    let machineNo: Int
}

private enum AttendanceWidgetBridge {
    private static let originalAppGroup = "group.net.sukavinagroup.portal"
    static let kind = "SukavinaAttendanceWidget"
    private static let stateKey = "attendance-widget-state"
    private static let tokenKey = "attendance-widget-token"

    private static var appGroup: String {
        let resignedGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
        return resignedGroups?.first(where: { $0.contains(originalAppGroup) }) ?? originalAppGroup
    }

    private struct State: Codable {
        let employeeName: String
        let status: String
        let checkIn: String?
        let checkOut: String?
        let updatedAt: Date
    }

    static func update(from dashboard: Dashboard) {
        let records = dashboard.attendanceRecords ?? []
        let state = State(
            employeeName: dashboard.name,
            status: dashboard.attendanceStatus,
            checkIn: records.last?.punchedAt,
            checkOut: records.count > 1 ? records.first?.punchedAt : nil,
            updatedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.set(data, forKey: stateKey)
        defaults?.synchronize()
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    static func configure(token: String) {
        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.set(token, forKey: tokenKey)
        defaults?.synchronize()
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    static func clear() {
        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.removeObject(forKey: stateKey)
        defaults?.removeObject(forKey: tokenKey)
        defaults?.synchronize()
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}

private struct AttendanceMonth: Decodable {
    let month: String
    let startTime: String?
    let endTime: String?
    let department: String?
    let days: [AttendanceDay]
}

private struct AttendanceDay: Decodable, Identifiable {
    let date: String
    let checkIn: String?
    let checkOut: String?
    let punchCount: Int
    let status: String?
    let statuses: [String]?
    let startTime: String?
    let endTime: String?
    let sources: [String]?
    let punches: [AttendancePunch]?
    var id: String { date }
}

private struct AttendancePunch: Decodable, Identifiable {
    let id: String
    let punchedAt: String
    let source: String
    let machineNo: Int
}

private struct AttendanceMonthOption: Identifiable {
    let value: String
    let title: String
    let label: String
    var id: String { value }
}

private struct LoginBody: Encodable { let loginId: String; let password: String }
private struct RegisterBody: Encodable {
    let employeeCode: String
    let fullName: String
    let phoneNumber: String?
    let gmailEmail: String
    let password: String
}
private struct VerifyBody: Encodable { let employeeCode: String; let gmailEmail: String; let code: String }
private struct ResendBody: Encodable { let employeeCode: String; let gmailEmail: String }
private struct DeleteAccountBody: Encodable { let password: String; let confirmation: String }
private struct PasswordChangeConfirmBody: Encodable { let code: String; let newPassword: String }
private struct MessageResponse: Decodable { let message: String }
private struct PasswordChangeRequestResponse: Decodable {
    let message: String
    let email: String
    let expiresInMinutes: Int
}
private struct RegistrationResponse: Decodable {
    let id: String
    let employeeCode: String
    let message: String
    let requiresVerification: Bool
}

@MainActor
private final class SessionStore: ObservableObject {
    enum State {
        case restoring
        case signedOut
        case signedIn
    }

    @Published var state: State = .restoring
    @Published var profile: Profile?
    @Published var dashboard: Dashboard?
    @Published var errorMessage: String?
    @Published var errorTitle = "Chưa thể thực hiện"
    @Published var errorOffersSettings = false
    @Published var isWorking = false
    @Published var unreadCount = 0
    @Published var requestUnreadCount = 0
    @Published var biometricsEnabled = BiometricPreferences.enabled
    @Published var passwordChangeRequiresEmail = false
    @Published var todayMenu: TodayMenu?

    private(set) var token: String?
    private var knownArticleIDs: Set<String> = []
    private let knownArticlesKey = "known-native-article-ids"
    private var eventStreamTask: Task<Void, Never>?
    private var sessionRefreshTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "net.sukavinagroup.network-path")
    private var isMonitoringNetwork = false
    private var lastPathStatus: NWPath.Status?
    private var lastPathWasCellular: Bool?

    func restore() async {
        startNetworkMonitoring()
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard KeychainStore.loadToken() != nil || KeychainStore.loadRefreshToken() != nil else {
            state = .signedOut
            return
        }
        loadKnownArticles()
        do {
            if let savedToken = KeychainStore.loadToken() {
                token = savedToken
                do {
                    profile = try await APIClient.shared.request("auth/me", token: savedToken)
                    if KeychainStore.loadRefreshToken() == nil {
                        let upgraded: LoginResponse = try await APIClient.shared.request(
                            "auth/session/upgrade",
                            method: "POST",
                            token: savedToken
                        )
                        applySession(upgraded)
                    }
                } catch NetworkError.unauthorized {
                    try await refreshSession()
                }
            } else {
                try await refreshSession()
            }
            state = .signedIn
            startNetworkMonitoring()
            await NotificationManager.shared.requestAuthorizationIfNeeded()
            await refreshDashboard()
            await refreshProfile()
            startRealTimeUpdates()
            startSessionRefresh()
        } catch NetworkError.unauthorized {
            signOut()
        } catch {
            present(error)
            startRealTimeUpdates()
        }
    }

    func signIn(loginId: String, password: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        ConnectionDiagnostics.record("Sign-in started; identifierLength=\(loginId.count)")
        if lastPathStatus == .unsatisfied && lastPathWasCellular == true {
            ConnectionDiagnostics.record("Sign-in stopped: iOS reports an unsatisfied cellular path")
            present(NetworkError.cellularRestricted)
            return false
        }
        do {
            let response: LoginResponse = try await APIClient.shared.request(
                "auth/login",
                method: "POST",
                body: LoginBody(loginId: loginId, password: password)
            )
            resetBiometricsWhenAccountChanges(to: response.user.employeeCode)
            applySession(response)
            loadKnownArticles()
            state = .signedIn
            startNetworkMonitoring()
            await NotificationManager.shared.requestAuthorizationIfNeeded()
            await refreshDashboard()
            await refreshProfile()
            startRealTimeUpdates()
            startSessionRefresh()
            ConnectionDiagnostics.record("Sign-in completed successfully")
            return true
        } catch {
            ConnectionDiagnostics.record("Sign-in failed: \(error.localizedDescription)")
            present(error)
            return false
        }
    }

    func refreshTodayMenu() async {
        guard let token else { return }
        do {
            todayMenu = try await APIClient.shared.request("me/menu", token: token)
        } catch {
            present(error)
        }
    }

    func selectMeal(_ choice: String) async {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            todayMenu = try await APIClient.shared.request(
                "me/menu/selection",
                method: "PATCH",
                token: token,
                body: MealSelectionBody(choice: choice)
            )
        } catch {
            present(error)
        }
    }

    func cancelMealSelection() async {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            todayMenu = try await APIClient.shared.request(
                "me/menu/selection",
                method: "DELETE",
                token: token
            )
        } catch {
            present(error)
        }
    }

    func receiveMealSelection() async {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            todayMenu = try await APIClient.shared.request(
                "me/menu/selection/received",
                method: "PATCH",
                token: token
            )
        } catch {
            present(error)
        }
    }

    var biometricName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "Face ID"
    }

    var biometricIcon: String {
        biometricName == "Touch ID" ? "touchid" : "faceid"
    }

    func signInWithBiometrics() async -> Bool {
        guard biometricsEnabled else { return false }
        isWorking = true
        defer { isWorking = false }
        guard let savedToken = BiometricKeychain.load(prompt: "Đăng nhập Sukavina") else {
            errorTitle = "Không thể xác thực"
            errorMessage = "Không thể xác thực sinh trắc học. Vui lòng thử lại hoặc đăng nhập bằng mật khẩu."
            return false
        }
        do {
            let freshProfile: Profile = try await APIClient.shared.request("auth/me", token: savedToken)
            guard BiometricPreferences.employeeCode == freshProfile.employeeCode else {
                disableBiometricLogin()
                errorTitle = "Cần thiết lập lại sinh trắc học"
                errorMessage = "Sinh trắc học chưa được liên kết với tài khoản này. Hãy đăng nhập bằng mật khẩu và bật lại trong tab Tài khoản."
                return false
            }
            token = savedToken
            profile = freshProfile
            state = .signedIn
            startNetworkMonitoring()
            await refreshDashboard()
            startRealTimeUpdates()
            startSessionRefresh()
            return true
        } catch NetworkError.unauthorized {
            disableBiometricLogin()
            errorTitle = "Cần đăng nhập lại"
            errorMessage = "Phiên đăng nhập đã hết hạn. Hãy đăng nhập bằng mật khẩu rồi bật lại sinh trắc học."
            return false
        } catch {
            present(error)
            return false
        }
    }

    func setBiometricLogin(enabled: Bool) {
        if enabled {
            let context = LAContext()
            var evaluationError: NSError?
            guard let employeeCode = profile?.employeeCode,
                  context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError),
                  let token,
                  BiometricKeychain.save(token: token) else {
                biometricsEnabled = false
                errorTitle = "Không thể bật sinh trắc học"
                errorMessage = "Thiết bị chưa thiết lập Face ID/Touch ID hoặc chưa bật mật mã màn hình."
                return
            }
            BiometricPreferences.enabled = true
            BiometricPreferences.employeeCode = employeeCode
            biometricsEnabled = true
        } else {
            disableBiometricLogin()
        }
    }

    private func disableBiometricLogin() {
        BiometricKeychain.clear()
        BiometricPreferences.enabled = false
        BiometricPreferences.employeeCode = nil
        biometricsEnabled = false
    }

    private func resetBiometricsWhenAccountChanges(to employeeCode: String) {
        guard biometricsEnabled else { return }
        guard BiometricPreferences.employeeCode == employeeCode else {
            disableBiometricLogin()
            return
        }
    }

    func refreshDashboard() async {
        guard let token else { return }
        do {
            let fresh: Dashboard = try await APIClient.shared.request("me/dashboard", token: token)
            processNewArticles(fresh.contentItems)
            dashboard = fresh
            AttendanceWidgetBridge.update(from: fresh)
            await refreshRequestNotificationCount()
        } catch {
            present(error)
        }
    }

    func signOut() {
        eventStreamTask?.cancel()
        eventStreamTask = nil
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        KeychainStore.clear()
        token = nil
        profile = nil
        dashboard = nil
        AttendanceWidgetBridge.clear()
        unreadCount = 0
        requestUnreadCount = 0
        state = .signedOut
    }

    private func applySession(_ response: LoginResponse) {
        token = response.accessToken
        KeychainStore.save(token: response.accessToken)
        KeychainStore.save(refreshToken: response.refreshToken)
        AttendanceWidgetBridge.configure(token: response.widgetToken)
        profile = Profile(
            id: "",
            employeeCode: response.user.employeeCode,
            name: response.user.name,
            role: response.user.role,
            accountType: response.user.accountType,
            permissions: response.user.permissions,
            protected: response.user.protected,
            email: nil,
            passwordChangedAt: nil
        )
    }

    private func refreshSession() async throws {
        guard let refreshToken = KeychainStore.loadRefreshToken() else {
            throw NetworkError.unauthorized
        }
        let response: LoginResponse = try await APIClient.shared.request(
            "auth/refresh",
            method: "POST",
            body: RefreshSessionBody(refreshToken: refreshToken)
        )
        applySession(response)
        if biometricsEnabled {
            _ = BiometricKeychain.save(token: response.accessToken)
        }
    }

    private func startSessionRefresh() {
        sessionRefreshTask?.cancel()
        sessionRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12 * 60 * 60 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                do {
                    try await self.refreshSession()
                } catch NetworkError.unauthorized {
                    self.signOut()
                    return
                } catch {
                    ConnectionDiagnostics.record("Session refresh deferred: \(error.localizedDescription)")
                }
            }
        }
    }

    func refreshRequestNotificationCount() async {
        guard let token,
              let values: [RequestNotification] = try? await APIClient.shared.request("me/requests/notifications", token: token) else { return }
        requestUnreadCount = values.filter { !$0.read }.count
    }

    func dismissError() {
        errorMessage = nil
        errorTitle = "Chưa thể thực hiện"
        errorOffersSettings = false
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        if let networkError = error as? NetworkError,
           case .cellularRestricted = networkError {
            errorTitle = "Cần bật dữ liệu di động"
            errorOffersSettings = true
        } else if let networkError = error as? NetworkError,
                  case .invalidCredentials = networkError {
            errorTitle = "Sai thông tin đăng nhập"
            errorOffersSettings = false
        } else {
            errorTitle = "Chưa thể thực hiện"
            errorOffersSettings = false
        }
    }

    private func startRealTimeUpdates() {
        eventStreamTask?.cancel()
        eventStreamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    var request = URLRequest(url: URL(string: "https://sukavinagroup.net/api/public/news/events")!)
                    request.timeoutInterval = 60 * 60
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await NetworkSessions.events.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw NetworkError.invalidResponse
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        if line.hasPrefix("data:") && line.contains("_changed") {
                            await refreshProfile()
                            await refreshDashboard()
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    private func startNetworkMonitoring() {
        guard !isMonitoringNetwork else { return }
        isMonitoringNetwork = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasStatus = self.lastPathStatus
                let wasCellular = self.lastPathWasCellular
                let isCellular = path.usesInterfaceType(.cellular)
                let isWiFi = path.usesInterfaceType(.wifi)
                ConnectionDiagnostics.record("Network path: status=\(String(describing: path.status)) cellular=\(isCellular) wifi=\(isWiFi) expensive=\(path.isExpensive) constrained=\(path.isConstrained)")
                self.lastPathStatus = path.status
                self.lastPathWasCellular = isCellular

                // The first callback only records the current path. Refresh after a real reconnect or handoff.
                guard wasStatus != nil,
                      path.status == .satisfied,
                      wasStatus != .satisfied || wasCellular != isCellular,
                      self.token != nil else { return }
                await self.refreshProfile()
                await self.refreshDashboard()
                self.startRealTimeUpdates()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func refreshProfile() async {
        guard let token else { return }
        do {
            profile = try await APIClient.shared.request("auth/me", token: token)
        } catch {
            present(error)
        }
    }

    func markArticlesRead() {
        guard let items = dashboard?.contentItems else { return }
        knownArticleIDs.formUnion(items.map(\.id))
        persistKnownArticles()
        unreadCount = 0
        NotificationManager.shared.clearBadge()
    }

    private func loadKnownArticles() {
        let stored = UserDefaults.standard.stringArray(forKey: knownArticlesKey) ?? []
        knownArticleIDs = Set(stored)
    }

    private func processNewArticles(_ items: [ContentItem]) {
        if knownArticleIDs.isEmpty {
            knownArticleIDs = Set(items.map(\.id))
            persistKnownArticles()
            return
        }
        let newItems = items.filter { !knownArticleIDs.contains($0.id) }
        if !newItems.isEmpty {
            unreadCount += newItems.count
            NotificationManager.shared.notifyNewArticles(newItems)
            knownArticleIDs.formUnion(newItems.map(\.id))
            persistKnownArticles()
        }
    }

    private func persistKnownArticles() {
        UserDefaults.standard.set(Array(knownArticleIDs.prefix(300)), forKey: knownArticlesKey)
    }

    func deleteAccount(password: String) async -> Bool {
        guard let token else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let _: MessageResponse = try await APIClient.shared.request(
                "auth/me",
                method: "DELETE",
                token: token,
                body: DeleteAccountBody(password: password, confirmation: "XOA TAI KHOAN")
            )
            disableBiometricLogin()
            signOut()
            return true
        } catch {
            present(error)
            return false
        }
    }

    func requestPasswordChange() async -> PasswordChangeRequestResponse? {
        guard let token else { return nil }
        passwordChangeRequiresEmail = false
        isWorking = true
        defer { isWorking = false }
        do {
            return try await APIClient.shared.request(
                "auth/password-change/request", method: "POST", token: token
            )
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("email") {
                presentMissingEmailForPasswordChange()
            } else {
                present(error)
            }
            return nil
        }
    }

    var hasLinkedEmail: Bool {
        !(profile?.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func presentMissingEmailForPasswordChange() {
        passwordChangeRequiresEmail = true
        errorTitle = "Cần cập nhật email"
        errorMessage = "Tài khoản chưa có email liên kết. Vui lòng liên hệ Nhân sự để cập nhật email trước khi đổi mật khẩu."
        errorOffersSettings = false
    }

    func confirmPasswordChange(code: String, newPassword: String) async -> Bool {
        guard let token else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let _: MessageResponse = try await APIClient.shared.request(
                "auth/password-change/confirm", method: "POST", token: token,
                body: PasswordChangeConfirmBody(code: code, newPassword: newPassword)
            )
            disableBiometricLogin()
            await refreshProfile()
            return true
        } catch {
            present(error)
            return false
        }
    }
}

private struct SukavinaAppView: View {
    @StateObject private var session = SessionStore()

    var body: some View {
        ZStack {
            Group {
                switch session.state {
                case .restoring:
                    NativeLaunchView()
                case .signedOut:
                    AuthenticationView()
                        .environmentObject(session)
                case .signedIn:
                    EmployeePortalView()
                        .environmentObject(session)
                }
            }

            if let message = session.errorMessage {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { session.dismissError() }

                ElegantAppAlert(
                    title: session.errorTitle,
                    message: message,
                    offersSettings: session.errorOffersSettings,
                    dismiss: { session.dismissError() }
                )
                .padding(.horizontal, 22)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .task { await session.restore() }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: session.errorMessage)
    }
}

private struct ElegantAppAlert: View {
    let title: String
    let message: String
    let offersSettings: Bool
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(AppTheme.red.opacity(0.12))
                    Image(systemName: alertIcon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(AppTheme.red)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text(message)
                        .font(.system(size: 14.5, weight: .regular))
                        .foregroundColor(AppTheme.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundColor(AppTheme.muted)
                        .frame(width: 30, height: 30)
                        .background(AppTheme.field)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Đóng")
            }

            if offersSettings {
                Button {
                    dismiss()
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    Label("Mở Cài đặt", systemImage: "gearshape.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .background(
                    LinearGradient(colors: [AppTheme.red, AppTheme.deepRed], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Button("Đã hiểu", action: dismiss)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(AppTheme.red)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .buttonStyle(.plain)
            }
        }
        .padding(20)
        .adaptiveGlassSurface(cornerRadius: 24, tint: AppTheme.red.opacity(0.06))
        .shadow(color: .black.opacity(0.24), radius: 22, y: 10)
        .frame(maxWidth: 370)
    }

    private var alertIcon: String {
        if offersSettings { return "antenna.radiowaves.left.and.right.slash" }
        if title == "Cần cập nhật email" { return "envelope.badge.fill" }
        return "exclamationmark.shield.fill"
    }
}

private struct NativeLaunchView: View {
    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            VStack(spacing: 20) {
                Image("AppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                ProgressView().tint(AppTheme.red)
                Text("SUKAVINA")
                    .font(.caption.weight(.semibold))
                    .tracking(4)
                    .foregroundColor(AppTheme.muted)
            }
        }
    }
}

private struct AuthenticationView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [AppTheme.ink, AppTheme.loginAccent, AppTheme.ink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SUKAVINA GROUP")
                                .font(.caption.weight(.bold))
                                .tracking(3.5)
                                .foregroundColor(.red.opacity(0.9))
                            Text("Chào mừng trở lại")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("Thông tin công việc của bạn, trong một ứng dụng native gọn gàng.")
                                .foregroundColor(AppTheme.muted)
                        }

                        LoginForm()
                        .padding(20)
                        .background(AppTheme.card.opacity(0.96))
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(AppTheme.cardBorder, lineWidth: 1)
                        )
                        .shadow(color: AppTheme.deepRed.opacity(0.14), radius: 24, y: 12)
                    }
                    .padding(22)
                }
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }
}

private struct LoginForm: View {
    @EnvironmentObject private var session: SessionStore
    @State private var loginId = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            NativeField(title: "Mã nhân viên, Gmail hoặc số điện thoại", text: $loginId, icon: "person.text.rectangle")
            NativeSecureField(title: "Mật khẩu", text: $password)
            Button {
                Task { _ = await session.signIn(loginId: loginId, password: password) }
            } label: {
                HStack {
                    if session.isWorking { ProgressView().tint(.white) }
                    Text("Đăng nhập").fontWeight(.bold)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .background(AppTheme.red)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(loginId.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || session.isWorking)
            .opacity(loginId.isEmpty || password.isEmpty ? 0.55 : 1)

            if session.biometricsEnabled {
                HStack(spacing: 12) {
                    Rectangle().fill(AppTheme.fieldBorder).frame(height: 1)
                    Text("hoặc").font(.caption).foregroundColor(AppTheme.muted)
                    Rectangle().fill(AppTheme.fieldBorder).frame(height: 1)
                }

                Button {
                    Task { _ = await session.signInWithBiometrics() }
                } label: {
                    Label("Đăng nhập bằng \(session.biometricName)", systemImage: session.biometricIcon)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.biometricForeground)
                .background(AppTheme.biometricFill)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.biometricForeground.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: AppTheme.deepRed.opacity(0.08), radius: 10, y: 4)
                .disabled(session.isWorking)
            }
        }
    }
}

private struct RegistrationForm: View {
    @State private var employeeCode = ""
    @State private var fullName = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var verification: VerificationContext?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 16) {
            NativeField(title: "Mã nhân viên", text: $employeeCode, icon: "number")
            NativeField(title: "Họ và tên", text: $fullName, icon: "person")
            NativeField(title: "Số điện thoại (không bắt buộc)", text: $phone, icon: "phone", keyboard: .phonePad)
            NativeField(title: "Địa chỉ Gmail", text: $email, icon: "envelope", keyboard: .emailAddress)
            NativeSecureField(title: "Mật khẩu từ 6 ký tự", text: $password)

            Button("Đăng ký và nhận mã") {
                Task { await register() }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundColor(.white)
            .background(AppTheme.red)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(!isValid || isWorking)
            .opacity(isValid ? 1 : 0.55)

            if let message {
                Text(message).font(.footnote).foregroundColor(AppTheme.muted)
            }
        }
        .sheet(item: $verification) { context in
            VerificationView(context: context)
        }
    }

    private var isValid: Bool {
        !employeeCode.trimmingCharacters(in: .whitespaces).isEmpty &&
        !fullName.trimmingCharacters(in: .whitespaces).isEmpty &&
        email.lowercased().hasSuffix("@gmail.com") && password.count >= 6
    }

    private func register() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result: RegistrationResponse = try await APIClient.shared.request(
                "auth/register",
                method: "POST",
                body: RegisterBody(
                    employeeCode: employeeCode,
                    fullName: fullName,
                    phoneNumber: phone.isEmpty ? nil : phone,
                    gmailEmail: email,
                    password: password
                )
            )
            message = result.message
            verification = VerificationContext(employeeCode: result.employeeCode, email: email.lowercased())
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct VerificationContext: Identifiable {
    let employeeCode: String
    let email: String
    var id: String { employeeCode + email }
}

private struct VerificationView: View {
    let context: VerificationContext
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var message: String
    @State private var isWorking = false

    init(context: VerificationContext) {
        self.context = context
        _message = State(initialValue: "Nhập mã gồm 6 chữ số đã gửi tới \(context.email).")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 48))
                    .foregroundColor(AppTheme.red)
                Text("Xác minh Gmail").font(.title.bold())
                Text(message).multilineTextAlignment(.center).foregroundColor(AppTheme.muted)
                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .padding()
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Button("Xác minh") { Task { await verify() } }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(AppTheme.red)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .disabled(code.count != 6 || isWorking)
                Button("Gửi lại mã") { Task { await resend() } }
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(24)
            .background(AppTheme.ink.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } } }
        }
    }

    private func verify() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result: MessageResponse = try await APIClient.shared.request(
                "auth/verify-email",
                method: "POST",
                body: VerifyBody(employeeCode: context.employeeCode, gmailEmail: context.email, code: code)
            )
            message = result.message
            code = ""
        } catch { message = error.localizedDescription }
    }

    private func resend() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result: MessageResponse = try await APIClient.shared.request(
                "auth/resend-verification",
                method: "POST",
                body: ResendBody(employeeCode: context.employeeCode, gmailEmail: context.email)
            )
            message = result.message
        } catch { message = error.localizedDescription }
    }
}

private struct EmployeePortalView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Trang chủ", systemImage: "house.fill") }
            TodayMenuView()
                .tabItem { Label("Thực đơn", systemImage: "fork.knife") }
            RequestsView()
                .tabItem { Label("Đơn từ", systemImage: "doc.text.fill") }
            NotificationsView()
                .tabItem { Label("Thông báo", systemImage: "bell.fill") }
                .badge(session.unreadCount + session.requestUnreadCount)
            ProfileView()
                .tabItem { Label("Tài khoản", systemImage: "person.crop.circle.fill") }
        }
        .accentColor(AppTheme.red)
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task {
                    await session.refreshDashboard()
                }
            }
        }
    }
}

private struct TodayMenuView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var pendingChoice: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("BẾP ĂN SUKAVINA")
                            .font(.caption.bold())
                            .tracking(1.5)
                            .foregroundColor(AppTheme.red)
                        Text("Thực đơn hôm nay")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(session.todayMenu?.day.dayName ?? "Đang cập nhật")
                            .foregroundColor(AppTheme.muted)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 11) {
                        menuGroup("Món nước", icon: "takeoutbag.and.cup.and.straw.fill", color: .cyan, lines: [session.todayMenu?.day.featured])
                        menuGroup("Món thường", icon: "fork.knife", color: .orange, lines: [
                            session.todayMenu?.day.savoryMain,
                            session.todayMenu?.day.savorySide,
                            session.todayMenu?.day.vegetable,
                            session.todayMenu?.day.soup
                        ])
                        menuGroup("Món chay", icon: "leaf.fill", color: .green, lines: [
                            session.todayMenu?.day.vegetarianMain,
                            session.todayMenu?.day.vegetarianSide
                        ])
                        menuGroup("Tăng ca", icon: "moon.stars.fill", color: .purple, lines: [session.todayMenu?.day.overtime])
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        if let selection = session.todayMenu?.selection {
                            let isWater = selection == "water"
                            Text("MÓN ĂN ĐÃ ĐẶT").font(.caption.bold()).tracking(1.2).foregroundColor(AppTheme.muted)
                            HStack(spacing: 14) {
                                Image(systemName: isWater ? "takeoutbag.and.cup.and.straw.fill" : "leaf.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(isWater ? .cyan : .green)
                                    .frame(width: 50, height: 50)
                                    .background((isWater ? Color.cyan : Color.green).opacity(0.14))
                                    .clipShape(RoundedRectangle(cornerRadius: 15))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(isWater ? "Món nước" : "Món chay").font(.title3.bold())
                                    Text(selectedMealDetail(selection))
                                        .font(.subheadline).foregroundColor(AppTheme.muted).lineLimit(2)
                                }
                            }
                            if session.todayMenu?.receivedAt == nil {
                                Button {
                                    pendingChoice = "received"
                                } label: {
                                    Label("Xác nhận đã nhận món", systemImage: "checkmark.circle.fill")
                                        .font(.headline).foregroundColor(.white)
                                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                                        .background(Color.green.opacity(0.88))
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                }
                            } else {
                                Label("Đã nhận món", systemImage: "checkmark.seal.fill")
                                    .font(.headline).foregroundColor(.green)
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background(Color.green.opacity(0.11))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            if session.todayMenu?.receivedAt == nil {
                                Button {
                                    pendingChoice = "cancel"
                                } label: {
                                    Label("Hủy lựa chọn hôm nay", systemImage: "xmark.circle.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.red.opacity(0.86))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                                .disabled(session.todayMenu?.orderingOpen == false)
                            }
                        } else {
                            Text("LỰA CHỌN HÔM NAY").font(.caption.bold()).tracking(1.2).foregroundColor(AppTheme.muted)
                            Text("Bạn muốn dùng món nào?").font(.title3.bold())
                            if session.todayMenu?.orderingOpen == false {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.badge.exclamationmark.fill")
                                        .font(.title3.bold())
                                        .foregroundColor(.orange)
                                        .frame(width: 42, height: 42)
                                        .background(Color.orange.opacity(0.13))
                                        .clipShape(RoundedRectangle(cornerRadius: 13))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Đã khóa đặt món").font(.headline).foregroundColor(.orange)
                                        Text("Vui lòng đặt món trước \(session.todayMenu?.orderingCutoff ?? "09:00").")
                                            .font(.caption).foregroundColor(AppTheme.muted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color.orange.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            } else {
                                mealButton("Món nước", detail: session.todayMenu?.day.featured, icon: "takeoutbag.and.cup.and.straw.fill", color: .cyan, choice: "water")
                                mealButton("Món chay", detail: [session.todayMenu?.day.vegetarianMain, session.todayMenu?.day.vegetarianSide].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), icon: "leaf.fill", color: .green, choice: "vegetarian")
                            }
                        }
                    }
                    .padding(18)
                    .background(AppTheme.card.opacity(0.86))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(18)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("Thực đơn")
            .task {
                await session.refreshTodayMenu()
                while !Task.isCancelled {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
                    let now = Date()
                    let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
                    let delay = max(1, nextDay.timeIntervalSince(now) + 0.5)
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    await session.refreshTodayMenu()
                }
            }
            .refreshable { await session.refreshTodayMenu() }
            .sheet(isPresented: Binding(get: { pendingChoice != nil }, set: { if !$0 { pendingChoice = nil } })) {
                let choice = pendingChoice ?? "water"
                let cancelling = choice == "cancel"
                let receiving = choice == "received"
                let title = choice == "water" ? "Món nước" : "Món chay"
                let detail = choice == "water"
                    ? (session.todayMenu?.day.featured ?? "...")
                    : [session.todayMenu?.day.vegetarianMain, session.todayMenu?.day.vegetarianSide].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                VStack(spacing: 18) {
                    Capsule().fill(AppTheme.muted.opacity(0.35)).frame(width: 42, height: 5)
                    Image(systemName: cancelling ? "xmark.circle.fill" : (receiving ? "checkmark.circle.fill" : (choice == "water" ? "takeoutbag.and.cup.and.straw.fill" : "leaf.fill")))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(cancelling ? .red : (receiving ? .green : (choice == "water" ? .cyan : .green)))
                        .frame(width: 64, height: 64)
                        .background((cancelling ? Color.red : (choice == "water" ? Color.cyan : Color.green)).opacity(0.13))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    VStack(spacing: 7) {
                        Text(cancelling ? "Hủy lựa chọn hôm nay?" : (receiving ? "Bạn đã nhận món?" : "Xác nhận \(title)"))
                            .font(.title2.bold())
                        Text(cancelling ? "Bạn có thể chọn lại món khác bất cứ lúc nào trong ngày." : (receiving ? "Xác nhận sau khi bạn đã nhận đúng phần ăn đã đặt." : "Kiểm tra món trước khi xác nhận đặt."))
                            .font(.subheadline).foregroundColor(AppTheme.muted).multilineTextAlignment(.center)
                    }
                    if !cancelling && !receiving {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title.uppercased()).font(.caption.bold()).tracking(1).foregroundColor(AppTheme.muted)
                            Text(detail.isEmpty ? "..." : detail).font(.headline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Button {
                        pendingChoice = nil
                        Task {
                            if cancelling { await session.cancelMealSelection() }
                            else if receiving { await session.receiveMealSelection() }
                            else { await session.selectMeal(choice) }
                        }
                    } label: {
                        Text(cancelling ? "Xác nhận hủy" : (receiving ? "Xác nhận đã nhận" : "Xác nhận đặt món"))
                            .font(.headline).foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(cancelling ? Color.red : (receiving ? Color.green : AppTheme.red)).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Button("Quay lại") { pendingChoice = nil }
                        .font(.headline).foregroundColor(AppTheme.muted).padding(.vertical, 5)
                }
                .padding(22)
                .presentationDetents([.height((cancelling || receiving) ? 370 : 450)])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(28)
            }
        }
    }

    private func selectedMealDetail(_ selection: String) -> String {
        if selection == "water" {
            return session.todayMenu?.day.featured ?? "..."
        }
        let detail = [session.todayMenu?.day.vegetarianMain, session.todayMenu?.day.vegetarianSide]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? "..." : detail
    }

    private func menuGroup(_ title: String, icon: String, color: Color, lines: [String?]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.headline).foregroundColor(color).frame(width: 42, height: 42).background(color.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 13))
            Text(title.uppercased()).font(.caption2.bold()).tracking(1).foregroundColor(AppTheme.muted)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, value in
                Text(value?.isEmpty == false ? value! : "...")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(15)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(color.opacity(0.16)))
    }

    private func mealButton(_ title: String, detail: String?, icon: String, color: Color, choice: String) -> some View {
        let selected = session.todayMenu?.selection == choice
        return Button {
            pendingChoice = choice
        } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.title3).foregroundColor(color).frame(width: 44, height: 44).background(color.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail?.isEmpty == false ? detail! : "...").font(.caption).foregroundColor(AppTheme.muted).lineLimit(1)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundColor(selected ? .green : AppTheme.muted)
            }
            .padding(13)
            .background(selected ? Color.green.opacity(0.11) : Color.white.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(selected ? Color.green.opacity(0.35) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(session.isWorking)
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Xin chào,")
                            .foregroundColor(AppTheme.muted)
                        Text(session.dashboard?.name ?? session.profile?.name ?? "Nhân viên")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(session.dashboard?.employeeCode ?? session.profile?.employeeCode ?? "")
                            .font(.subheadline.monospaced())
                            .foregroundColor(AppTheme.red)
                    }

                    MetricCard(value: "\(session.dashboard?.remainingLeaveDays ?? 0)", label: "Ngày phép còn lại", icon: "calendar.badge.clock")
                    MetricWideCard(status: session.dashboard?.payrollStatus ?? "Chưa cập nhật")

                    NavigationLink(destination: ModernAttendanceHistoryView()) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Chấm công hôm nay").font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(AppTheme.red)
                            }
                            Divider().overlay(Color.white.opacity(0.08))
                            HStack(spacing: 0) {
                                attendanceMetric(title: "Giờ vào", value: checkInTime, color: .green)
                                Divider().frame(height: 38).overlay(Color.white.opacity(0.08))
                                attendanceMetric(title: "Giờ ra", value: checkOutTime, color: AppTheme.red)
                            }
                        }
                        .padding(16)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)

                }
                .padding(20)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("Sukavina")
            .refreshable { await session.refreshDashboard() }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func attendanceMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(AppTheme.muted)
            Text(value).font(.title3.bold()).foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private func attendanceTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            return value
        }
        return date.formatted(date: .omitted, time: .standard)
    }

    private var checkInTime: String {
        guard let record = session.dashboard?.attendanceRecords?.last else { return "--:--" }
        return attendanceTime(record.punchedAt)
    }

    private var checkOutTime: String {
        guard let records = session.dashboard?.attendanceRecords, records.count > 1,
              let record = records.first else { return "--:--" }
        return attendanceTime(record.punchedAt)
    }
}

private struct AttendanceHistoryView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var selectedMonth = Self.monthValue(Date())
    @State private var history: AttendanceMonth?
    @State private var isLoading = false
    @State private var message: String?
    @State private var monthCache: [String: AttendanceMonth] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    ForEach(monthOptions) { option in
                        monthTab(option)
                    }
                }
                .padding(5)
                .background(AppTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(AppTheme.muted.opacity(0.18), lineWidth: 1)
                }

                if isLoading {
                    ProgressView("Đang tải bảng công...").tint(AppTheme.red)
                } else if let days = history?.days, !days.isEmpty {
                    LazyVStack(spacing: 12) {
                    ForEach(days) { day in
                        HStack(spacing: 14) {
                            Text(dayLabel(day.date)).font(.headline)
                            Spacer()
                            timeColumn("Vào", day.checkIn)
                            timeColumn("Ra", day.checkOut)
                        }
                        .padding(16)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    }
                } else {
                    Text(message ?? "Không có dữ liệu trong tháng này.")
                        .foregroundColor(AppTheme.muted)
                }
            }
            .padding(20)
        }
        .background(AppTheme.ink.ignoresSafeArea())
        .navigationTitle("Bảng chấm công")
        .task(id: selectedMonth) { await loadHistory() }
    }

    private var monthOptions: [AttendanceMonthOption] {
        (0..<2).compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .month, value: -offset, to: Date()) else { return nil }
            return AttendanceMonthOption(
                value: Self.monthValue(date),
                title: offset == 0 ? "Tháng này" : "Tháng trước",
                label: Self.monthLabel(date)
            )
        }
    }

    private func monthTab(_ option: AttendanceMonthOption) -> some View {
        let isSelected = selectedMonth == option.value
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                selectedMonth = option.value
            }
        } label: {
            VStack(spacing: 3) {
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                Text(option.label)
                    .font(.caption2.weight(.medium))
                    .opacity(isSelected ? 0.82 : 0.7)
            }
            .foregroundStyle(isSelected ? Color.white : AppTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(isSelected ? AppTheme.red : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title), \(option.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func timeColumn(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(title).font(.caption2).foregroundColor(AppTheme.muted)
            Text(timeLabel(value)).font(.subheadline.bold())
        }
        .frame(minWidth: 54)
    }

    private func loadHistory() async {
        guard let token = session.token else { return }
        if let cached = monthCache[selectedMonth] {
            history = cached
            message = nil
            return
        }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let loaded: AttendanceMonth = try await APIClient.shared.request(
                "me/attendance?month=\(selectedMonth)",
                token: token
            )
            history = loaded
            monthCache[selectedMonth] = loaded
        } catch {
            history = nil
            message = error.localizedDescription
        }
    }

    private func timeLabel(_ value: String?) -> String {
        guard let value else { return "--:--" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return "--:--" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func dayLabel(_ value: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return value }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private static func monthValue(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private static func monthLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "'Tháng' M, yyyy"
        return formatter.string(from: date)
    }
}

private struct ModernAttendanceHistoryView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var selectedMonth = Self.monthValue(Date())
    @State private var history: AttendanceMonth?
    @State private var selectedDate: String?
    @State private var isLoading = false
    @State private var message: String?
    @State private var cache: [String: AttendanceMonth] = [:]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                monthNavigation
                enhancedSummaryCards
                calendarCard
                if isLoading {
                    ProgressView("Đang tải bảng công...").tint(AppTheme.red)
                } else if let day = selectedDay {
                    dayDetail(day)
                } else if let message {
                    Text(message).foregroundStyle(AppTheme.muted)
                }
            }
            .padding(16)
        }
        .background(AppTheme.ink.ignoresSafeArea())
        .navigationTitle("Bảng chấm công")
        .task(id: selectedMonth) { await loadHistory() }
    }

    private var monthNavigation: some View {
        HStack {
            monthButton("chevron.left", target: 1)
            Spacer()
            Text(monthTitle).font(.headline.bold()).foregroundStyle(Color.primary)
            Spacer()
            monthButton("chevron.right", target: -1)
        }
        .padding(12).background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func monthButton(_ icon: String, target offset: Int) -> some View {
        let index = options.firstIndex(of: selectedMonth) ?? 0
        let target = index + offset
        return Button {
            guard options.indices.contains(target) else { return }
            selectedMonth = options[target]
        } label: {
            Image(systemName: icon).font(.caption.bold())
                .frame(width: 40, height: 40)
                .background(AppTheme.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .disabled(!options.indices.contains(target))
        .opacity(options.indices.contains(target) ? 1 : 0.35)
    }

    private var summaryCards: some View {
        HStack(spacing: 8) {
            summary(count("present"), "Ngày công", .green)
            summary(count("late"), "Đi trễ", .orange)
            summary(count("leave"), "Nghỉ phép", EmployeeRequestKind.leave.color)
            summary(count("absent"), "Vắng", AppTheme.red)
        }
    }

    private var enhancedSummaryCards: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(4, max(1, visibleSummaries.count))),
            spacing: 8
        ) {
            ForEach(visibleSummaries, id: \.title) { item in
                summary(item.value, item.title, item.color)
            }
        }
    }

    private var visibleSummaries: [(title: String, value: Int, color: Color)] {
        [
            ("Ngày công", countStatus("present"), .green),
            ("Đi trễ", countStatus("late"), EmployeeRequestKind.late.color),
            ("Về sớm", countStatus("early"), EmployeeRequestKind.early.color),
            ("Nghỉ phép", countStatus("leave"), EmployeeRequestKind.leave.color),
            ("Vắng", countStatus("absent"), AppTheme.red),
            ("Làm thêm", countStatus("overtime"), EmployeeRequestKind.overtime.color),
        ].filter { $0.value > 0 }
    }

    private func summary(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 5) {
            Text("\(value)").font(.title3.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(AppTheme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 13)
        .background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 15))
    }

    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lịch chấm công").font(.headline).foregroundStyle(Color.primary)
            HStack(spacing: 4) {
                ForEach(["T2", "T3", "T4", "T5", "T6", "T7", "CN"], id: \.self) {
                    Text($0).font(.caption.bold()).foregroundStyle(AppTheme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 7) {
                ForEach(0..<leadingEmptyDays, id: \.self) { _ in
                    Color.clear.frame(height: 50)
                }
                ForEach(history?.days ?? []) { day in dayCell(day) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 9) {
                if countStatus("present") > 0 { legend("Đủ công", .green.opacity(0.22)) }
                if countStatus("late") > 0 { legend("Đi trễ", EmployeeRequestKind.late.color.opacity(0.22)) }
                if countStatus("early") > 0 { legend("Về sớm", EmployeeRequestKind.early.color.opacity(0.22)) }
                if countStatus("leave") > 0 { legend("Nghỉ phép", EmployeeRequestKind.leave.color.opacity(0.2)) }
                if countStatus("absent") > 0 { legend("Vắng", AppTheme.red.opacity(0.2)) }
                if countStatus("overtime") > 0 { legend("Làm thêm", EmployeeRequestKind.overtime.color.opacity(0.2)) }
              }
            }
        }
        .padding(18).background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func dayCell(_ day: AttendanceDay) -> some View {
        let selected = selectedDate == day.date
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { selectedDate = day.date }
        } label: {
            Text(String(Int(day.date.suffix(2)) ?? 0))
                .font(.subheadline.weight(selected ? .bold : .medium))
                .foregroundStyle(dayStatuses(day).contains("absent") ? AppTheme.red : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(dayBackground(day))
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(selected ? Color(red: 0.05, green: 0.25, blue: 0.5) : .clear, lineWidth: 2)
                }
        }.buttonStyle(.plain)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 9, height: 9)
            Text(title).font(.system(size: 9)).foregroundStyle(AppTheme.muted)
        }
    }

    private func dayDetail(_ day: AttendanceDay) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Chi tiết ngày \(displayDate(day.date))", systemImage: "calendar")
                .font(.headline).foregroundStyle(Color.primary)
            Divider()
            detailRow("Giờ vào", time(day.checkIn))
            detailRow("Giờ ra", time(day.checkOut))
            detailRow("Trạng thái", dayStatuses(day).map(statusTitle).joined(separator: " · "))
            detailRow("Khung giờ \(history?.department ?? "phòng ban")",
                      "\(day.startTime ?? history?.startTime ?? "--:--") - \(day.endTime ?? history?.endTime ?? "--:--")")
        }
        .padding(18).background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(AppTheme.muted); Spacer(); Text(value).bold() }
    }

    private var options: [String] {
        (0..<2).compactMap { Calendar.current.date(byAdding: .month, value: -$0, to: Date()) }
            .map(Self.monthValue)
    }
    private var monthTitle: String {
        guard let date = Self.monthParser.date(from: selectedMonth) else { return selectedMonth }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "'Tháng' M / yyyy"; return formatter.string(from: date)
    }
    private var selectedDay: AttendanceDay? {
        let days = history?.days ?? []
        return days.first { $0.date == selectedDate } ?? days.first { $0.date == Self.dayValue(Date()) }
    }
    private var leadingEmptyDays: Int {
        guard let value = history?.days.first?.date, let date = Self.dayParser.date(from: value) else { return 0 }
        return (Calendar(identifier: .gregorian).component(.weekday, from: date) + 5) % 7
    }
    private func count(_ status: String) -> Int { history?.days.filter { $0.status == status }.count ?? 0 }
    private func countStatus(_ status: String) -> Int {
        history?.days.filter { dayStatuses($0).contains(status) }.count ?? 0
    }
    private func dayStatuses(_ day: AttendanceDay) -> [String] {
        day.statuses ?? day.status.map { [$0] } ?? []
    }
    @ViewBuilder private func dayBackground(_ day: AttendanceDay) -> some View {
        let statuses = dayStatuses(day)
        if statuses.contains("late") && statuses.contains("early") {
            HStack(spacing: 0) {
                EmployeeRequestKind.late.color.opacity(0.22)
                EmployeeRequestKind.early.color.opacity(0.22)
            }
        } else {
            dayColor(statuses.first)
        }
    }
    private func dayColor(_ status: String?) -> Color {
        switch status {
        case "present": return .green.opacity(0.2)
        case "late": return .orange.opacity(0.2)
        case "early": return EmployeeRequestKind.early.color.opacity(0.2)
        case "leave": return EmployeeRequestKind.leave.color.opacity(0.2)
        case "absent": return AppTheme.red.opacity(0.18)
        case "overtime": return EmployeeRequestKind.overtime.color.opacity(0.2)
        case "weekend": return .gray.opacity(0.08)
        default: return AppTheme.muted.opacity(0.06)
        }
    }
    private func statusTitle(_ status: String?) -> String {
        switch status {
        case "present": return "Đủ công"
        case "late": return "Đi trễ"
        case "early": return "Về sớm"
        case "leave": return "Nghỉ phép"
        case "absent": return "Vắng"
        case "overtime": return "Làm thêm giờ"
        case "weekend": return "Cuối tuần"
        default: return "Chưa đến"
        }
    }
    private func time(_ value: String?) -> String {
        guard let value else { return "--:--" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return "--:--" }
        return date.formatted(date: .omitted, time: .shortened)
    }
    private func displayDate(_ value: String) -> String {
        guard let date = Self.dayParser.date(from: value) else { return value }
        let formatter = DateFormatter(); formatter.dateFormat = "dd/MM/yyyy"; return formatter.string(from: date)
    }
    private func loadHistory() async {
        guard let token = session.token else { return }
        if let cached = cache[selectedMonth] {
            history = cached
            selectedDate = cached.days.first(where: { $0.date == Self.dayValue(Date()) })?.date ?? cached.days.last?.date
            return
        }
        isLoading = true; message = nil
        defer { isLoading = false }
        do {
            let loaded: AttendanceMonth = try await APIClient.shared.request(
                "me/attendance?month=\(selectedMonth)", token: token
            )
            history = loaded; cache[selectedMonth] = loaded
            selectedDate = loaded.days.first(where: { $0.date == Self.dayValue(Date()) })?.date ?? loaded.days.last?.date
        } catch {
            history = nil; message = error.localizedDescription
        }
    }
    private static func monthValue(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"; return formatter.string(from: date)
    }
    private static func dayValue(_ date: Date) -> String { dayParser.string(from: date) }
    private static let monthParser: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"; return formatter
    }()
    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = "yyyy-MM-dd"; return formatter
    }()
}

private struct MetricCard: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).foregroundColor(AppTheme.red)
            Text(value).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.65)
            Text(label).font(.caption).foregroundColor(AppTheme.muted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct MetricWideCard: View {
    let status: String
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "banknote.fill")
                .font(.title2)
                .foregroundColor(AppTheme.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Bảng lương").font(.caption).foregroundColor(AppTheme.muted)
                Text(status.isEmpty ? "Chưa cập nhật" : status).font(.headline)
            }
            Spacer()
        }
        .padding(18)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private enum EmployeeRequestStatus: String, Codable, CaseIterable {
    case pending, approved, rejected, cancelled
    var title: String {
        switch self { case .pending: return "Chờ duyệt"; case .approved: return "Đã duyệt"; case .rejected: return "Từ chối"; case .cancelled: return "Đã hủy" }
    }
    var color: Color {
        switch self { case .pending: return .orange; case .approved: return .green; case .rejected: return AppTheme.red; case .cancelled: return .gray }
    }
}

private enum EmployeeRequestKind: String, Codable, CaseIterable, Identifiable {
    case leave, late, early, overtime, business
    var id: String { rawValue }
    var title: String {
        switch self { case .leave: return "Nghỉ phép"; case .late: return "Đi trễ"; case .early: return "Về sớm"; case .overtime: return "Làm thêm giờ"; case .business: return "Công tác" }
    }
    var icon: String {
        switch self {
        case .leave: return "calendar.badge.minus"
        case .late: return "clock.badge.exclamationmark"
        case .early: return "figure.walk.departure"
        case .overtime: return "moon.stars.fill"
        case .business: return "airplane"
        }
    }
    var color: Color {
        switch self {
        case .leave: return .blue
        case .late: return .orange
        case .early: return .purple
        case .overtime: return .indigo
        case .business: return .teal
        }
    }
}

private struct EmployeeRequest: Codable, Identifiable {
    struct EmployeeSummary: Codable { let fullName: String; let employeeCode: String }
    let id: String
    let kind: EmployeeRequestKind
    let from: Date
    let to: Date
    let reason: String
    let status: EmployeeRequestStatus
    let createdAt: Date
    let dueAt: Date
    let decisionNote: String?
    let autoApproved: Bool
    let employee: EmployeeSummary?

    enum CodingKeys: String, CodingKey {
        case id, kind, reason, status, createdAt, dueAt, decisionNote, autoApproved, employee
        case from = "startsAt"
        case to = "endsAt"
    }
}

private struct RequestBody: Encodable { let kind: String; let startsAt: Date; let endsAt: Date; let reason: String }
private struct RequestDecisionBody: Encodable { let status: String; let note: String? }

@MainActor private final class EmployeeRequestStore: ObservableObject {
    @Published private(set) var requests: [EmployeeRequest] = []
    @Published private(set) var approvals: [EmployeeRequest] = []
    @Published var message: String?

    func load(_ token: String?) async {
        guard let token else { return }
        do {
            async let mine: [EmployeeRequest] = APIClient.shared.request("me/requests", token: token)
            async let assigned: [EmployeeRequest] = APIClient.shared.request("me/requests/approvals", token: token)
            requests = try await mine
            approvals = try await assigned
        } catch { message = error.localizedDescription }
    }

    func submit(token: String?, kind: EmployeeRequestKind, from: Date, to: Date, reason: String) async -> Bool {
        guard let token else { return false }
        do {
            let _: EmployeeRequest = try await APIClient.shared.request("me/requests", method: "POST", token: token, body: RequestBody(kind: kind.rawValue, startsAt: from, endsAt: to, reason: reason))
            await load(token); return true
        } catch { message = error.localizedDescription; return false }
    }

    func cancel(token: String?, id: String) async {
        guard let token else { return }
        do { let _: EmployeeRequest = try await APIClient.shared.request("me/requests/\(id)", method: "DELETE", token: token); await load(token) }
        catch { message = error.localizedDescription }
    }

    func decide(token: String?, id: String, approved: Bool, note: String) async -> Bool {
        guard let token else { return false }
        do {
            let _: EmployeeRequest = try await APIClient.shared.request("me/requests/\(id)/decision", method: "PATCH", token: token, body: RequestDecisionBody(status: approved ? "approved" : "rejected", note: note.isEmpty ? nil : note))
            await load(token); return true
        } catch { message = error.localizedDescription; return false }
    }
}

private struct RequestsView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var store = EmployeeRequestStore()
    @State private var filter: EmployeeRequestStatus?
    @State private var composing = false
    @State private var reviewing: EmployeeRequest?
    @State private var cancelling: EmployeeRequest?
    @State private var filterIndex = 0
    private var combinedRequests: [EmployeeRequest] {
        var seen = Set<String>()
        return (store.approvals + store.requests)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private var visible: [EmployeeRequest] { filter.map { value in combinedRequests.filter { $0.status == value } } ?? combinedRequests }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterButton("Tất cả", nil)
                            ForEach(EmployeeRequestStatus.allCases, id: \.self) { filterButton($0.title, $0) }
                        }
                        .padding(.horizontal, 16)
                    }

                    TabView(selection: $filterIndex) {
                        ForEach(filterOptions.indices, id: \.self) { index in
                            requestPage(filterOptions[index])
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.easeInOut(duration: 0.22), value: filterIndex)
                }
                .padding(.top, 8)
                .onChange(of: filterIndex) { _, newIndex in
                    guard filterOptions.indices.contains(newIndex) else { return }
                    filter = filterOptions[newIndex]
                    UISelectionFeedbackGenerator().selectionChanged()
                }

                Button { composing = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 58, height: 58)
                        .background(AppTheme.red)
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                        .shadow(color: AppTheme.red.opacity(0.38), radius: 18, y: 9)
                }
                .accessibilityLabel("Tạo đơn mới")
                .padding(.trailing, 20)
                .padding(.bottom, 18)
            }
            .background(AppTheme.ink.ignoresSafeArea()).navigationTitle("Đơn từ của tôi")
            .sheet(isPresented: $composing) {
                RequestComposer { kind, from, to, reason in
                    Task { _ = await store.submit(token: session.token, kind: kind, from: from, to: to, reason: reason) }
                }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
            .sheet(item: $reviewing) { request in
                RequestDecisionView(request: request) { approved, note in
                    await store.decide(token: session.token, id: request.id, approved: approved, note: note)
                }
            }
            .alert(item: $cancelling) { request in
                Alert(
                    title: Text("Hủy đơn này?"),
                    message: Text("Đơn \(request.kind.title) sẽ chuyển sang trạng thái đã hủy và người quản lý sẽ nhận được thông báo. Thao tác không thể hoàn tác."),
                    primaryButton: .destructive(Text("Xác nhận hủy")) {
                        Task { await store.cancel(token: session.token, id: request.id) }
                    },
                    secondaryButton: .cancel(Text("Giữ lại"))
                )
            }
            .task { await store.load(session.token) }
            .refreshable { await store.load(session.token) }
            .alert("Đơn từ", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("Đóng") { store.message = nil } } message: { Text(store.message ?? "") }
        }
    }

    private func filterButton(_ title: String, _ value: EmployeeRequestStatus?) -> some View {
        Button(title) {
            guard let index = filterOptions.firstIndex(where: { $0 == value }) else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                filter = value
                filterIndex = index
            }
        }.font(.subheadline.bold()).padding(.horizontal, 14).padding(.vertical, 9)
            .background(filter == value ? AppTheme.red : AppTheme.card)
            .foregroundStyle(filter == value ? Color.white : Color.primary)
            .overlay(Capsule().stroke(filter == value ? Color.clear : Color.primary.opacity(0.12), lineWidth: 1))
            .clipShape(Capsule())
    }

    private var filterOptions: [EmployeeRequestStatus?] {
        [nil] + EmployeeRequestStatus.allCases.map(Optional.some)
    }

    @ViewBuilder private func requestPage(_ status: EmployeeRequestStatus?) -> some View {
        let requests = status.map { value in combinedRequests.filter { $0.status == value } } ?? combinedRequests
        ScrollView {
            if requests.isEmpty {
                ContentUnavailableView(
                    "Chưa có đơn",
                    systemImage: "doc.text",
                    description: Text("Không có đơn trong trạng thái này.")
                )
                .padding(.top, 70)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(requests) { request in
                        if store.approvals.contains(where: { $0.id == request.id && $0.status == .pending }) {
                            Button { reviewing = request } label: {
                                RequestCard(request: request, canCancel: false, cancel: {})
                            }
                            .buttonStyle(.plain)
                        } else {
                            RequestCard(request: request) { cancelling = request }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 92)
            }
        }
        .refreshable { await store.load(session.token) }
    }
}

private struct RequestCard: View {
    let request: EmployeeRequest
    var canCancel = true
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: request.kind.icon).frame(width: 42, height: 42).background(request.kind.color.opacity(0.16)).foregroundStyle(request.kind.color).clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.employee?.fullName ?? "Đơn của tôi").font(.headline)
                    HStack(spacing: 7) {
                        Text(request.kind.title).font(.caption.bold()).foregroundStyle(request.kind.color).padding(.horizontal, 9).padding(.vertical, 4).background(request.kind.color.opacity(0.14)).clipShape(Capsule())
                        Text(request.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(AppTheme.muted)
                    }
                }
                Spacer()
                Text(request.status.title).font(.caption.bold()).foregroundStyle(request.status.color).padding(.horizontal, 10).padding(.vertical, 6).background(request.status.color.opacity(0.14)).clipShape(Capsule())
            }
            Label("\(request.from.formatted(date: .abbreviated, time: .shortened)) – \(request.to.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar").font(.subheadline).foregroundStyle(AppTheme.muted)
            Text(request.reason).font(.subheadline)
            if let note = request.decisionNote, !note.isEmpty { Label(note, systemImage: "text.bubble").font(.caption).foregroundStyle(AppTheme.muted) }
            if canCancel && request.status == .pending { Button("Hủy đơn", role: .destructive, action: cancel).font(.subheadline.bold()).frame(maxWidth: .infinity, alignment: .trailing) }
        }.padding(16).background(LinearGradient(colors: [request.kind.color.opacity(0.09), AppTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing)).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(request.kind.color.opacity(0.22), lineWidth: 1))
    }
}

private struct RequestDecisionView: View {
    let request: EmployeeRequest
    let decide: (Bool, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var working = false
    @State private var rejecting = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                RequestCard(request: request, canCancel: false, cancel: {})
                Text(rejecting ? "Lý do từ chối" : "Ghi chú cho nhân viên (tùy chọn)").font(.headline)
                TextEditor(text: $note).scrollContentBackground(.hidden).padding(12).frame(minHeight: 130)
                    .background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 18))
                if rejecting { Text("Lý do từ chối là bắt buộc, tối thiểu 5 ký tự.").font(.caption).foregroundStyle(AppTheme.red) }
                HStack(spacing: 12) {
                    Button("Từ chối") { rejecting = true }.buttonStyle(.bordered).tint(AppTheme.red)
                    Button(rejecting ? "Xác nhận từ chối" : "Duyệt đơn") {
                        Task { working = true; if await decide(!rejecting, note.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }; working = false }
                    }
                    .buttonStyle(.borderedProminent).tint(rejecting ? AppTheme.red : .green)
                    .disabled(working || (rejecting && note.trimmingCharacters(in: .whitespacesAndNewlines).count < 5))
                }.frame(maxWidth: .infinity, alignment: .trailing)
                Spacer()
            }.padding(20).background(AppTheme.ink.ignoresSafeArea()).navigationTitle("Xử lý đơn")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } } }
        }
    }
}

private struct RequestComposer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind = EmployeeRequestKind.leave
    @State private var from = Date()
    @State private var to = Calendar.current.date(byAdding: .hour, value: 8, to: Date()) ?? Date()
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool
    let submit: (EmployeeRequestKind, Date, Date, String) -> Void
    private var cleanReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { cleanReason.count >= 10 && to >= from }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(AppTheme.red.opacity(0.16))
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 25, weight: .semibold))
                                .foregroundStyle(AppTheme.red)
                        }
                        .frame(width: 52, height: 52)

                        Text("Tạo đơn mới")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Điền thông tin rõ ràng để đơn được xử lý nhanh hơn.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.muted)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        composerLabel("Loại đơn", icon: "square.grid.2x2")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(EmployeeRequestKind.allCases) { item in
                                Button { kind = item } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: item.icon)
                                            .font(.system(size: 16, weight: .semibold))
                                        Text(item.title)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 13)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(kind == item ? item.color.opacity(0.2) : AppTheme.card)
                                    .foregroundStyle(kind == item ? item.color : Color.primary)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(kind == item ? item.color.opacity(0.75) : Color.primary.opacity(0.12), lineWidth: 1)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        composerLabel("Thời gian", icon: "calendar")
                        VStack(spacing: 0) {
                            dateRow("Bắt đầu", selection: $from)
                            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 44)
                            dateRow("Kết thúc", selection: $to, range: from...)
                        }
                        .padding(.horizontal, 14)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        composerLabel("Nội dung đơn", icon: "text.alignleft")
                        ZStack(alignment: .topLeading) {
                            if reason.isEmpty {
                                Text("Mô tả lý do và thông tin cần người duyệt lưu ý...")
                                    .font(.body)
                                    .foregroundStyle(AppTheme.muted.opacity(0.72))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 17)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $reason)
                                .focused($reasonFocused)
                                .scrollContentBackground(.hidden)
                                .padding(11)
                                .frame(minHeight: 150)
                                .background(Color.clear)
                        }
                        .background(AppTheme.card)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(reasonFocused ? AppTheme.red.opacity(0.78) : Color.white.opacity(0.08), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        HStack {
                            Label(cleanReason.count >= 10 ? "Nội dung hợp lệ" : "Tối thiểu 10 ký tự", systemImage: cleanReason.count >= 10 ? "checkmark.circle.fill" : "info.circle")
                                .foregroundStyle(cleanReason.count >= 10 ? Color.green : AppTheme.muted)
                            Spacer()
                            Text("\(reason.count) ký tự").foregroundStyle(AppTheme.muted)
                        }
                        .font(.caption.weight(.medium))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 120)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hủy") { dismiss() }
                        .foregroundStyle(AppTheme.muted)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    submit(kind, from, to, cleanReason)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "paperplane.fill")
                        Text("Gửi đơn")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(canSubmit ? AppTheme.red : Color.white.opacity(0.08))
                    .foregroundStyle(canSubmit ? Color.white : AppTheme.muted)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: canSubmit ? AppTheme.red.opacity(0.28) : .clear, radius: 16, y: 7)
                }
                .disabled(!canSubmit)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(.ultraThinMaterial)
            }
            .onChange(of: from) { oldValue, newValue in
                if to < newValue {
                    let previousDuration = max(to.timeIntervalSince(oldValue), 60 * 60)
                    to = newValue.addingTimeInterval(previousDuration)
                }
            }
        }
    }

    private func composerLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func dateRow(_ title: String, selection: Binding<Date>, range: PartialRangeFrom<Date>? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: title == "Bắt đầu" ? "arrow.right.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(title == "Bắt đầu" ? AppTheme.red : Color.green)
                .font(.system(size: 20))
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if let range {
                DatePicker("", selection: selection, in: range)
                    .labelsHidden()
            } else {
                DatePicker("", selection: selection)
                    .labelsHidden()
            }
        }
        .frame(minHeight: 58)
    }
}

private struct RequestNotification: Decodable, Identifiable {
    let id: String
    let type: String
    let title: String
    let message: String
    let requestId: String?
    let read: Bool
    let createdAt: Date
}
private struct UpdateCount: Decodable { let count: Int }

private struct NotificationsView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var requestStore = EmployeeRequestStore()
    @State private var requestNotifications: [RequestNotification] = []
    @State private var reviewing: EmployeeRequest?
    @State private var viewing: EmployeeRequest?
    @State private var confirmClear = false
    @State private var hiddenArticleIDs = Set<String>()
    private var items: [ContentItem] { (session.dashboard?.contentItems ?? []).filter { !hiddenArticleIDs.contains($0.id) } }
    private var totalUnread: Int { session.unreadCount + requestNotifications.filter { !$0.read }.count }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    HStack {
                        Text(totalUnread == 0 ? "Bạn đã đọc tất cả thông báo" : "\(totalUnread) thông báo chưa đọc").font(.subheadline.bold())
                        Spacer()
                        if !requestNotifications.isEmpty || !items.isEmpty { Button("Xóa tất cả", role: .destructive) { confirmClear = true }.font(.subheadline.bold()) }
                    }
                    ForEach(requestNotifications) { item in
                        SwipeDeleteRow(onDelete: { Task { await deleteNotification(item) } }) {
                          Button { Task { await open(item) } } label: {
                          HStack(alignment: .top, spacing: 14) {
                            Image(systemName: notificationIcon(item)).frame(width: 44, height: 44).background(notificationColor(item).opacity(0.16)).foregroundStyle(notificationColor(item)).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.headline)
                                if let request = linkedRequest(item) {
                                    Text(request.kind.title).font(.caption.bold()).foregroundStyle(request.kind.color).padding(.horizontal, 9).padding(.vertical, 4).background(request.kind.color.opacity(0.13)).clipShape(Capsule())
                                }
                                Text(item.message).font(.subheadline).foregroundStyle(AppTheme.muted)
                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(AppTheme.red)
                            }
                            Spacer()
                            if !item.read { Circle().fill(AppTheme.red).frame(width: 8, height: 8) }
                          }.padding(16).background(item.read ? AppTheme.card : Color.white.opacity(0.115)).overlay { RoundedRectangle(cornerRadius: 20).stroke(item.read ? Color.clear : notificationColor(item).opacity(0.32)) }.clipShape(RoundedRectangle(cornerRadius: 20))
                          }.buttonStyle(.plain)
                        }
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SwipeDeleteRow(onDelete: { hideArticle(item) }) {
                          NavigationLink(destination: ArticleDetailView(item: item)) {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "megaphone.fill").frame(width: 44, height: 44).background(AppTheme.red.opacity(0.16)).foregroundStyle(AppTheme.red).clipShape(RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title).font(.headline).multilineTextAlignment(.leading)
                                    Text(item.preview).font(.subheadline).foregroundStyle(AppTheme.muted).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(AppTheme.red)
                                }
                                Spacer(minLength: 0)
                            }.padding(16).background(index < session.unreadCount ? Color.white.opacity(0.115) : AppTheme.card).overlay { RoundedRectangle(cornerRadius: 20).stroke(index < session.unreadCount ? AppTheme.red.opacity(0.3) : Color.clear) }.clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                          }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { session.markArticlesRead() })
                        }
                    }
                    if items.isEmpty && requestNotifications.isEmpty { ContentUnavailableView("Chưa có thông báo", systemImage: "bell.slash").padding(.top, 70) }
                }.padding(16)
            }.background(AppTheme.ink.ignoresSafeArea()).navigationTitle("Thông báo")
                .refreshable { await session.refreshDashboard(); await loadRequestNotifications() }
                .task { hiddenArticleIDs = Set(UserDefaults.standard.stringArray(forKey: "hidden-notification-articles") ?? []); await loadRequestNotifications() }
                .onChange(of: session.requestUnreadCount) { _, _ in Task { await loadRequestNotifications() } }
                .confirmationDialog("Xóa tất cả thông báo?", isPresented: $confirmClear, titleVisibility: .visible) { Button("Xóa tất cả", role: .destructive) { Task { await clearAll() } }; Button("Hủy", role: .cancel) {} }
                .sheet(item: $reviewing) { request in RequestDecisionView(request: request) { approved, note in await requestStore.decide(token: session.token, id: request.id, approved: approved, note: note) } }
                .sheet(item: $viewing) { request in RequestNotificationDetail(request: request) }
        }
    }

    private func loadRequestNotifications() async {
        guard let token = session.token else { return }
        if let values: [RequestNotification] = try? await APIClient.shared.request("me/requests/notifications", token: token) {
            requestNotifications = values
            session.requestUnreadCount = values.filter { !$0.read }.count
            await requestStore.load(token)
        }
    }

    private func open(_ item: RequestNotification) async {
        guard let token = session.token else { return }
        let _: UpdateCount? = try? await APIClient.shared.request("me/requests/notifications/\(item.id)/read", method: "PATCH", token: token)
        await requestStore.load(token)
        if let id = item.requestId {
            if item.type == "request_pending", let request = requestStore.approvals.first(where: { $0.id == id && $0.status == .pending }) { reviewing = request }
            else { viewing = (requestStore.requests + requestStore.approvals).first(where: { $0.id == id }) }
        }
        await loadRequestNotifications()
    }

    private func clearAll() async {
        guard let token = session.token else { return }
        let _: UpdateCount? = try? await APIClient.shared.request("me/requests/notifications", method: "DELETE", token: token)
        hiddenArticleIDs.formUnion(items.map(\.id)); UserDefaults.standard.set(Array(hiddenArticleIDs), forKey: "hidden-notification-articles")
        session.markArticlesRead(); await loadRequestNotifications()
    }

    private func deleteNotification(_ item: RequestNotification) async {
        guard let token = session.token else { return }
        withAnimation(.snappy(duration: 0.28)) {
            requestNotifications.removeAll { $0.id == item.id }
        }
        session.requestUnreadCount = requestNotifications.filter { !$0.read }.count
        let _: UpdateCount? = try? await APIClient.shared.request(
            "me/requests/notifications/\(item.id)", method: "DELETE", token: token
        )
    }

    private func hideArticle(_ item: ContentItem) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.snappy(duration: 0.28)) { hiddenArticleIDs.insert(item.id) }
        UserDefaults.standard.set(Array(hiddenArticleIDs), forKey: "hidden-notification-articles")
    }

    private func linkedRequest(_ item: RequestNotification) -> EmployeeRequest? {
        guard let id = item.requestId else { return nil }
        return (requestStore.requests + requestStore.approvals).first { $0.id == id }
    }
    private func notificationIcon(_ item: RequestNotification) -> String {
        let type = item.type
        if type == "request_pending", let request = linkedRequest(item) { return request.kind.icon }
        if type == "request_pending" { return "clock.badge.exclamationmark.fill" }
        if type.contains("rejected") { return "xmark.circle.fill" }
        if type.contains("cancelled") { return "minus.circle.fill" }
        if type.contains("auto_approved") { return "timer.circle.fill" }
        return "checkmark.seal.fill"
    }
    private func notificationColor(_ item: RequestNotification) -> Color {
        let type = item.type
        if type == "request_pending", let request = linkedRequest(item) { return request.kind.color }
        if type == "request_pending" { return .orange }
        if type.contains("rejected") { return AppTheme.red }
        if type.contains("cancelled") { return .gray }
        return .green
    }
}

private struct SwipeDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    let content: Content
    @State private var offset: CGFloat = 0

    init(onDelete: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onDelete = onDelete
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            LinearGradient(
                colors: [Color(red: 0.96, green: 0.22, blue: 0.24), Color(red: 0.67, green: 0.04, blue: 0.08)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .overlay(alignment: .trailing) {
                Button(action: performDelete) {
                    VStack(spacing: 5) {
                        Image(systemName: "trash.fill").font(.title3.bold())
                        Text("Xóa").font(.caption.bold())
                    }
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 64)
                }
                .buttonStyle(.plain)
                .scaleEffect(offset < -35 ? 1 : 0.78)
                .opacity(offset < -10 ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            content
                .offset(x: offset)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .highPriorityGesture(swipeGesture, including: .all)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard value.translation.width < 0,
                      abs(value.translation.width) > abs(value.translation.height) * 1.05 else { return }
                offset = max(-260, value.translation.width)
            }
            .onEnded { value in
                if value.translation.width < -165 || value.predictedEndTranslation.width < -250 {
                    performDelete()
                } else if value.translation.width < -36 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { offset = -88 }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { offset = 0 }
                }
            }
    }

    private func performDelete() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeIn(duration: 0.2)) { offset = -UIScreen.main.bounds.width }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { onDelete() }
    }
}

private struct RequestNotificationDetail: View {
    let request: EmployeeRequest
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 18) { RequestCard(request: request, canCancel: false, cancel: {}); if request.autoApproved { Label("Tự động duyệt sau 4 giờ", systemImage: "timer").foregroundStyle(.green) } }.padding(20) }.background(AppTheme.ink.ignoresSafeArea()).navigationTitle("Chi tiết đơn").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } } } } }
}

private struct NewsView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var query = ""

    private var items: [ContentItem] {
        let all = session.dashboard?.contentItems ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.plainBody.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(destination: ArticleDetailView(item: item)) {
                            ArticleRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                    if items.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "newspaper").font(.largeTitle).foregroundColor(AppTheme.muted)
                            Text("Chưa có bài viết phù hợp").foregroundColor(AppTheme.muted)
                        }.padding(.top, 80)
                    }
                }
                .padding(18)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("Bài viết nội bộ")
            .searchable(text: $query, prompt: "Tìm bài viết")
            .refreshable { await session.refreshDashboard() }
            .onAppear { session.markArticlesRead() }
        }
        .navigationViewStyle(.stack)
    }
}

private struct ArticleRow: View {
    let item: ContentItem
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(item.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.red)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(AppTheme.muted)
            }
            Text(item.title).font(.headline).multilineTextAlignment(.leading)
            Text(item.preview)
                .font(.subheadline)
                .foregroundColor(AppTheme.muted)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ArticleDetailView: View {
    let item: ContentItem
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text(item.createdAt.formatted(date: .long, time: .shortened))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.red)
                Text(item.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Divider().overlay(Color.white.opacity(0.12))
                ForEach(item.articleBlocks) { block in
                    ArticleBlockView(block: block)
                }
            }
            .padding(22)
        }
        .background(AppTheme.ink.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ArticleBlockView: View {
    let block: ArticleBlock

    @ViewBuilder
    var body: some View {
        switch block.kind {
        case .heading(let level):
            VStack(alignment: .leading, spacing: 10) {
                Text(block.text)
                    .font(headingFont(level))
                    .fontWeight(.bold)
                    .foregroundColor(level <= 1 ? .white : Color(red: 0.52, green: 0.86, blue: 0.68))
                    .frame(maxWidth: .infinity, alignment: level == 1 ? .center : .leading)
                if level == 2 {
                    Rectangle()
                        .fill(Color(red: 0.18, green: 0.54, blue: 0.35))
                        .frame(height: 2)
                }
            }
            .padding(level == 1 ? 22 : 0)
            .background(level == 1 ? Color(red: 0.08, green: 0.27, blue: 0.19) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        case .paragraph:
            Text(block.text)
                .font(.body)
                .lineSpacing(7)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .listItem:
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color(red: 0.18, green: 0.54, blue: 0.35))
                    .frame(width: 7, height: 7)
                    .padding(.top, 8)
                Text(block.text)
                    .lineSpacing(6)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)

        case .image(let url, let alt):
            VStack(spacing: 10) {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure:
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(AppTheme.muted)
                                .frame(maxWidth: .infinity, minHeight: 140)
                        default:
                            ProgressView()
                                .tint(AppTheme.red)
                                .frame(maxWidth: .infinity, minHeight: 180)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !alt.isEmpty {
                    Text(alt)
                        .font(.caption)
                        .foregroundColor(AppTheme.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(12)
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        case .tableRow:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text.replacingOccurrences(of: "\n", with: "  |  "))
                    .font(.system(.subheadline, design: .rounded))
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .question:
            HStack(alignment: .top, spacing: 12) {
                Text("Q")
                    .font(.caption.bold())
                    .frame(width: 28, height: 28)
                    .background(Color(red: 0.18, green: 0.54, blue: 0.35))
                    .clipShape(Circle())
                Text(block.text).font(.headline)
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 27, weight: .bold, design: .rounded)
        case 2: return .system(size: 23, weight: .bold, design: .rounded)
        default: return .system(size: 19, weight: .bold, design: .rounded)
        }
    }
}

private struct ProfileView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var showDelete = false
    @State private var password = ""
    @State private var showPasswordChange = false
    @State private var showPasswordChangeLimit = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {
                    ZStack {
                        Circle().fill(AppTheme.red.opacity(0.18)).frame(width: 96, height: 96)
                        Text(initials).font(.title.bold()).foregroundColor(AppTheme.red)
                    }
                    Text(session.profile?.name ?? "Nhân viên").font(.title2.bold())
                    Text(session.profile?.employeeCode ?? "").font(.subheadline.monospaced()).foregroundColor(AppTheme.muted)

                    accountSectionTitle("THÔNG TIN TÀI KHOẢN")
                    VStack(spacing: 0) {
                        ProfileLine(label: "Vai trò", value: session.profile?.role ?? "")
                        Divider().padding(.leading, 18)
                        ProfileLine(label: "Loại tài khoản", value: accountType)
                    }
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                    accountSectionTitle("BẢO MẬT")
                    Button {
                        if !session.hasLinkedEmail { session.presentMissingEmailForPasswordChange() }
                        else if passwordChangedThisMonth { showPasswordChangeLimit = true }
                        else { showPasswordChange = true }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "key.fill").foregroundColor(AppTheme.red).frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Đổi mật khẩu").font(.headline).foregroundColor(.primary)
                                Text(passwordChangeDescription)
                                    .font(.caption).foregroundColor(AppTheme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(AppTheme.muted)
                        }.padding(18)
                    }
                    .buttonStyle(.plain)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    HStack(spacing: 14) {
                        Image(systemName: session.biometricIcon)
                            .font(.title3)
                            .foregroundColor(AppTheme.red)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Đăng nhập bằng \(session.biometricName)")
                                .font(.headline)
                            Text("Dùng sinh trắc học thay cho mật khẩu ở lần đăng nhập sau.")
                                .font(.caption)
                                .foregroundColor(AppTheme.muted)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { session.biometricsEnabled },
                            set: { session.setBiometricLogin(enabled: $0) }
                        ))
                        .labelsHidden()
                        .tint(AppTheme.red)
                    }
                    .padding(18)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    accountSectionTitle("QUYỀN RIÊNG TƯ & HỖ TRỢ")
                    VStack(spacing: 0) {
                        Link(destination: URL(string: "https://sukavinagroup.net/privacy-policy")!) {
                            accountLink(icon: "hand.raised.fill", title: "Chính sách quyền riêng tư")
                        }
                        Divider().padding(.leading, 58)
                        Link(destination: URL(string: "https://sukavinagroup.net/support")!) {
                            accountLink(icon: "questionmark.circle.fill", title: "Hỗ trợ người dùng")
                        }
                        Divider().padding(.leading, 58)
                        Link(destination: URL(string: "https://sukavinagroup.net/account-deletion")!) {
                            accountLink(icon: "person.crop.circle.badge.minus", title: "Hướng dẫn xóa tài khoản")
                        }
                        Divider().padding(.leading, 58)
                        Link(destination: URL(string: UIApplication.openNotificationSettingsURLString)!) {
                            accountLink(icon: "bell.badge.fill", title: "Cài đặt thông báo")
                        }
                    }
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    accountSectionTitle("PHIÊN ĐĂNG NHẬP")
                    Button("Đăng xuất", role: .destructive) { session.signOut() }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    if session.profile?.protected != true && session.profile?.accountType != "SUPER_ADMIN" {
                        accountSectionTitle("VÙNG NGUY HIỂM")
                        Button("Yêu cầu xóa tài khoản", role: .destructive) { showDelete = true }
                            .font(.footnote.weight(.semibold))
                    }
                }
                .padding(22)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("Tài khoản")
            .alert("Xóa tài khoản vĩnh viễn?", isPresented: $showDelete) {
                SecureField("Mật khẩu", text: $password)
                Button("Hủy", role: .cancel) { password = "" }
                Button("Xóa vĩnh viễn", role: .destructive) {
                    Task { if await session.deleteAccount(password: password) { password = "" } }
                }
            } message: {
                Text("Toàn bộ tài khoản và dữ liệu cá nhân sẽ bị xóa. Hành động này không thể hoàn tác.")
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showPasswordChange) {
            PasswordChangeView().environmentObject(session)
        }
        .alert("Chưa thể đổi mật khẩu", isPresented: $showPasswordChangeLimit) {
            Button("Đã hiểu", role: .cancel) {}
        } message: {
            Text("Bạn chỉ được đổi mật khẩu một lần mỗi tháng. Bạn có thể đổi lại từ ngày 01/\(nextPasswordChangeMonth).")
        }
    }

    private var initials: String {
        let words = (session.profile?.name ?? "NV").split(separator: " ")
        return words.suffix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
    private var accountType: String {
        switch session.profile?.accountType {
        case "SUPER_ADMIN": return "Quản trị viên tổng"
        case "ADMIN": return "Quản trị viên"
        default: return "Nhân viên"
        }
    }
    private var passwordChangedThisMonth: Bool {
        if isAdminAccount { return false }
        guard let changedAt = session.profile?.passwordChangedAt else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        return calendar.isDate(changedAt, equalTo: Date(), toGranularity: .month)
    }
    private var isAdminAccount: Bool {
        session.profile?.accountType == "ADMIN" || session.profile?.accountType == "SUPER_ADMIN"
    }
    private var passwordChangeDescription: String {
        isAdminAccount
            ? "Xác thực OTP qua email, không giới hạn số lần đổi."
            : "Xác thực OTP qua email, tối đa một lần mỗi tháng."
    }
    private func accountSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .tracking(1.2)
            .foregroundColor(AppTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }
    private func accountLink(icon: String, title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundColor(AppTheme.red).frame(width: 26)
            Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
            Spacer()
            Image(systemName: "arrow.up.right").font(.caption.bold()).foregroundColor(AppTheme.muted)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
    }
    private var nextPasswordChangeMonth: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        let next = calendar.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        return next.formatted(.dateTime.month(.twoDigits).year())
    }
}

private struct PasswordChangeView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var otpSent = false
    @State private var completed = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(AppTheme.red.opacity(0.14)).frame(width: 58, height: 58)
                            Image(systemName: "key.fill").font(.title2).foregroundColor(AppTheme.red)
                        }
                        Text("Bảo vệ tài khoản").font(.title2.bold())
                        Text("Xác minh email trước khi thiết lập mật khẩu mới.")
                            .font(.subheadline).foregroundColor(AppTheme.muted)
                    }

                    HStack(spacing: 10) {
                        stepBadge(number: 1, title: "Nhận OTP", active: true)
                        Rectangle().fill(otpSent ? AppTheme.red : AppTheme.fieldBorder).frame(height: 2)
                        stepBadge(number: 2, title: "Mật khẩu mới", active: otpSent)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Label(otpSent ? "OTP đã gửi tới \(email)" : "Xác minh qua email", systemImage: "envelope.badge.fill")
                            .font(.headline).foregroundColor(AppTheme.red)
                        Text(otpSent
                             ? "Mã gồm 6 số và có hiệu lực trong 10 phút."
                             : "Mã OTP sẽ được gửi tới email liên kết. Nếu chưa có email, vui lòng liên hệ Nhân sự để cập nhật.")
                            .font(.subheadline).foregroundColor(AppTheme.muted)
                    }
                    .padding(18).background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.cardBorder))

                    if otpSent {
                        VStack(spacing: 14) {
                            NativeField(title: "Mã OTP gồm 6 số", text: $code, icon: "number", keyboard: .numberPad)
                            NativeSecureField(title: "Mật khẩu mới, ít nhất 6 ký tự", text: $newPassword)
                            NativeSecureField(title: "Nhập lại mật khẩu mới", text: $confirmPassword)
                            if !confirmPassword.isEmpty && newPassword != confirmPassword {
                                Label("Mật khẩu nhập lại chưa khớp", systemImage: "exclamationmark.circle.fill")
                                    .font(.caption).foregroundColor(AppTheme.red).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(18).background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    Button {
                        if otpSent {
                            Task {
                                if await session.confirmPasswordChange(code: code, newPassword: newPassword) { completed = true }
                            }
                        } else {
                            Task {
                                if let response = await session.requestPasswordChange() {
                                    email = response.email
                                    otpSent = true
                                } else if session.passwordChangeRequiresEmail {
                                    dismiss()
                                }
                            }
                        }
                    } label: {
                        HStack {
                            if session.isWorking { ProgressView().tint(.white) }
                            Text(otpSent ? "Xác nhận đổi mật khẩu" : "Gửi mã OTP").fontWeight(.bold)
                            Spacer()
                            Image(systemName: otpSent ? "checkmark.shield.fill" : "arrow.right")
                        }.padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.plain).foregroundColor(.white).background(AppTheme.red)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .disabled(session.isWorking || (otpSent && !canConfirm))
                    .opacity(session.isWorking || (otpSent && !canConfirm) ? 0.55 : 1)
                }
                .padding(22)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("Đổi mật khẩu")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } } }
            .alert("Đổi mật khẩu thành công", isPresented: $completed) {
                Button("Hoàn tất") { dismiss() }
            } message: {
                Text("Bạn có thể đổi lại vào tháng tiếp theo. Đăng nhập sinh trắc học đã được tắt để bảo vệ tài khoản.")
            }
        }.navigationViewStyle(.stack)
    }

    private var canConfirm: Bool {
        code.count == 6 && code.allSatisfy(\.isNumber) && newPassword.count >= 6 && newPassword == confirmPassword
    }

    @ViewBuilder
    private func stepBadge(number: Int, title: String, active: Bool) -> some View {
        HStack(spacing: 7) {
            Text("\(number)").font(.caption.bold()).foregroundColor(active ? .white : AppTheme.muted)
                .frame(width: 25, height: 25).background(active ? AppTheme.red : AppTheme.field)
                .clipShape(Circle())
            Text(title).font(.caption.weight(.semibold)).foregroundColor(active ? .primary : AppTheme.muted)
        }.fixedSize()
    }
}

private struct ProfileLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(AppTheme.muted)
            Spacer()
            Text(value).fontWeight(.medium)
        }.padding(18)
    }
}

private struct NativeField: View {
    let title: String
    @Binding var text: String
    let icon: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundColor(AppTheme.muted)
            TextField(title, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(AppTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AppTheme.fieldBorder, lineWidth: 1))
    }
}

private struct NativeSecureField: View {
    let title: String
    @Binding var text: String
    @State private var visible = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").frame(width: 22).foregroundColor(AppTheme.muted)
            Group {
                if visible { TextField(title, text: $text) }
                else { SecureField(title, text: $text) }
            }
            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
            }.foregroundColor(AppTheme.muted)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(AppTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AppTheme.fieldBorder, lineWidth: 1))
    }
}

private extension String {
    var safeHTMLText: String {
        let maximumCharacters = 750_000
        var output = String()
        output.reserveCapacity(Swift.min(count, maximumCharacters))
        var tag = String()
        var isInsideTag = false
        var written = 0

        for character in self {
            if written >= maximumCharacters {
                output.append("\n\n[Nội dung đã được rút gọn để bảo đảm ứng dụng hoạt động ổn định.]")
                break
            }
            if character == "<" {
                isInsideTag = true
                tag.removeAll(keepingCapacity: true)
                continue
            }
            if isInsideTag {
                if character == ">" {
                    isInsideTag = false
                    let name = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if name.hasPrefix("br") || name.hasPrefix("/p") || name.hasPrefix("/div") ||
                        name.hasPrefix("/li") || name.hasPrefix("/h") || name.hasPrefix("hr") {
                        if output.last != "\n" { output.append("\n") }
                    } else if name.hasPrefix("/td") || name.hasPrefix("/th") {
                        output.append(" | ")
                    } else if name.hasPrefix("li") {
                        if output.last != "\n" { output.append("\n") }
                        output.append("• ")
                    }
                } else if tag.count < 80 {
                    tag.append(character)
                }
                continue
            }
            output.append(character)
            written += 1
        }

        let decoded = output
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        var lines: [String] = []
        var previousWasEmpty = false
        for rawLine in decoded.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !previousWasEmpty && !lines.isEmpty { lines.append("") }
                previousWasEmpty = true
            } else {
                lines.append(line)
                previousWasEmpty = false
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var readingChunks: [String] {
        let maximumChunkLength = 1_800
        var chunks: [String] = []
        for paragraph in components(separatedBy: "\n\n") where !paragraph.isEmpty {
            var remainder = paragraph[...]
            while remainder.count > maximumChunkLength {
                let tentativeEnd = remainder.index(remainder.startIndex, offsetBy: maximumChunkLength)
                let split = remainder[..<tentativeEnd].lastIndex(of: " ") ?? tentativeEnd
                chunks.append(String(remainder[..<split]))
                remainder = remainder[split...].drop(while: { $0 == " " })
            }
            if !remainder.isEmpty { chunks.append(String(remainder)) }
        }
        return chunks.isEmpty ? [self] : chunks
    }
}

#if DEBUG
private struct SukavinaPreviewContainer: View {
    @StateObject private var session: SessionStore
    private let mode: SessionStore.State

    init(mode: SessionStore.State) {
        self.mode = mode
        let previewSession = SessionStore()
        previewSession.state = mode
        if mode == .signedIn {
            previewSession.profile = Profile(
                id: "preview", employeeCode: "SKV-001", name: "Nguyễn Văn A",
                role: "Nhân viên", accountType: "EMPLOYEE", permissions: [], protected: false
            )
            previewSession.dashboard = Dashboard(
                employeeCode: "SKV-001", fullName: "Nguyễn Văn A", role: "Nhân sự vận hành",
                remainingLeaveDays: 8, attendanceStatus: "Đã ghi nhận", payrollStatus: "Đã cập nhật",
                name: "Nguyễn Văn A", attendanceRecords: [], contentItems: []
            )
        }
        _session = StateObject(wrappedValue: previewSession)
    }

    var body: some View {
        Group {
            switch mode {
            case .restoring: NativeLaunchView()
            case .signedOut: AuthenticationView().environmentObject(session)
            case .signedIn: EmployeePortalView().environmentObject(session)
            }
        }
    }
}

private struct SukavinaAppPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            SukavinaPreviewContainer(mode: .signedOut)
                .previewDisplayName("Đăng nhập")
            SukavinaPreviewContainer(mode: .signedIn)
                .previewDisplayName("Trang chủ nhân viên")
            SukavinaPreviewContainer(mode: .restoring)
                .previewDisplayName("Khởi động")
        }
    }
}
#endif
