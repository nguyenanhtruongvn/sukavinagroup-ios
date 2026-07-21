import UIKit
import SwiftUI
import Security
import UserNotifications
import Network
import LocalAuthentication

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
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1) : UIColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1)
    })
    static let card = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1) : UIColor.white
    })
    static let muted = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.66, green: 0.65, blue: 0.68, alpha: 1) : UIColor(red: 0.36, green: 0.35, blue: 0.38, alpha: 1)
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
        body: Body? = nil
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw NetworkError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        var data: Data
        var response: URLResponse
        let primaryHost = url.host ?? "unknown"
        ConnectionDiagnostics.record("API primary start: \(method) \(primaryHost)/\(path)")
        do {
            (data, response) = try await NetworkSessions.api.data(for: request)
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
            request.url = fallbackURL
            let fallbackHost = fallbackURL.host ?? "unknown"
            ConnectionDiagnostics.record("API fallback start: \(method) \(fallbackHost)/\(path)")
            do {
                (data, response) = try await NetworkSessions.api.data(for: request)
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
    private static let account = "access-token"

    static func save(token: String) {
        let data = Data(token.utf8)
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
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
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
    let user: UserSummary
}

private struct Profile: Decodable {
    let id: String
    let employeeCode: String
    let name: String
    let role: String
    let accountType: String
    let permissions: [String]
    let protected: Bool
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

private struct AttendanceMonth: Decodable {
    let month: String
    let days: [AttendanceDay]
}

private struct AttendanceDay: Decodable, Identifiable {
    let date: String
    let checkIn: String?
    let checkOut: String?
    let punchCount: Int
    let sources: [String]
    let punches: [AttendancePunch]
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
private struct MessageResponse: Decodable { let message: String }
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

    private(set) var token: String?
    private var knownArticleIDs: Set<String> = []
    private let knownArticlesKey = "known-native-article-ids"
    private var eventStreamTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "net.sukavinagroup.network-path")
    private var isMonitoringNetwork = false
    private var lastPathStatus: NWPath.Status?
    private var lastPathWasCellular: Bool?

    func restore() async {
        startNetworkMonitoring()
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let savedToken = KeychainStore.loadToken() else {
            state = .signedOut
            return
        }
        token = savedToken
        loadKnownArticles()
        state = .signedIn
        startNetworkMonitoring()
        do {
            profile = try await APIClient.shared.request("auth/me", token: savedToken)
            await NotificationManager.shared.requestAuthorizationIfNeeded()
            await refreshDashboard()
            startRealTimeUpdates()
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
            token = response.accessToken
            KeychainStore.save(token: response.accessToken)
            loadKnownArticles()
            profile = Profile(
                id: "",
                employeeCode: response.user.employeeCode,
                name: response.user.name,
                role: response.user.role,
                accountType: response.user.accountType,
                permissions: response.user.permissions,
                protected: response.user.protected
            )
            state = .signedIn
            startNetworkMonitoring()
            await NotificationManager.shared.requestAuthorizationIfNeeded()
            await refreshDashboard()
            startRealTimeUpdates()
            ConnectionDiagnostics.record("Sign-in completed successfully")
            return true
        } catch {
            ConnectionDiagnostics.record("Sign-in failed: \(error.localizedDescription)")
            present(error)
            return false
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
            token = savedToken
            profile = freshProfile
            state = .signedIn
            startNetworkMonitoring()
            await refreshDashboard()
            startRealTimeUpdates()
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
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError),
                  let token,
                  BiometricKeychain.save(token: token) else {
                biometricsEnabled = false
                errorTitle = "Không thể bật sinh trắc học"
                errorMessage = "Thiết bị chưa thiết lập Face ID/Touch ID hoặc chưa bật mật mã màn hình."
                return
            }
            BiometricPreferences.enabled = true
            biometricsEnabled = true
        } else {
            disableBiometricLogin()
        }
    }

    private func disableBiometricLogin() {
        BiometricKeychain.clear()
        BiometricPreferences.enabled = false
        biometricsEnabled = false
    }

    func refreshDashboard() async {
        guard let token else { return }
        do {
            let fresh: Dashboard = try await APIClient.shared.request("me/dashboard", token: token)
            processNewArticles(fresh.contentItems)
            dashboard = fresh
            await refreshRequestNotificationCount()
        } catch {
            present(error)
        }
    }

    func signOut() {
        eventStreamTask?.cancel()
        eventStreamTask = nil
        KeychainStore.clear()
        token = nil
        profile = nil
        dashboard = nil
        unreadCount = 0
        requestUnreadCount = 0
        state = .signedOut
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
                Color.black.opacity(0.62)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { session.dismissError() }

                ElegantAppAlert(
                    title: session.errorTitle,
                    message: message,
                    offersSettings: session.errorOffersSettings,
                    dismiss: { session.dismissError() }
                )
                .padding(24)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
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
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(AppTheme.red.opacity(0.16))
                    .frame(width: 68, height: 68)
                Circle()
                    .stroke(AppTheme.red.opacity(0.28), lineWidth: 1)
                    .frame(width: 68, height: 68)
                Image(systemName: offersSettings ? "antenna.radiowaves.left.and.right.slash" : "exclamationmark.shield.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundColor(AppTheme.red)
            }
            .padding(.bottom, 18)

            Text(title)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundColor(AppTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 9)
                .padding(.bottom, 22)

            if offersSettings {
                Button {
                    dismiss()
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    Label("Mở Cài đặt", systemImage: "gearshape.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .background(
                    LinearGradient(colors: [AppTheme.red, AppTheme.deepRed], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Button("Đóng") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.muted)
                .padding(.top, offersSettings ? 16 : 0)
                .frame(maxWidth: .infinity, minHeight: offersSettings ? 28 : 48)
        }
        .padding(24)
        .adaptiveGlassSurface(cornerRadius: 28, tint: AppTheme.deepRed.opacity(0.22))
        .shadow(color: .black.opacity(0.42), radius: 30, y: 16)
        .frame(maxWidth: 390)
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
                    colors: [AppTheme.ink, AppTheme.deepRed.opacity(0.72), AppTheme.ink],
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
                                .stroke(Color.white.opacity(0.08))
                        )
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
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    Text("hoặc").font(.caption).foregroundColor(AppTheme.muted)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                }

                Button {
                    Task { _ = await session.signInWithBiometrics() }
                } label: {
                    Label("Đăng nhập bằng \(session.biometricName)", systemImage: session.biometricIcon)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .background(Color.white.opacity(0.075))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.1))
                )
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

                    NavigationLink(destination: AttendanceHistoryView()) {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Tháng", selection: $selectedMonth) {
                    ForEach(monthOptions) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
                .tint(AppTheme.red)

                if isLoading {
                    ProgressView("Đang tải bảng công...").tint(AppTheme.red)
                } else if let days = history?.days, !days.isEmpty {
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
                label: date.formatted(.dateTime.month(.wide).year())
            )
        }
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
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            history = try await APIClient.shared.request(
                "me/attendance?month=\(selectedMonth)",
                token: token
            )
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
                ScrollView {
                    VStack(spacing: 16) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                filterButton("Tất cả", nil)
                                ForEach(EmployeeRequestStatus.allCases, id: \.self) { filterButton($0.title, $0) }
                            }
                        }
                        if visible.isEmpty {
                            ContentUnavailableView("Chưa có đơn", systemImage: "doc.text", description: Text("Các đơn đã gửi sẽ xuất hiện tại đây."))
                                .padding(.top, 70)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(visible) { request in
                                    if store.approvals.contains(where: { $0.id == request.id && $0.status == .pending }) {
                                        Button { reviewing = request } label: { RequestCard(request: request, canCancel: false, cancel: {}) }.buttonStyle(.plain)
                                    } else {
                                        RequestCard(request: request) { Task { await store.cancel(token: session.token, id: request.id) } }
                                    }
                                }
                            }
                        }
                    }.padding(16).padding(.bottom, 82)
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
            .task { await store.load(session.token) }
            .refreshable { await store.load(session.token) }
            .alert("Đơn từ", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("Đóng") { store.message = nil } } message: { Text(store.message ?? "") }
        }
    }

    private func filterButton(_ title: String, _ value: EmployeeRequestStatus?) -> some View {
        Button(title) { filter = value }.font(.subheadline.bold()).padding(.horizontal, 14).padding(.vertical, 9)
            .background(filter == value ? AppTheme.red : AppTheme.card)
            .foregroundStyle(filter == value ? Color.white : Color.primary)
            .overlay(Capsule().stroke(filter == value ? Color.clear : Color.primary.opacity(0.12), lineWidth: 1))
            .clipShape(Capsule())
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
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
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

                    VStack(spacing: 0) {
                        ProfileLine(label: "Vai trò", value: session.profile?.role ?? "")
                        Divider().padding(.leading, 18)
                        ProfileLine(label: "Loại tài khoản", value: accountType)
                    }
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

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

                    Button("Đăng xuất", role: .destructive) { session.signOut() }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    if session.profile?.protected != true && session.profile?.accountType != "SUPER_ADMIN" {
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
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
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
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
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
