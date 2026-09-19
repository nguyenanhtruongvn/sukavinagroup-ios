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
import os

/// Darwin notifications cross the app/WidgetKit process boundary.  The normal
/// NotificationCenter notification is intentionally kept as well for APNs and
/// in-app controls.
private let meetingLiveActivityStateChangedString =
    "net.sukavinagroup.meeting-live-activity-state-changed" as CFString
private let meetingLiveActivityStateChanged =
    CFNotificationName(rawValue: meetingLiveActivityStateChangedString)

private func receiveMeetingLiveActivityStateChanged(
    _ center: CFNotificationCenter?,
    observer: UnsafeMutableRawPointer?,
    name: CFNotificationName?,
    object: UnsafeRawPointer?,
    userInfo: CFDictionary?
) {
    guard let observer else { return }
    let session = Unmanaged<SessionStore>.fromOpaque(observer).takeUnretainedValue()
    Task { @MainActor [weak session] in
        guard let session else { return }
        await session.applyLiveActivityMeetingChangeImmediately()
    }
}

private extension DateFormatter { static let meetingDay: DateFormatter = { let value = DateFormatter(); value.calendar = Calendar(identifier: .gregorian); value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh"); value.dateFormat = "yyyy-MM-dd"; return value }() }
private let sessionRestoreLogger = Logger(
    subsystem: "net.sukavinagroup.user",
    category: "session-restore"
)

@MainActor
@available(iOS 17.0, *)
final class SessionStore: ObservableObject {
    private struct CachedValue<Value: Codable>: Codable {
        let savedAt: Date
        let value: Value
    }

    private struct CachedDashboard: Codable {
        let savedAt: Date
        let value: Dashboard
    }

    private struct CachedAttendanceMonth: Codable {
        let savedAt: Date
        let value: AttendanceMonth
    }

    // Meeting details contain participant information, so keep this cache in
    // memory only. It makes repeated opens instant without persisting extra
    // personal data to disk.
    private struct MeetingDetailsMemoryEntry {
        let savedAt: Date
        let value: MeetingBookingDetails
    }

    enum State {
        case restoring
        case signedOut
        case signedIn
    }

    // UIKit presents this stable launch screen while credentials are resolved.
    // The result, rather than a timer, decides which screen is shown next.
    @Published var state: State = .restoring
    @Published var profile: Profile?
    @Published var dashboard: Dashboard?
    @Published var errorMessage: String?
    @Published var errorTitle = "Chưa thể thực hiện"
    @Published var errorOffersSettings = false
    @Published var isWorking = false
    @Published var unreadCount = 0
    @Published var requestUnreadCount = 0
    @Published var notificationBadgeCount = 0
    @Published var biometricsEnabled = BiometricPreferences.enabled
    @Published var passwordChangeRequiresEmail = false
    @Published var passwordChangeError: String?
    @Published var forgotPasswordError: String?
    @Published var todayMenu: TodayMenu?
    @Published var meetingRooms: [MeetingRoom] = []
    @Published var meetingBookings: [MeetingBooking] = []
    @Published var meetingInvitees: [MeetingInvitee] = []
    @Published private(set) var attendanceRevision = 0
    @Published private(set) var requestRevision = 0
    @Published private(set) var localAttendanceNotifications: [RequestNotification] = []
    @Published private(set) var isOfflineNoticeVisible = false
    @Published private(set) var isNetworkAvailable = false

    /// `false` only after NWPathMonitor has confirmed an offline path. Before
    /// its first callback callers may still make their normal initial request.
    var hasConfirmedOfflineConnection: Bool {
        lastPathStatus != nil && !isNetworkAvailable
    }

    private(set) var token: String?
    private var knownArticleIDs: Set<String> = []
    private let knownArticlesKey = "known-native-article-ids"
    private let knownAttendancePrefix = "known-native-attendance-ids-"
    private let localAttendanceNotificationsPrefix = "local-native-attendance-notifications-"
    private let acknowledgedNotificationBadgePrefix = "acknowledged-native-notification-badge-"
    private let acknowledgedNotificationBadgeDatePrefix = "acknowledged-native-notification-badge-date-"
    private var latestRequestNotifications: [RequestNotification] = []
    private var articleBadgeCount = 0
    private let attendanceMonthCachePrefix = "native-attendance-month-"
    private let attendanceMonthCacheOwnerKey = "native-attendance-month-cache-owner"
    private let dashboardCachePrefix = "native-dashboard-cache-"
    private let todayMenuCachePrefix = "native-today-menu-cache-"
    private let requestNotificationsCachePrefix = "native-request-notifications-cache-"
    /// Re-signed/TestFlight builds can receive a rewritten App Group.  Resolve
    /// it exactly as the widget bridge does so the app and AppIntent extension
    /// read the same end-time payload.
    private var meetingLiveActivityAppGroup: String {
        let original = "group.net.sukavinagroup.user"
        let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]
        return groups?.first(where: { $0.contains(original) }) ?? original
    }
    private let endedMeetingLiveActivityKey = "meeting-live-activity-ended-booking"
    private var eventStreamTask: Task<Void, Never>?
    private var realtimeRefreshTask: Task<Void, Never>?
    private var pendingRealtimeEvents: Set<String> = []
    fileprivate var activeMeetingScheduleDate = Date()
    private var displayedMeetingScheduleDay: String?
    private var meetingScheduleRefreshTasks: [String: Task<Void, Never>] = [:]
    private var meetingInviteesLoadedAt: Date?
    private var meetingInviteesRefreshTask: Task<String?, Never>?
    private let meetingInviteesCacheTTL: TimeInterval = 10 * 60
    private var todayMenuRefreshTask: Task<Void, Never>?
    private var todayMenuLoadedAt: Date?
    private let todayMenuRefreshTTL: TimeInterval = 90
    private var meetingDetailsCache: [String: MeetingDetailsMemoryEntry] = [:]
    private var meetingDetailsRefreshTasks: [String: Task<MeetingBookingDetails?, Never>] = [:]
    private let meetingDetailsCacheTTL: TimeInterval = 60
    private var sessionRefreshTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "net.sukavinagroup.network-path")
    private var isMonitoringNetwork = false
    private var lastPathStatus: NWPath.Status?
    private var lastPathWasCellular: Bool?
    private var offlineNoticeTask: Task<Void, Never>?
    private var foregroundRefreshTask: Task<Void, Never>?
    private var apnsTokenObserver: NSObjectProtocol?
    private var meetingPushObserver: NSObjectProtocol?
    private var activeRestoreAttempt: UUID?
    // Kept only for the current app session. Persisting this acknowledgement
    // made a valid APNs token silently disappear from the server after a token
    // cleanup or an account switch on the same iPhone.
    private var registeredAPNsIdentity: String?

    init() {
        apnsTokenObserver = NotificationCenter.default.addObserver(
            forName: .sukavinaAPNsTokenUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncAPNsToken()
            }
        }
        meetingPushObserver = NotificationCenter.default.addObserver(
            forName: .sukavinaMeetingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.meetingDetailsRefreshTasks.values.forEach { $0.cancel() }
                self.meetingDetailsRefreshTasks.removeAll()
                self.meetingDetailsCache.removeAll()
                await self.refreshMeetingSchedule(date: self.activeMeetingScheduleDate, force: true)
            }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            receiveMeetingLiveActivityStateChanged,
            meetingLiveActivityStateChangedString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        offlineNoticeTask?.cancel()
        if let apnsTokenObserver {
            NotificationCenter.default.removeObserver(apnsTokenObserver)
        }
        if let meetingPushObserver {
            NotificationCenter.default.removeObserver(meetingPushObserver)
        }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            meetingLiveActivityStateChanged,
            nil
        )
    }

    func cachedAttendanceMonth(_ month: String) -> AttendanceMonth? {
        guard let cacheKey = attendanceMonthCacheKey(month),
              let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        if let cached = try? JSONDecoder().decode(CachedAttendanceMonth.self, from: data) {
            return cached.value
        }
        // One-release migration path for the former unversioned cache.
        return try? JSONDecoder().decode(AttendanceMonth.self, from: data)
    }

    func shouldRevalidateAttendanceMonth(_ month: String) -> Bool {
        guard let cacheKey = attendanceMonthCacheKey(month),
              let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(CachedAttendanceMonth.self, from: data) else { return true }
        let currentMonth = String(DateFormatter.meetingDay.string(from: Date()).prefix(7))
        let ttl: TimeInterval = month == currentMonth ? 90 : 12 * 60 * 60
        return Date().timeIntervalSince(cached.savedAt) >= ttl
    }

    func loadAttendanceMonth(_ month: String, token: String) async throws -> AttendanceMonth {
        do {
            let loaded: AttendanceMonth = try await APIClient.shared.request(
                "me/attendance?month=\(month)", token: token
            )
            saveAttendanceMonth(loaded, for: month)
            return loaded
        } catch {
            if let cached = cachedAttendanceMonth(month) { return cached }
            throw error
        }
    }

    private func attendanceMonthCacheKey(_ month: String) -> String? {
        let employeeCode = profile?.employeeCode.nilIfEmpty
            ?? dashboard?.employeeCode.nilIfEmpty
            ?? UserDefaults.standard.string(forKey: attendanceMonthCacheOwnerKey)?.nilIfEmpty
        guard let employeeCode else { return nil }
        return attendanceMonthCachePrefix + employeeCode + "-" + month
    }

    private func saveAttendanceMonth(_ month: AttendanceMonth, for keyMonth: String) {
        guard let cacheKey = attendanceMonthCacheKey(keyMonth),
              let employeeCode = profile?.employeeCode.nilIfEmpty ?? dashboard?.employeeCode.nilIfEmpty,
              let data = try? JSONEncoder().encode(CachedAttendanceMonth(savedAt: Date(), value: month)) else { return }
        UserDefaults.standard.set(employeeCode, forKey: attendanceMonthCacheOwnerKey)
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private func restoreCachedDashboard() {
        guard let employeeCode = profile?.employeeCode.nilIfEmpty,
              let data = UserDefaults.standard.data(forKey: dashboardCachePrefix + employeeCode),
              let cached = try? JSONDecoder().decode(CachedDashboard.self, from: data),
              Date().timeIntervalSince(cached.savedAt) < 24 * 60 * 60 else { return }
        dashboard = cached.value
    }

    private func saveDashboardCache(_ value: Dashboard) {
        let employeeCode = value.employeeCode.nilIfEmpty ?? profile?.employeeCode.nilIfEmpty
        guard let employeeCode,
              let data = try? JSONEncoder().encode(CachedDashboard(savedAt: Date(), value: value)) else { return }
        UserDefaults.standard.set(data, forKey: dashboardCachePrefix + employeeCode)
    }

    private var cacheEmployeeCode: String? {
        profile?.employeeCode.nilIfEmpty ?? dashboard?.employeeCode.nilIfEmpty
    }

    private func restoreCachedTodayMenu() {
        guard let employeeCode = cacheEmployeeCode,
              let data = UserDefaults.standard.data(forKey: todayMenuCachePrefix + employeeCode),
              let cached = try? JSONDecoder().decode(CachedValue<TodayMenu>.self, from: data),
              cached.value.date == DateFormatter.meetingDay.string(from: Date()),
              Date().timeIntervalSince(cached.savedAt) < 24 * 60 * 60 else { return }
        todayMenu = cached.value
        todayMenuLoadedAt = cached.savedAt
    }

    private func saveTodayMenuCache(_ value: TodayMenu) {
        guard let employeeCode = cacheEmployeeCode,
              let data = try? JSONEncoder().encode(CachedValue(savedAt: Date(), value: value)) else { return }
        UserDefaults.standard.set(data, forKey: todayMenuCachePrefix + employeeCode)
    }

    func cachedRequestNotifications() -> [RequestNotification] {
        guard let employeeCode = cacheEmployeeCode,
              let data = UserDefaults.standard.data(forKey: requestNotificationsCachePrefix + employeeCode),
              let cached = try? JSONDecoder().decode(CachedValue<[RequestNotification]>.self, from: data),
              Date().timeIntervalSince(cached.savedAt) < 7 * 24 * 60 * 60 else {
            return mergedRequestNotifications([])
        }
        return mergedRequestNotifications(cached.value)
    }

    private func saveRequestNotificationsCache(_ values: [RequestNotification]) {
        let inboxValues = values.filter { !isAttendanceNotificationType($0.type) }
        guard let employeeCode = cacheEmployeeCode,
              let data = try? JSONEncoder().encode(CachedValue(savedAt: Date(), value: inboxValues)) else { return }
        UserDefaults.standard.set(data, forKey: requestNotificationsCachePrefix + employeeCode)
    }

    /// Starts restoration directly from the UIKit lifecycle. This deliberately
    /// avoids a first Swift Concurrency task at launch on iOS 17, where that
    /// task can be scheduled but never resume after dispatching its work.
    func beginRestore() {
        guard state == .restoring, activeRestoreAttempt == nil else { return }
        sessionRestoreLogger.notice("Restore entered")
        startNetworkMonitoring()
        sessionRestoreLogger.notice("Network monitor started")
        guard UIApplication.shared.isProtectedDataAvailable else {
            sessionRestoreLogger.notice("Protected data unavailable")
            ConnectionDiagnostics.record("Protected data unavailable; showing sign-in")
            state = .signedOut
            return
        }
        let attemptID = UUID()
        activeRestoreAttempt = attemptID
        // Security.framework can wait while protected data wakes. Keep it off
        // the UI actor. The completion alone selects the next screen.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            sessionRestoreLogger.notice("Keychain read started")
            let accessToken = KeychainStore.loadToken()
            let refreshToken = KeychainStore.loadRefreshToken()
            sessionRestoreLogger.notice(
                "Keychain read completed: access=\(accessToken != nil, privacy: .public) refresh=\(refreshToken != nil, privacy: .public)"
            )
            DispatchQueue.main.async { [weak self] in
                self?.completeRestore(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    attemptID: attemptID
                )
            }
        }
    }

    func restore() async {
        beginRestore()
    }

    private func completeRestore(accessToken savedToken: String?, refreshToken savedRefreshToken: String?, attemptID: UUID) {
        guard activeRestoreAttempt == attemptID else { return }
        activeRestoreAttempt = nil
        guard savedToken != nil || savedRefreshToken != nil else {
            sessionRestoreLogger.notice("Restore completed: no saved session")
            state = .signedOut
            return
        }
        token = savedToken
        profile = SessionCache.loadProfile()
        restoreCachedDashboard()
        restoreCachedTodayMenu()
        state = .signedIn
        sessionRestoreLogger.notice("Restore completed: signed in from cached session")
        loadKnownArticles()
        Task { @MainActor [weak self] in
            await self?.hydrateRestoredSession(savedToken: savedToken)
        }
    }

    private func hydrateRestoredSession(savedToken: String?) async {
        do {
            if let savedToken {
                do {
                    profile = try await APIClient.shared.request("auth/me", token: savedToken)
                    if let profile { SessionCache.save(profile: profile) }
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
            if profile?.accountType == "CANTEEN" && profile?.employeeCode != "DEMO" {
                await refreshProfile()
                startSessionRefresh()
                return
            }
            await NotificationManager.shared.requestAuthorizationIfNeeded()
            await refreshDashboard()
            await refreshProfile()
            startRealTimeUpdates()
            startSessionRefresh()
        } catch NetworkError.unauthorized {
            signOut()
        } catch {
            // Keep the locally restored session while offline and retry after reconnection.
            present(error)
            startRealTimeUpdates()
            startSessionRefresh()
        }
    }

    /// Lets the native UIKit host recover from a restore task that never
    /// resumes on an older OS. Credentials stay in Keychain so a subsequent
    /// normal restore or sign-in can still use them.
    func abandonRestore() {
        guard state == .restoring else { return }
        activeRestoreAttempt = nil
        state = .signedOut
    }

    func appBecameActive() {
        guard state == .signedIn else { return }
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.refreshSession()
            } catch NetworkError.unauthorized {
                self.signOut()
                return
            } catch {
                ConnectionDiagnostics.record("Foreground session refresh deferred: \(error.localizedDescription)")
            }
            guard !Task.isCancelled else { return }
            // Fetch the tab/icon count immediately. Previously it waited for
            // the profile and dashboard refreshes to finish first.
            async let notificationCountRefresh: Void = self.refreshRequestNotificationCount()
            await self.refreshProfile()
            if self.profile?.accountType == "CANTEEN" {
                self.startSessionRefresh()
                return
            }
            await self.refreshDashboard(shouldRefreshRequestNotificationCount: false)
            await self.refreshTodayMenu()
            _ = await notificationCountRefresh
            self.startRealTimeUpdates()
            self.startSessionRefresh()
        }
    }

    func signIn(loginId: String, password: String) async -> Bool {
        activeRestoreAttempt = nil
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
            // The session is authenticated at this point.  Present the portal
            // immediately and hydrate its data in the background rather than
            // holding the login button until every dashboard request finishes.
            Task { @MainActor [weak self] in
                await self?.hydrateSignedInSession(
                    isCanteen: response.user.accountType == "CANTEEN" && response.user.employeeCode != "DEMO"
                )
            }
            return true
        } catch {
            ConnectionDiagnostics.record("Sign-in failed: \(error.localizedDescription)")
            present(error)
            return false
        }
    }

    func refreshTodayMenu(force: Bool = false) async {
        guard let token else { return }

        if !force,
           todayMenu != nil,
           let todayMenuLoadedAt,
           Date().timeIntervalSince(todayMenuLoadedAt) < todayMenuRefreshTTL {
            return
        }

        if let existing = todayMenuRefreshTask {
            await existing.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value: TodayMenu = try await APIClient.shared.request("me/menu", token: token)
                self.todayMenu = value
                self.todayMenuLoadedAt = Date()
                self.saveTodayMenuCache(value)
            } catch is CancellationError {
                return
            } catch {
                // Keep a restored menu visible if revalidation is temporarily
                // unavailable instead of replacing useful cached UI with an alert.
                if self.todayMenu == nil {
                    self.present(error)
                } else {
                    ConnectionDiagnostics.record(
                        "Today menu refresh deferred: \(error.localizedDescription)"
                    )
                }
            }
        }

        todayMenuRefreshTask = task
        await task.value
        todayMenuRefreshTask = nil
    }

    func scanMealQRCode(_ qrToken: String) async -> MealScanResponse? {
        guard let token else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            return try await APIClient.shared.request(
                "me/menu/scan",
                method: "POST",
                token: token,
                body: MealQrScanBody(token: qrToken)
            )
        } catch {
            present(error)
            return nil
        }
    }

    func issueMealQRCode() async -> MealQrIssueResponse? {
        guard let token else { return nil }
        do {
            return try await APIClient.shared.request(
                "me/menu/selection/qr",
                method: "POST",
                token: token
            )
        } catch {
            present(error)
            return nil
        }
    }

    func selectMeal(_ choice: String) async {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let value: TodayMenu = try await APIClient.shared.request(
                "me/menu/selection",
                method: "PATCH",
                token: token,
                body: MealSelectionBody(choice: choice)
            )
            todayMenu = value
            todayMenuLoadedAt = Date()
            saveTodayMenuCache(value)
        } catch {
            present(error)
        }
    }

    func cancelMealSelection() async {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let value: TodayMenu = try await APIClient.shared.request(
                "me/menu/selection",
                method: "DELETE",
                token: token
            )
            todayMenu = value
            todayMenuLoadedAt = Date()
            saveTodayMenuCache(value)
        } catch {
            present(error)
        }
    }

    func receiveMealSelection() async {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let value: TodayMenu = try await APIClient.shared.request(
                "me/menu/selection/received",
                method: "PATCH",
                token: token
            )
            todayMenu = value
            todayMenuLoadedAt = Date()
            saveTodayMenuCache(value)
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
        guard let savedRefreshToken = BiometricKeychain.load(prompt: "Đăng nhập Sukavina") else {
            errorTitle = "Không thể xác thực"
            errorMessage = "Không thể xác thực sinh trắc học. Vui lòng thử lại hoặc đăng nhập bằng mật khẩu."
            return false
        }
        do {
            let response: LoginResponse = try await APIClient.shared.request(
                "auth/refresh",
                method: "POST",
                body: RefreshSessionBody(refreshToken: savedRefreshToken)
            )
            guard BiometricPreferences.employeeCode == response.user.employeeCode else {
                disableBiometricLogin()
                errorTitle = "Cần thiết lập lại sinh trắc học"
                errorMessage = "Sinh trắc học chưa được liên kết với tài khoản này. Hãy đăng nhập bằng mật khẩu và bật lại trong tab Tài khoản."
                return false
            }
            applySession(response)
            state = .signedIn
            startNetworkMonitoring()
            if response.user.accountType == "CANTEEN" && response.user.employeeCode != "DEMO" {
                startSessionRefresh()
                return true
            }
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

    func setBiometricLogin(enabled: Bool) async {
        if enabled {
            let context = LAContext()
            context.localizedCancelTitle = "Hủy"
            var evaluationError: NSError?
            guard let employeeCode = profile?.employeeCode,
                  context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError),
                  let refreshToken = KeychainStore.loadRefreshToken() else {
                biometricsEnabled = false
                errorTitle = "Không thể bật sinh trắc học"
                errorMessage = "Thiết bị chưa thiết lập Face ID/Touch ID hoặc chưa bật mật mã màn hình."
                return
            }
            do {
                let confirmed = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Xác nhận bật \(biometricName) để đăng nhập Sukavina"
                )
                guard confirmed, BiometricKeychain.save(refreshToken: refreshToken) else {
                    biometricsEnabled = false
                    errorTitle = "Không thể bật sinh trắc học"
                    errorMessage = "Không thể lưu thông tin đăng nhập sinh trắc học. Vui lòng thử lại."
                    return
                }
            } catch {
                biometricsEnabled = false
                errorTitle = "Chưa bật sinh trắc học"
                if let authenticationError = error as? LAError,
                   authenticationError.code == .userCancel || authenticationError.code == .appCancel {
                    errorMessage = "Bạn đã hủy xác nhận. Sinh trắc học vẫn đang tắt."
                } else {
                    errorMessage = "Không thể xác nhận \(biometricName). Vui lòng quét lại và thử lần nữa."
                }
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

    func refreshDashboard(shouldRefreshRequestNotificationCount: Bool = true) async {
        guard let token, profile?.accountType != "CANTEEN" else { return }
        do {
            let fresh: Dashboard = try await APIClient.shared.request("me/dashboard", token: token)
            processNewAttendance(fresh)
            processNewArticles(fresh.contentItems)
            dashboard = fresh
            saveDashboardCache(fresh)
            attendanceRevision &+= 1
            AttendanceWidgetBridge.update(from: fresh)
            if shouldRefreshRequestNotificationCount {
                await refreshRequestNotificationCount()
            }
        } catch is CancellationError {
            // URLSession cancellation is a normal task-lifecycle event, not
            // evidence that the device has lost Internet access.
            return
        } catch {
            present(error)
        }
    }

    private func processNewAttendance(_ fresh: Dashboard) {
        let employeeCode = fresh.employeeCode.isEmpty ? (profile?.employeeCode ?? "") : fresh.employeeCode
        let key = knownAttendancePrefix + employeeCode
        let defaults = UserDefaults.standard
        let records = fresh.attendanceRecords ?? []

        // Attendance alerts are delivered by APNs and must stay outside the
        // in-app Notifications inbox. Remove the legacy local inbox bridge so
        // upgraded installs do not keep showing old attendance rows.
        localAttendanceNotifications = []
        if !employeeCode.isEmpty {
            defaults.removeObject(forKey: localAttendanceNotificationsPrefix + employeeCode)
        }
        defaults.set(records.map(\.id), forKey: key)
    }

    func isAttendanceNotificationType(_ type: String) -> Bool {
        type == "attendance_check_in" || type == "attendance_check_out"
    }

    func mergedRequestNotifications(_ server: [RequestNotification]) -> [RequestNotification] {
        clearLocalAttendanceNotifications()
        return server
            .filter { !isAttendanceNotificationType($0.type) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func isLocalAttendanceNotification(_ item: RequestNotification) -> Bool { item.id.hasPrefix("local-attendance-") }
    func markLocalAttendanceNotificationRead(_ id: String) {
        localAttendanceNotifications = localAttendanceNotifications.map { $0.id == id ? RequestNotification(id: $0.id, type: $0.type, title: $0.title, message: $0.message, requestId: $0.requestId, read: true, createdAt: $0.createdAt) : $0 }
        persistLocalAttendanceNotifications(profile?.employeeCode ?? dashboard?.employeeCode ?? "")
    }
    func deleteLocalAttendanceNotification(_ id: String) {
        localAttendanceNotifications.removeAll { $0.id == id }
        persistLocalAttendanceNotifications(profile?.employeeCode ?? dashboard?.employeeCode ?? "")
    }
    func clearLocalAttendanceNotifications() {
        localAttendanceNotifications = []
        persistLocalAttendanceNotifications(profile?.employeeCode ?? dashboard?.employeeCode ?? "")
    }
    private func loadLocalAttendanceNotifications(_ employeeCode: String) {
        guard !employeeCode.isEmpty,
              let data = UserDefaults.standard.data(forKey: localAttendanceNotificationsPrefix + employeeCode),
              let items = try? JSONDecoder().decode([RequestNotification].self, from: data) else { return }
        localAttendanceNotifications = items
    }
    private func persistLocalAttendanceNotifications(_ employeeCode: String) {
        guard !employeeCode.isEmpty, let data = try? JSONEncoder().encode(Array(localAttendanceNotifications.prefix(50))) else { return }
        UserDefaults.standard.set(data, forKey: localAttendanceNotificationsPrefix + employeeCode)
    }

    private func attendanceNotificationTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else {
            let parts = value.split(separator: "T")
            return parts.count > 1 ? String(parts[1].prefix(5)) : "vừa xong"
        }
        let output = DateFormatter()
        output.locale = Locale(identifier: "vi_VN")
        output.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        output.dateFormat = "HH:mm"
        return output.string(from: date)
    }

    func signOut() {
        sessionRestoreLogger.notice("Sign-out requested")
        activeRestoreAttempt = nil
        let logoutToken = token
        let deviceToken = APNsRegistration.deviceToken
        if let logoutToken, let deviceToken {
            Task {
                let _: MessageResponse? = try? await APIClient.shared.request(
                    "auth/push-token",
                    method: "DELETE",
                    token: logoutToken,
                    body: PushTokenRegistrationBody(token: deviceToken, platform: "ios")
                )
            }
        }
        eventStreamTask?.cancel()
        eventStreamTask = nil
        realtimeRefreshTask?.cancel()
        realtimeRefreshTask = nil
        pendingRealtimeEvents.removeAll()
        meetingScheduleRefreshTasks.values.forEach { $0.cancel() }
        meetingScheduleRefreshTasks.removeAll()
        displayedMeetingScheduleDay = nil
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        offlineNoticeTask?.cancel()
        offlineNoticeTask = nil
        isOfflineNoticeVisible = false
        registeredAPNsIdentity = nil

        // Remove account-scoped notification data from disk on sign-out.
        // Meeting details are RAM-only and are cancelled/cleared here as well.
        if let employeeCode = cacheEmployeeCode {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: requestNotificationsCachePrefix + employeeCode)
            defaults.removeObject(forKey: localAttendanceNotificationsPrefix + employeeCode)
            defaults.removeObject(forKey: acknowledgedNotificationBadgePrefix + employeeCode)
            defaults.removeObject(forKey: acknowledgedNotificationBadgeDatePrefix + employeeCode)
        }
        meetingDetailsRefreshTasks.values.forEach { $0.cancel() }
        meetingDetailsRefreshTasks.removeAll()
        meetingDetailsCache.removeAll()
        meetingInviteesRefreshTask?.cancel()
        meetingInviteesRefreshTask = nil
        meetingInviteesLoadedAt = nil
        meetingInvitees = []
        todayMenuRefreshTask?.cancel()
        todayMenuRefreshTask = nil
        todayMenuLoadedAt = nil
        latestRequestNotifications = []
        localAttendanceNotifications = []
        if let employeeCode = cacheEmployeeCode {
            UserDefaults.standard.removeObject(
                forKey: "native-employee-requests-cache-" + employeeCode
            )
        }

        SessionCache.clear()
        token = nil
        profile = nil
        dashboard = nil
        meetingRooms = []
        meetingBookings = []
        meetingInvitees = []
        AttendanceWidgetBridge.clear()
        unreadCount = 0
        requestUnreadCount = 0
        notificationBadgeCount = 0
        articleBadgeCount = 0
        syncApplicationBadge()
        // Move to the login UI before touching Security.framework.  On some
        // devices SecItemDelete can wait for the protected-data service.
        state = .signedOut
        sessionRestoreLogger.notice("Sign-out completed: showing authentication")
        Task.detached(priority: .utility) {
            KeychainStore.clear(accessToken: logoutToken)
        }
    }

    private func hydrateSignedInSession(isCanteen: Bool) async {
        if isCanteen {
            await refreshProfile()
            startSessionRefresh()
            ConnectionDiagnostics.record("Canteen sign-in completed successfully")
            return
        }
        await NotificationManager.shared.requestAuthorizationIfNeeded()
        await refreshDashboard()
        await refreshProfile()
        startRealTimeUpdates()
        startSessionRefresh()
        ConnectionDiagnostics.record("Sign-in completed successfully")
    }

    private func applySession(_ response: LoginResponse) {
        token = response.accessToken
        KeychainStore.save(token: response.accessToken)
        if #available(iOS 17.2, *) {
            // Fresh sign-in is the first point at which the start token can
            // be authenticated and retained by the server.
            MeetingLiveActivityStartRegistration.observe()
        }
        if !response.refreshToken.isEmpty {
            KeychainStore.save(refreshToken: response.refreshToken)
        }
        if !response.widgetToken.isEmpty {
            AttendanceWidgetBridge.configure(token: response.widgetToken)
        }
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
        if let profile { SessionCache.save(profile: profile) }
        Task { @MainActor [weak self] in
            await APNsRegistration.requestAuthorizationAndRegister()
            await self?.syncAPNsToken()
            await self?.syncPushBadgeReset()
        }
    }

    private func syncAPNsToken() async {
        guard let token,
              let deviceToken = APNsRegistration.deviceToken,
              let employeeCode = profile?.employeeCode.nilIfEmpty else { return }

        let registrationIdentity = "\(employeeCode):\(deviceToken)"
        guard registeredAPNsIdentity != registrationIdentity else { return }

        do {
            let _: MessageResponse = try await APIClient.shared.request(
                "auth/push-token",
                method: "POST",
                token: token,
                body: PushTokenRegistrationBody(token: deviceToken, platform: "ios")
            )
            registeredAPNsIdentity = registrationIdentity
        } catch {
            ConnectionDiagnostics.record("APNs token upload failed: \(error.localizedDescription)")
        }
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
        if biometricsEnabled, !response.refreshToken.isEmpty {
            _ = BiometricKeychain.save(refreshToken: response.refreshToken)
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
        updateRequestUnreadCount(values)
    }

    func updateRequestUnreadCount(_ values: [RequestNotification]) {
        let inboxValues = mergedRequestNotifications(values)
        latestRequestNotifications = inboxValues
        saveRequestNotificationsCache(inboxValues)
        requestUnreadCount = inboxValues.filter { !$0.read }.count
        let employeeCode = profile?.employeeCode ?? dashboard?.employeeCode ?? ""
        let acknowledged = UserDefaults.standard.stringArray(forKey: acknowledgedNotificationBadgePrefix + employeeCode)
        let acknowledgedAt = UserDefaults.standard.object(forKey: acknowledgedNotificationBadgeDatePrefix + employeeCode) as? Date
        let requestBadgeCount = inboxValues.filter { notification in
            guard !notification.read else { return false }
            if acknowledged?.contains(notification.id) == true { return false }
            return acknowledgedAt == nil || notification.createdAt > acknowledgedAt!
        }.count
        notificationBadgeCount = max(0, articleBadgeCount + requestBadgeCount)
        syncApplicationBadge()
    }

    /// Opening Notifications clears only its visual badge. The underlying
    /// notifications remain unread until the user opens or removes them.
    func clearNotificationBadge() {
        let employeeCode = profile?.employeeCode ?? dashboard?.employeeCode ?? ""
        guard !employeeCode.isEmpty else { return }
        let acknowledgedAt = Date()
        let currentUnreadIDs = latestRequestNotifications.filter { !$0.read }.map(\.id)
        UserDefaults.standard.set(currentUnreadIDs, forKey: acknowledgedNotificationBadgePrefix + employeeCode)
        UserDefaults.standard.set(acknowledgedAt, forKey: acknowledgedNotificationBadgeDatePrefix + employeeCode)
        articleBadgeCount = 0
        notificationBadgeCount = 0
        NotificationManager.shared.clearBadge()
        Task { await syncPushBadgeReset(acknowledgedAt: acknowledgedAt) }
    }

    /// APNs applies the badge while the app is suspended, so the reset marker
    /// must be stored per iPhone on the server as well as locally. Unread
    /// notifications remain unread; only future notifications count again.
    private func syncPushBadgeReset(acknowledgedAt: Date? = nil) async {
        guard let token,
              let deviceToken = APNsRegistration.deviceToken,
              let employeeCode = profile?.employeeCode ?? dashboard?.employeeCode,
              !employeeCode.isEmpty else { return }
        let resetAt = acknowledgedAt ?? (UserDefaults.standard.object(
            forKey: acknowledgedNotificationBadgeDatePrefix + employeeCode
        ) as? Date)
        guard let resetAt else { return }
        do {
            let _: MessageResponse = try await APIClient.shared.request(
                "auth/push-token/badge-reset",
                method: "POST",
                token: token,
                body: PushBadgeResetBody(token: deviceToken, acknowledgedAt: resetAt)
            )
        } catch {
            ConnectionDiagnostics.record("APNs badge reset sync deferred: \(error.localizedDescription)")
        }
    }

    private func syncApplicationBadge() {
        UIApplication.shared.applicationIconBadgeNumber = max(0, notificationBadgeCount)
    }

    func dismissError() {
        errorMessage = nil
        errorTitle = "Chưa thể thực hiện"
        errorOffersSettings = false
    }

    private func present(_ error: Error) {
        guard !(error is CancellationError) else { return }
        errorMessage = error.localizedDescription
        if let networkError = error as? NetworkError,
           case .cellularRestricted = networkError {
            errorTitle = "Cần bật dữ liệu di động"
            errorOffersSettings = true
        } else if let networkError = error as? NetworkError,
                  case .invalidCredentials = networkError {
            errorTitle = "Sai thông tin đăng nhập"
            errorOffersSettings = false
        } else if let networkError = error as? NetworkError,
                  case .offline = networkError {
            errorTitle = "Kiểm tra kết nối Internet"
            errorOffersSettings = false
        } else {
            errorTitle = "Chưa thể thực hiện"
            errorOffersSettings = false
        }
    }

    private func startRealTimeUpdates() {
        eventStreamTask?.cancel()
        guard profile?.accountType != "CANTEEN" else {
            eventStreamTask = nil
            return
        }
        eventStreamTask = Task { [weak self] in
            guard let self else { return }
            guard let eventsURL = URL(string: "https://sukavinagroup.net/api/public/news/events") else { return }
            while !Task.isCancelled {
                do {
                    var request = URLRequest(url: eventsURL)
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
                            scheduleRealtimeRefresh(for: line)
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    let reconnectDelay = UInt64.random(in: 2_000_000_000...5_000_000_000)
                    try? await Task.sleep(nanoseconds: reconnectDelay)
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
                self.isNetworkAvailable = path.status == .satisfied
                self.showOfflineNoticeIfNeeded(previousStatus: wasStatus, currentStatus: path.status)

                // The first callback only records the current path. Refresh after a real reconnect or handoff.
                guard wasStatus != nil,
                      path.status == .satisfied,
                      wasStatus != .satisfied || wasCellular != isCellular,
                      self.token != nil else { return }
                await self.refreshProfile()
                await self.syncPushBadgeReset()
                if self.profile?.accountType == "CANTEEN" { return }
                await self.refreshDashboard()
                await self.refreshMeetingSchedule(date: self.activeMeetingScheduleDate, force: true)
                self.startRealTimeUpdates()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func showOfflineNoticeIfNeeded(previousStatus: NWPath.Status?, currentStatus: NWPath.Status) {
        // Also show it on the initial path when the app starts offline, but do not repeat it
        // for intermediate unsatisfied/requires-connection transitions.
        guard currentStatus != .satisfied,
              previousStatus == nil || previousStatus == .satisfied else { return }

        offlineNoticeTask?.cancel()
        isOfflineNoticeVisible = true
        offlineNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.isOfflineNoticeVisible = false
        }
    }

    private func refreshProfile() async {
        guard let token else { return }
        do {
            profile = try await APIClient.shared.request("auth/me", token: token)
            if let profile { SessionCache.save(profile: profile) }
        } catch {
            present(error)
        }
    }

    func markArticlesRead() {
        guard let items = dashboard?.contentItems else { return }
        knownArticleIDs.formUnion(items.map(\.id))
        persistKnownArticles()
        unreadCount = 0
        notificationBadgeCount = max(0, notificationBadgeCount - articleBadgeCount)
        articleBadgeCount = 0
        syncApplicationBadge()
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
            articleBadgeCount += newItems.count
            notificationBadgeCount += newItems.count
            syncApplicationBadge()
            NotificationManager.shared.notifyNewArticles(newItems, badge: notificationBadgeCount)
            knownArticleIDs.formUnion(newItems.map(\.id))
            persistKnownArticles()
        }
    }

    private func persistKnownArticles() {
        UserDefaults.standard.set(Array(knownArticleIDs.prefix(300)), forKey: knownArticlesKey)
    }

    func deleteAccount() async -> Bool {
        guard let token else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let _: MessageResponse = try await APIClient.shared.request(
                "auth/me",
                method: "DELETE",
                token: token,
                body: DeleteAccountBody(confirmation: "XOA TAI KHOAN")
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
        passwordChangeError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            return try await APIClient.shared.request(
                "auth/password-change/request", method: "POST", token: token
            )
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("email") {
                passwordChangeRequiresEmail = true
                passwordChangeError = "Tài khoản chưa có email liên kết. Vui lòng liên hệ Nhân sự để cập nhật email."
            } else {
                passwordChangeError = error.localizedDescription
            }
            return nil
        }
    }

    /// Shows the last confirmed schedule immediately and only revalidates when it is stale.
    /// Realtime/APNs events and explicit user refreshes bypass the freshness window.
    func refreshMeetingSchedule(date: Date = .now, force: Bool = false) async {
        activeMeetingScheduleDate = date
        let day = DateFormatter.meetingDay.string(from: date)
        displayCachedMeetingScheduleIfNeeded(for: day)

        guard let token else { return }
        // Before the first path callback, allow the request to proceed. Once the
        // monitor confirms an offline path, use the cached schedule only.
        guard isNetworkAvailable || lastPathStatus == nil else { return }
        guard force || shouldRevalidateMeetingSchedule(day: day) else { return }

        // Tab activation, foreground changes and SwiftUI lifecycle callbacks can
        // arrive together. Coalesce them into one request per day.
        if let existing = meetingScheduleRefreshTasks[day] {
            await existing.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchMeetingSchedule(day: day, token: token)
        }
        meetingScheduleRefreshTasks[day] = task
        await task.value
        meetingScheduleRefreshTasks[day] = nil
    }

    private func shouldRevalidateMeetingSchedule(day: String) -> Bool {
        guard let employeeCode = meetingCacheEmployeeCode,
              let savedAt = SessionCache.meetingScheduleSavedAt(day: day, employeeCode: employeeCode)
        else { return true }

        let today = DateFormatter.meetingDay.string(from: Date())
        let ttl: TimeInterval = day == today ? 60 : 5 * 60
        return Date().timeIntervalSince(savedAt) >= ttl
    }

    private func displayCachedMeetingScheduleIfNeeded(for day: String) {
        guard displayedMeetingScheduleDay != day else { return }
        restoreCachedMeetingSchedule(for: day)
        displayedMeetingScheduleDay = day
    }

    private func fetchMeetingSchedule(day: String, token: String) async {
        do {
            let value: MeetingScheduleResponse = try await APIClient.shared.request(
                "me/meeting-rooms?date=\(day)",
                token: token
            )
            guard !Task.isCancelled else { return }

            let pendingEndedMeeting = pendingEndedMeetingLiveActivityResult()
            var cachedBookings = normalizedMeetingBookings(value.bookings)

            // A slower response for a previously selected date must never replace
            // the date the user is currently looking at.
            if displayedMeetingScheduleDay == day {
                meetingRooms = applyMeetingRoomOrder(value.rooms)
                meetingBookings = cachedBookings
                applyEndedMeetingLiveActivityResultIfAvailable()
                meetingBookings = normalizedMeetingBookings(meetingBookings)
                cachedBookings = meetingBookings
            }

            if let pendingEndedMeeting,
               serverHasConfirmed(pendingEndedMeeting, in: value.bookings) {
                clearPendingEndedMeetingLiveActivityResult()
            }
            saveMeetingSchedule(
                MeetingScheduleResponse(rooms: value.rooms, bookings: cachedBookings),
                for: day
            )
        } catch {
            guard !Task.isCancelled else { return }
            ConnectionDiagnostics.record("Meeting schedule refresh deferred: \(error.localizedDescription)")
        }
    }

    private var meetingCacheEmployeeCode: String? {
        profile?.employeeCode.nilIfEmpty ?? dashboard?.employeeCode.nilIfEmpty
    }

    private func restoreCachedMeetingSchedule(for day: String) {
        guard let employeeCode = meetingCacheEmployeeCode else { return }
        let rooms = SessionCache.loadMeetingRooms(employeeCode: employeeCode)
        let roomIDs = Set(rooms.map(\.id))
        let bookings = SessionCache.loadMeetingSchedule(day: day, employeeCode: employeeCode)?.bookings ?? []
        meetingRooms = applyMeetingRoomOrder(rooms)
        // A room removed by admin disappears as soon as the next online catalog
        // refresh is cached, even if an older day's booking cache still exists.
        meetingBookings = normalizedMeetingBookings(bookings.filter { roomIDs.contains($0.roomId) })
        applyEndedMeetingLiveActivityResultIfAvailable()
    }

    private func saveMeetingSchedule(_ schedule: MeetingScheduleResponse, for day: String) {
        guard let employeeCode = meetingCacheEmployeeCode else { return }
        SessionCache.saveMeetingRooms(schedule.rooms, employeeCode: employeeCode)
        SessionCache.saveMeetingSchedule(schedule, day: day, employeeCode: employeeCode)
    }

    /// Invitees are supporting data for the booking form. Keep them in RAM for
    /// a short window and coalesce concurrent opens of the booking sheet.
    func refreshMeetingInvitees(force: Bool = false) async -> String? {
        guard let token else { return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại." }

        if !force,
           let meetingInviteesLoadedAt,
           Date().timeIntervalSince(meetingInviteesLoadedAt) < meetingInviteesCacheTTL {
            return nil
        }

        if let existing = meetingInviteesRefreshTask {
            return await existing.value
        }

        let staleInvitees = meetingInvitees
        let task = Task { @MainActor [weak self] () -> String? in
            guard let self else { return nil }
            do {
                self.meetingInvitees = try await APIClient.shared.request(
                    "me/meeting-rooms/invitees",
                    token: token
                )
                self.meetingInviteesLoadedAt = Date()
                return nil
            } catch is CancellationError {
                return nil
            } catch {
                // Existing RAM data is still useful when a revalidation fails.
                if !staleInvitees.isEmpty {
                    ConnectionDiagnostics.record(
                        "Meeting invitees refresh deferred: \(error.localizedDescription)"
                    )
                    return nil
                }
                return error.localizedDescription
            }
        }

        meetingInviteesRefreshTask = task
        let result = await task.value
        meetingInviteesRefreshTask = nil
        return result
    }

    func cachedMeetingBookingDetails(id: String) -> MeetingBookingDetails? {
        meetingDetailsCache[id]?.value
    }

    /// Returns fresh details from a short-lived RAM cache when possible.
    /// Stale cached data remains available to the caller for immediate display
    /// while this method revalidates it. Concurrent opens of the same meeting
    /// share one network request.
    func meetingBookingDetails(id: String, forceRefresh: Bool = false) async -> MeetingBookingDetails? {
        guard !id.isEmpty else { return nil }

        let cached = meetingDetailsCache[id]
        if !forceRefresh,
           let cached,
           Date().timeIntervalSince(cached.savedAt) < meetingDetailsCacheTTL {
            return cached.value
        }

        if let existing = meetingDetailsRefreshTasks[id] {
            return await existing.value
        }

        guard let token else { return cached?.value }
        guard !hasConfirmedOfflineConnection else { return cached?.value }

        let staleValue = cached?.value
        let task = Task { @MainActor [weak self] () -> MeetingBookingDetails? in
            guard let self else { return staleValue }
            do {
                let fresh: MeetingBookingDetails = try await APIClient.shared.request(
                    "me/meeting-bookings/\(id)",
                    token: token
                )
                self.meetingDetailsCache[id] = MeetingDetailsMemoryEntry(
                    savedAt: Date(),
                    value: fresh
                )
                return fresh
            } catch is CancellationError {
                return staleValue
            } catch {
                ConnectionDiagnostics.record(
                    "Meeting details refresh deferred: \(error.localizedDescription)"
                )
                return staleValue
            }
        }

        meetingDetailsRefreshTasks[id] = task
        let result = await task.value
        meetingDetailsRefreshTasks[id] = nil
        return result
    }

    private func updateCachedMeetingDetails(from booking: MeetingBooking) {
        guard let entry = meetingDetailsCache[booking.id] else { return }
        let current = entry.value
        let updated = MeetingBookingDetails(
            id: booking.id,
            roomId: booking.roomId,
            startsAt: booking.startsAt,
            endsAt: booking.endsAt,
            title: booking.title,
            attendeeCount: booking.attendeeCount,
            status: booking.status,
            room: current.room,
            employee: current.employee,
            participants: current.participants
        )
        meetingDetailsCache[booking.id] = MeetingDetailsMemoryEntry(
            savedAt: Date(),
            value: updated
        )
    }

    /// Cancelling is restricted by the server to the organiser and to meetings
    /// that have not started yet. Keep the visible day in sync immediately;
    /// the server also broadcasts the change to every other signed-in client.
    func cancelMeeting(id: String, scheduledAt: String) async -> String? {
        guard let token else { return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại." }
        guard isNetworkAvailable else { return "Mất kết nối internet. Không thể hủy lịch khi đang ngoại tuyến." }
        isWorking = true
        defer { isWorking = false }
        do {
            let _: MeetingBooking = try await APIClient.shared.request(
                "me/meeting-bookings/\(id)",
                method: "DELETE",
                token: token
            )
            meetingDetailsCache.removeValue(forKey: id)
            meetingBookings.removeAll { $0.id == id }
            await refreshMeetingSchedule(
                date: MeetingPresentation.date(from: scheduledAt) ?? activeMeetingScheduleDate,
                force: true
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The Live Activity intent is hosted outside the app process.  First
    /// redraw the currently visible schedule from its server-confirmed shared
    /// value, then revalidate in the background.  This avoids a visible delay
    /// while the schedule endpoint or real-time stream catches up.
    fileprivate func applyLiveActivityMeetingChangeImmediately() async {
        applyEndedMeetingLiveActivityResultIfAvailable()
        let day = DateFormatter.meetingDay.string(from: activeMeetingScheduleDate)
        saveMeetingSchedule(
            MeetingScheduleResponse(rooms: meetingRooms, bookings: meetingBookings),
            for: day
        )
        await refreshMeetingSchedule(date: activeMeetingScheduleDate, force: true)
    }

    private struct EndedMeetingLiveActivityResult: Codable {
        let bookingID: String
        let endsAt: String
    }

    private func pendingEndedMeetingLiveActivityResult() -> EndedMeetingLiveActivityResult? {
        guard let defaults = UserDefaults(suiteName: meetingLiveActivityAppGroup),
              let data = defaults.data(forKey: endedMeetingLiveActivityKey) else { return nil }
        return try? JSONDecoder().decode(EndedMeetingLiveActivityResult.self, from: data)
    }

    private func savePendingEndedMeetingLiveActivityResult(_ booking: MeetingBooking) {
        let result = EndedMeetingLiveActivityResult(bookingID: booking.id, endsAt: booking.endsAt)
        guard let data = try? JSONEncoder().encode(result) else { return }
        UserDefaults(suiteName: meetingLiveActivityAppGroup)?.set(data, forKey: endedMeetingLiveActivityKey)
    }

    private func clearPendingEndedMeetingLiveActivityResult() {
        UserDefaults(suiteName: meetingLiveActivityAppGroup)?.removeObject(forKey: endedMeetingLiveActivityKey)
    }

    private func serverHasConfirmed(_ result: EndedMeetingLiveActivityResult, in bookings: [MeetingBooking]) -> Bool {
        guard let serverEnd = bookings.first(where: { $0.id == result.bookingID })?.endsAt,
              let expected = MeetingPresentation.date(from: result.endsAt),
              let received = MeetingPresentation.date(from: serverEnd) else { return false }
        return abs(expected.timeIntervalSince(received)) < 1
    }

    /// A LiveActivityIntent runs without presenting the app UI.  It writes the
    /// server-confirmed end time into the shared App Group so the existing
    /// schedule can redraw at that exact time as soon as it is active.
    private func applyEndedMeetingLiveActivityResultIfAvailable() {
        guard let result = pendingEndedMeetingLiveActivityResult() else { return }
        var updated = meetingBookings
        var didUpdate = false
        for index in updated.indices where updated[index].id == result.bookingID {
            let booking = updated[index]
            updated[index] = MeetingBooking(
                id: booking.id,
                roomId: booking.roomId,
                startsAt: booking.startsAt,
                endsAt: result.endsAt,
                title: booking.title,
                attendeeCount: booking.attendeeCount,
                status: booking.status,
                isMine: booking.isMine,
                isOwner: booking.isOwner
            )
            didUpdate = true
        }
        if didUpdate { meetingBookings = normalizedMeetingBookings(updated) }
    }

    private func replaceMeetingInCurrentSchedule(_ serverBooking: MeetingBooking) {
        updateCachedMeetingDetails(from: serverBooking)
        guard meetingBookings.contains(where: { $0.id == serverBooking.id }) else { return }

        // Preserve client-only role flags when mutation endpoints return the
        // lean booking shape without isMine/isOwner. The server-confirmed time
        // and status still replace the old schedule entry immediately.
        var updated = meetingBookings
        for index in updated.indices where updated[index].id == serverBooking.id {
            let current = updated[index]
            updated[index] = MeetingBooking(
                id: serverBooking.id,
                roomId: serverBooking.roomId,
                startsAt: serverBooking.startsAt,
                endsAt: serverBooking.endsAt,
                title: serverBooking.title,
                attendeeCount: serverBooking.attendeeCount,
                status: serverBooking.status,
                isMine: serverBooking.isMine ?? current.isMine,
                isOwner: serverBooking.isOwner ?? current.isOwner
            )
        }

        meetingBookings = normalizedMeetingBookings(updated)
        let day = DateFormatter.meetingDay.string(from: activeMeetingScheduleDate)
        saveMeetingSchedule(
            MeetingScheduleResponse(rooms: meetingRooms, bookings: meetingBookings),
            for: day
        )
    }

    private func normalizedMeetingBookings(_ bookings: [MeetingBooking]) -> [MeetingBooking] {
        let identified = bookings.filter { !$0.id.isEmpty }
        return bookings.filter { booking in
            guard booking.id.isEmpty,
                  let anonymousStart = MeetingPresentation.date(from: booking.startsAt)
            else { return true }
            return !identified.contains { known in
                guard known.roomId == booking.roomId,
                      let knownStart = MeetingPresentation.date(from: known.startsAt)
                else { return false }
                return abs(knownStart.timeIntervalSince(anonymousStart)) < 1
            }
        }
    }

    private func applyMeetingRoomOrder(_ rooms: [MeetingRoom]) -> [MeetingRoom] {
        guard let employeeCode = meetingCacheEmployeeCode else { return rooms }
        let savedOrder = SessionCache.loadMeetingRoomOrder(employeeCode: employeeCode)
        guard !savedOrder.isEmpty else { return rooms }
        let savedRanks = Dictionary(uniqueKeysWithValues: savedOrder.enumerated().map { ($0.element, $0.offset) })
        let fallbackRanks = Dictionary(uniqueKeysWithValues: rooms.enumerated().map { ($0.element.id, $0.offset) })
        return rooms.sorted {
            let left = savedRanks[$0.id] ?? savedOrder.count + (fallbackRanks[$0.id] ?? 0)
            let right = savedRanks[$1.id] ?? savedOrder.count + (fallbackRanks[$1.id] ?? 0)
            return left < right
        }
    }

    /// Personal display preference only; the server catalogue and legacy clients remain unchanged.
    func reorderMeetingRooms(_ rooms: [MeetingRoom]) {
        guard let employeeCode = meetingCacheEmployeeCode else { return }
        let order = rooms.map(\.id)
        SessionCache.saveMeetingRoomOrder(order, employeeCode: employeeCode)
        meetingRooms = applyMeetingRoomOrder(meetingRooms)
    }

    /// Live Activity controls always revalidate with the server; only the
    /// organiser may end or extend an active booking.
    func handleLiveActivityAction(bookingID: String, action: String) async {
        _ = await performMeetingControl(bookingID: bookingID, action: action, extensionMinutes: 5)
    }

    /// Shared by the Live Activity and the in-app ten-minute reminder.  The
    /// endpoint remains unchanged for older clients; only the optional minute
    /// choice is new UI state sent to the existing extend API.
    func performMeetingControl(bookingID: String, action: String, extensionMinutes: Int = 5) async -> String? {
        guard let token else {
            let message = "Phiên đăng nhập đã hết hạn. Vui lòng mở ứng dụng và đăng nhập lại."
            errorMessage = message
            return message
        }
        do {
            switch action {
            case "end":
                let ended: MeetingBooking = try await APIClient.shared.request(
                    "me/meeting-bookings/\(bookingID)/end", method: "POST", token: token
                )
                // Apply the authoritative result immediately. A schedule
                // revalidation runs afterwards and no longer blocks button UI.
                savePendingEndedMeetingLiveActivityResult(ended)
                replaceMeetingInCurrentSchedule(ended)
                if #available(iOS 17.0, *) {
                    MeetingLiveActivityManager.end(bookingID: bookingID)
                }

            case "extend":
                let extended: MeetingBooking = try await APIClient.shared.request(
                    "me/meeting-bookings/\(bookingID)/extend", method: "POST", token: token,
                    body: ExtendMeetingBookingBody(minutes: extensionMinutes)
                )
                replaceMeetingInCurrentSchedule(extended)
                if #available(iOS 17.0, *),
                   let endsAt = MeetingPresentation.date(from: extended.endsAt) {
                    MeetingLiveActivityManager.update(
                        bookingID: bookingID,
                        endsAt: endsAt
                    )
                }

            default:
                return nil
            }

            let refreshDate = activeMeetingScheduleDate
            Task { [weak self] in
                guard let self else { return }
                await self.refreshMeetingSchedule(date: refreshDate, force: true)
            }
            return nil
        } catch {
            present(error)
            return error.localizedDescription
        }
    }
    /// Returns a server-facing failure message so the booking form can present
    /// a short, contextual notice instead of a global blocking alert.
    func createMeeting(room: MeetingRoom, title: String, start: Date, duration: Int, participants: [String]) async -> String? {
        guard let token else { return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại." }
        guard isNetworkAvailable else { return "Mất kết nối internet. Không thể đặt phòng khi đang ngoại tuyến." }
        isWorking = true
        defer { isWorking = false }
        do {
            let end = start.addingTimeInterval(Double(duration) * 60)
            let body = CreateMeetingBookingBody(
                roomId: room.id,
                startsAt: ISO8601DateFormatter().string(from: start),
                endsAt: ISO8601DateFormatter().string(from: end),
                title: title,
                attendeeCount: participants.count + 1,
                participantIds: participants
            )
            let created: MeetingBooking = try await APIClient.shared.request(
                "me/meeting-bookings",
                method: "POST",
                token: token,
                body: body
            )
            // Render the confirmed booking immediately. Waiting only for an
            // independent schedule refresh made a successful booking appear
            // absent in the iOS timeline for several seconds.
            let optimistic = MeetingBooking(
                id: created.id,
                roomId: created.roomId,
                startsAt: created.startsAt,
                endsAt: created.endsAt,
                title: created.title,
                attendeeCount: created.attendeeCount,
                status: created.status,
                isMine: true,
                isOwner: true
            )
            if !meetingBookings.contains(where: { $0.id == optimistic.id }) {
                meetingBookings.append(optimistic)
                meetingBookings.sort { $0.startsAt < $1.startsAt }
            }
            await refreshMeetingSchedule(date: start, force: true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func requestForgotPassword(employeeCode: String) async -> ForgotPasswordRequestResponse? {
        forgotPasswordError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            return try await APIClient.shared.request(
                "auth/forgot-password/request",
                method: "POST",
                body: ForgotPasswordRequestBody(employeeCode: employeeCode.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        } catch {
            forgotPasswordError = error.localizedDescription
            return nil
        }
    }

    private func scheduleRealtimeRefresh(for event: String) {
        if event.contains("attendance_changed") { pendingRealtimeEvents.insert("attendance_changed") }
        if event.contains("request_changed") { pendingRealtimeEvents.insert("request_changed") }
        if event.contains("meal_changed") { pendingRealtimeEvents.insert("meal_changed") }
        if event.contains("meeting_changed") { pendingRealtimeEvents.insert("meeting_changed") }
        if event.contains("content_changed") { pendingRealtimeEvents.insert("content_changed") }
        guard !pendingRealtimeEvents.isEmpty, realtimeRefreshTask == nil else { return }
        realtimeRefreshTask = Task { [weak self] in
            guard let self else { return }
            // Spread a realtime burst over less than one second so hundreds
            // of devices do not refresh the API in the exact same millisecond.
            // A meeting end/extension must visibly update the active room
            // schedule immediately. Other event bursts retain jitter so they
            // do not make all devices refresh at the same instant.
            if !self.pendingRealtimeEvents.contains("meeting_changed") {
                let delay = UInt64.random(in: 250_000_000...750_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            let events = self.pendingRealtimeEvents
            self.pendingRealtimeEvents.removeAll()
            self.realtimeRefreshTask = nil
            if events.contains("request_changed") {
                self.requestRevision &+= 1
            }
            if events.contains("attendance_changed") ||
                events.contains("request_changed") ||
                events.contains("content_changed") ||
                events.contains("meeting_changed") {
                await self.refreshDashboard()
            }
            if events.contains("meal_changed") {
                await self.refreshTodayMenu()
            }
            if events.contains("meeting_changed") {
                await self.refreshMeetingSchedule(date: self.activeMeetingScheduleDate, force: true)
            }
        }
    }

    func confirmForgotPassword(employeeCode: String, code: String, newPassword: String) async -> Bool {
        forgotPasswordError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let _: MessageResponse = try await APIClient.shared.request(
                "auth/forgot-password/confirm",
                method: "POST",
                body: ForgotPasswordConfirmBody(
                    employeeCode: employeeCode.trimmingCharacters(in: .whitespacesAndNewlines),
                    code: code,
                    newPassword: newPassword
                )
            )
            return true
        } catch {
            forgotPasswordError = error.localizedDescription
            return false
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

    func confirmPasswordChange(code: String = "", currentPassword: String? = nil, newPassword: String) async -> Bool {
        guard let token else { return false }
        passwordChangeError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let _: MessageResponse = try await APIClient.shared.request(
                "auth/password-change/confirm", method: "POST", token: token,
                body: PasswordChangeConfirmBody(code: code, currentPassword: currentPassword, newPassword: newPassword)
            )
            await refreshProfile()
            return true
        } catch {
            passwordChangeError = error.localizedDescription
            return false
        }
    }

    func clearPasswordChangeError() {
        passwordChangeError = nil
    }

    func clearForgotPasswordError() {
        forgotPasswordError = nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
