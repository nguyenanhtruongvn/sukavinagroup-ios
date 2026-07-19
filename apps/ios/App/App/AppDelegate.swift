import UIKit
import SwiftUI
import Security
import UserNotifications
import Network

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
    static let ink = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let card = Color(red: 0.12, green: 0.12, blue: 0.15)
    static let muted = Color(red: 0.66, green: 0.65, blue: 0.68)
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
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Máy chủ trả về dữ liệu không hợp lệ."
        case .server(let message): return message
        case .offline: return "Không thể kết nối máy chủ. Vui lòng kiểm tra Internet."
        case .cellularRestricted: return "Ứng dụng chưa được phép sử dụng dữ liệu di động. Hãy bật Dữ liệu di động cho Sukavina trong Cài đặt."
        case .unauthorized: return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại."
        }
    }
}

private enum NetworkSessions {
    static let api: URLSession = makeSession(resourceTimeout: 90)
    static let events: URLSession = makeSession(resourceTimeout: 24 * 60 * 60)

    private static func makeSession(resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
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

    static func report() -> String {
        lock.lock()
        defer { lock.unlock() }
        let entries = UserDefaults.standard.stringArray(forKey: key) ?? []
        let device = "iOS \(UIDevice.current.systemVersion) | \(UIDevice.current.model)"
        return (["SUKAVINA CONNECTION LOG", device, "Bundle: \(Bundle.main.infoDictionary?[\"CFBundleShortVersionString\"] as? String ?? \"?\") (\(Bundle.main.infoDictionary?[\"CFBundleVersion\"] as? String ?? \"?\"))", ""] + entries).joined(separator: "\n")
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
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
            request.httpBody = try JSONEncoder().encode(body)
        }

        var data: Data
        var response: URLResponse
        ConnectionDiagnostics.record("API primary start: \(method) \(url.host ?? \"unknown\")/\(path)")
        do {
            (data, response) = try await NetworkSessions.api.data(for: request)
        } catch let error as URLError where error.code == .dataNotAllowed || error.code == .internationalRoamingOff {
            ConnectionDiagnostics.record("API primary cellular denied: \(error.code.rawValue) \(error.localizedDescription)")
            throw NetworkError.cellularRestricted
        } catch {
            let code = (error as? URLError)?.code.rawValue
            ConnectionDiagnostics.record("API primary failed: code=\(code.map(String.init) ?? \"n/a\") \(error.localizedDescription)")
            guard let fallbackURL = URL(string: path, relativeTo: fallbackBaseURL) else {
                throw NetworkError.offline
            }
            request.url = fallbackURL
            ConnectionDiagnostics.record("API fallback start: \(method) \(fallbackURL.host ?? \"unknown\")/\(path)")
            do {
                (data, response) = try await NetworkSessions.api.data(for: request)
            } catch let fallbackError as URLError where fallbackError.code == .dataNotAllowed || fallbackError.code == .internationalRoamingOff {
                ConnectionDiagnostics.record("API fallback cellular denied: \(fallbackError.code.rawValue) \(fallbackError.localizedDescription)")
                throw NetworkError.cellularRestricted
            } catch {
                let code = (error as? URLError)?.code.rawValue
                ConnectionDiagnostics.record("API fallback failed: code=\(code.map(String.init) ?? \"n/a\") \(error.localizedDescription)")
                throw NetworkError.offline
            }
        }

        guard let http = response as? HTTPURLResponse else {
            ConnectionDiagnostics.record("API invalid non-HTTP response: \(path)")
            throw NetworkError.invalidResponse
        }
        ConnectionDiagnostics.record("API response: \(http.statusCode) host=\(http.url?.host ?? \"unknown\") path=\(path) bytes=\(data.count)")
        guard (200..<300).contains(http.statusCode) else {
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
    @Published var errorOffersSettings = false
    @Published var isWorking = false
    @Published var unreadCount = 0

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

    func refreshDashboard() async {
        guard let token else { return }
        do {
            let fresh: Dashboard = try await APIClient.shared.request("me/dashboard", token: token)
            processNewArticles(fresh.contentItems)
            dashboard = fresh
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
        state = .signedOut
    }

    func dismissError() {
        errorMessage = nil
        errorOffersSettings = false
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        if let networkError = error as? NetworkError,
           case .cellularRestricted = networkError {
            errorOffersSettings = true
        } else {
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
                    message: message,
                    offersSettings: session.errorOffersSettings,
                    dismiss: { session.dismissError() }
                )
                .padding(24)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .task { await session.restore() }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: session.errorMessage)
    }
}

private struct ElegantAppAlert: View {
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

            Text(offersSettings ? "Cần bật dữ liệu di động" : "Chưa thể thực hiện")
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
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(AppTheme.card)
                .shadow(color: .black.opacity(0.42), radius: 30, y: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
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
                Text("SUKAVINA USER")
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
    @State private var showDiagnostics = false

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

            Button {
                showDiagnostics = true
            } label: {
                Label("Nhật ký kết nối", systemImage: "waveform.path.ecg.rectangle")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(AppTheme.muted)
        }
        .sheet(isPresented: $showDiagnostics) { ConnectionDiagnosticsView() }
    }
}

private struct ConnectionDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report = ConnectionDiagnostics.report()
    @State private var showShareSheet = false
    @State private var copied = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(AppTheme.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Chẩn đoán kết nối").font(.headline)
                        Text("Không chứa mật khẩu hoặc token đăng nhập.")
                            .font(.caption)
                            .foregroundColor(AppTheme.muted)
                    }
                    Spacer()
                }

                ScrollView {
                    Text(report.isEmpty ? "Chưa có dữ liệu. Hãy thử đăng nhập rồi mở lại nhật ký." : report)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.82))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .background(Color.black.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = report
                        copied = true
                    } label: {
                        Label(copied ? "Đã sao chép" : "Sao chép", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Chia sẻ", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .background(AppTheme.red)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button("Xóa nhật ký cũ", role: .destructive) {
                    ConnectionDiagnostics.clear()
                    report = ConnectionDiagnostics.report()
                    copied = false
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(20)
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("Nhật ký kết nối")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ActivityShareView(items: [report])
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct ActivityShareView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
        .preferredColorScheme(.dark)
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
            NewsView()
                .tabItem { Label("Bài viết", systemImage: "newspaper.fill") }
                .badge(session.unreadCount)
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

                    HStack {
                        Text("Mới nhất").font(.title2.bold())
                        Spacer()
                        NavigationLink("Xem tất cả") { NewsView() }.foregroundColor(AppTheme.red)
                    }

                    ForEach(Array((session.dashboard?.contentItems ?? []).prefix(3))) { item in
                        NavigationLink(destination: ArticleDetailView(item: item)) {
                            ArticleRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
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
        .preferredColorScheme(.dark)
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
