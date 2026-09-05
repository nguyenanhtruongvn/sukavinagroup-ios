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

private extension DateFormatter { static let meetingDay: DateFormatter = { let value = DateFormatter(); value.calendar = Calendar(identifier: .gregorian); value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh"); value.dateFormat = "yyyy-MM-dd"; return value }() }

@MainActor
@available(iOS 17.0, *)
final class SessionStore: ObservableObject {
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
    @Published var passwordChangeError: String?
    @Published var forgotPasswordError: String?
    @Published var todayMenu: TodayMenu?
    @Published var meetingRooms: [MeetingRoom] = []
    @Published var meetingBookings: [MeetingBooking] = []
    @Published var meetingInvitees: [MeetingInvitee] = []
    @Published private(set) var attendanceRevision = 0
    @Published private(set) var requestRevision = 0

    private(set) var token: String?
    private var knownArticleIDs: Set<String> = []
    private let knownArticlesKey = "known-native-article-ids"
    private let knownAttendancePrefix = "known-native-attendance-ids-"
    private var eventStreamTask: Task<Void, Never>?
    private var realtimeRefreshTask: Task<Void, Never>?
    private var pendingRealtimeEvents: Set<String> = []
    private var activeMeetingScheduleDate = Date()
    private var sessionRefreshTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "net.sukavinagroup.network-path")
    private var isMonitoringNetwork = false
    private var lastPathStatus: NWPath.Status?
    private var lastPathWasCellular: Bool?
    private var foregroundRefreshTask: Task<Void, Never>?

    func restore() async {
        startNetworkMonitoring()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let savedToken = KeychainStore.loadToken()
        let savedRefreshToken = KeychainStore.loadRefreshToken()
        guard savedToken != nil || savedRefreshToken != nil else {
            state = .signedOut
            return
        }
        token = savedToken
        profile = SessionCache.loadProfile()
        state = .signedIn
        loadKnownArticles()
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
            await self.refreshProfile()
            if self.profile?.accountType == "CANTEEN" {
                self.startSessionRefresh()
                return
            }
            await self.refreshDashboard()
            self.startRealTimeUpdates()
            self.startSessionRefresh()
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
            if response.user.accountType == "CANTEEN" && response.user.employeeCode != "DEMO" {
                await refreshProfile()
                startSessionRefresh()
                ConnectionDiagnostics.record("Canteen sign-in completed successfully")
                return true
            }
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

    /// Loads the optional menu widget.  Callers that are refreshing an already
    /// populated dashboard can opt out of a global error alert so a transient
    /// menu request does not look like the whole app has lost connectivity.
    func refreshTodayMenu(reportFailure: Bool = true) async {
        guard let token else { return }
        do {
            todayMenu = try await APIClient.shared.request("me/menu", token: token)
        } catch {
            if reportFailure {
                present(error)
            }
        }
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

    /// Refreshes the dashboard.  A pull-to-refresh keeps the last successful
    /// content visible if a temporary request fails, rather than presenting an
    /// unrelated full-screen offline alert over usable cached content.
    func refreshDashboard(reportFailure: Bool = true) async {
        guard let token, profile?.accountType != "CANTEEN" else { return }
        do {
            let fresh: Dashboard = try await APIClient.shared.request("me/dashboard", token: token)
            processNewAttendance(fresh)
            processNewArticles(fresh.contentItems)
            dashboard = fresh
            attendanceRevision &+= 1
            AttendanceWidgetBridge.update(from: fresh)
            await refreshRequestNotificationCount()
        } catch {
            if reportFailure {
                present(error)
            }
        }
    }

    private func processNewAttendance(_ fresh: Dashboard) {
        let employeeCode = fresh.employeeCode.isEmpty ? (profile?.employeeCode ?? "") : fresh.employeeCode
        let key = knownAttendancePrefix + employeeCode
        let defaults = UserDefaults.standard
        let hasBaseline = defaults.object(forKey: key) != nil
        let known = Set(defaults.stringArray(forKey: key) ?? [])
        let records = fresh.attendanceRecords ?? []
        if hasBaseline,
           let newest = records.filter({ !known.contains($0.id) }).max(by: { $0.punchedAt < $1.punchedAt }) {
            let ordered = records.sorted { $0.punchedAt < $1.punchedAt }
            let position = (ordered.firstIndex(where: { $0.id == newest.id }) ?? 0) + 1
            NotificationManager.shared.notifyAttendance(
                isCheckIn: position % 2 == 1,
                time: attendanceNotificationTime(newest.punchedAt)
            )
        }
        defaults.set(records.map(\.id), forKey: key)
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
        eventStreamTask?.cancel()
        eventStreamTask = nil
        realtimeRefreshTask?.cancel()
        realtimeRefreshTask = nil
        pendingRealtimeEvents.removeAll()
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        KeychainStore.clear()
        SessionCache.clear()
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

                // The first callback only records the current path. Refresh after a real reconnect or handoff.
                guard wasStatus != nil,
                      path.status == .satisfied,
                      wasStatus != .satisfied || wasCellular != isCellular,
                      self.token != nil else { return }
                await self.refreshProfile()
                if self.profile?.accountType == "CANTEEN" { return }
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

    func refreshMeetingSchedule(date: Date = .now) async {
        activeMeetingScheduleDate = date
        guard let token else { return }
        do {
            let day = DateFormatter.meetingDay.string(from: date)
            let value: MeetingScheduleResponse = try await APIClient.shared.request(
                "me/meeting-rooms?date=\(day)",
                token: token
            )
            meetingRooms = value.rooms
            meetingBookings = value.bookings
        } catch {
            present(error)
        }
    }

    /// Invitees are optional supporting data for the booking form. Returning the
    /// message lets that form offer a retry without presenting a global
    /// “offline” alert while the room schedule itself is already usable.
    func refreshMeetingInvitees() async -> String? {
        guard let token else { return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại." }
        do {
            meetingInvitees = try await APIClient.shared.request(
                "me/meeting-rooms/invitees",
                token: token
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func meetingBookingDetails(id: String) async -> MeetingBookingDetails? {
        guard let token else { return nil }
        do {
            return try await APIClient.shared.request(
                "me/meeting-bookings/\(id)",
                token: token
            )
        } catch {
            present(error)
            return nil
        }
    }
    func createMeeting(room: MeetingRoom, title: String, start: Date, duration: Int, participants: [String]) async -> Bool { guard let token else { return false }; isWorking = true; defer { isWorking = false }; do { let end = start.addingTimeInterval(Double(duration) * 60); let body = CreateMeetingBookingBody(roomId: room.id, startsAt: ISO8601DateFormatter().string(from: start), endsAt: ISO8601DateFormatter().string(from: end), title: title, attendeeCount: participants.count + 1, participantIds: participants); let _: MeetingBooking = try await APIClient.shared.request("me/meeting-bookings", method: "POST", token: token, body: body); await refreshMeetingSchedule(date: start); return true } catch { present(error); return false } }

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
        if event.contains("content_changed") { pendingRealtimeEvents.insert("content_changed") }
        if event.contains("meeting_changed") { pendingRealtimeEvents.insert("meeting_changed") }
        guard !pendingRealtimeEvents.isEmpty, realtimeRefreshTask == nil else { return }
        realtimeRefreshTask = Task { [weak self] in
            // Spread a realtime burst over less than one second so hundreds
            // of devices do not refresh the API in the exact same millisecond.
            let delay = UInt64.random(in: 250_000_000...750_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            let events = self.pendingRealtimeEvents
            self.pendingRealtimeEvents.removeAll()
            self.realtimeRefreshTask = nil
            if events.contains("request_changed") {
                self.requestRevision &+= 1
            }
            if events.contains("attendance_changed") ||
                events.contains("request_changed") ||
                events.contains("content_changed") {
                await self.refreshDashboard()
            }
            if events.contains("meal_changed") {
                await self.refreshTodayMenu()
            }
            if events.contains("meeting_changed") {
                await self.refreshMeetingSchedule(date: self.activeMeetingScheduleDate)
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
