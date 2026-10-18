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

private let sessionRestoreLogger = Logger(
    subsystem: "net.sukavinagroup.user",
    category: "session-restore"
)

/// Meeting rooms feature state (Android: `MeetingStore`).
///
/// `SessionStore` publishes authentication and app-wide state. Feature data
/// lives in its own observable object so a view only redraws for the feature
/// it renders: meeting refreshes no longer redraw the dashboard, profile or
/// request screens, and session changes no longer redraw meeting timelines.
@MainActor
final class MeetingStore: ObservableObject {
    @Published var rooms: [MeetingRoom] = []
    /// Live bookings only. The API returns confirmed bookings; a booking
    /// cancelled on this device must disappear from every screen at once, so
    /// the rule lives here instead of in each view (the iOS 17 UIKit list and
    /// the SwiftUI cards used to disagree). Mirrors Android `MeetingStore`.
    @Published private(set) var bookings: [MeetingBooking] = []
    /// Bookings grouped by room, computed once per change instead of in
    /// every room-list body evaluation.
    @Published private(set) var bookingsByRoom: [String: [MeetingBooking]] = [:]
    @Published var invitees: [MeetingInvitee] = []
    /// Rooms were loaded (or restored from cache) at least once.
    @Published var scheduleLoaded = false
    /// The schedule could not be loaded and no rooms are known; shown with a retry.
    @Published var scheduleError: String?

    func replaceBookings(_ newValue: [MeetingBooking]) {
        // Sorted once here; views used to sort on every body evaluation.
        let live = newValue
            .filter { $0.status != "cancelled" }
            .sorted { $0.startsAt < $1.startsAt }
        bookingsByRoom = Dictionary(grouping: live, by: \.roomId)
        bookings = live
    }

    /// The room's next booking once a meeting ending at `end` is over: what
    /// limits extending it (`MeetingExtension`).
    func nextBooking(after end: Date, inRoom roomId: String, excluding bookingID: String) -> MeetingBooking? {
        let others = (bookingsByRoom[roomId] ?? []).filter { $0.id != bookingID }
        guard let start = MeetingExtension.nextStart(after: end, among: others.compactMap(\.startDate)) else {
            return nil
        }
        return others.first { $0.startDate == start }
    }
}

/// Canteen menu feature state (Android: `MenuStore`).
@MainActor
final class MenuStore: ObservableObject {
    @Published var todayMenu: TodayMenu?
    /// Today's menu could not be loaded and none is cached; the card offers a retry.
    @Published var loadError: String?
}

/// Ends this device's server session at sign-out: revokes its refresh,
/// access and widget tokens and detaches the APNs and push-to-start
/// registrations (`POST auth/logout`). With biometric sign-in enabled it first
/// obtains a separate session for it, so Face ID / Touch ID sign-in keeps
/// working after signing out. Mirrors Android `SessionTokens.signOutInBackground`.
enum ServerSignOut {
    static func run(
        accessToken: String?,
        refreshToken: String?,
        pushToken: String?,
        installationID: String?,
        keepBiometric: Bool
    ) async {
        guard accessToken != nil || refreshToken != nil else { return }
        if keepBiometric {
            guard let dedicated = await biometricSession(accessToken: accessToken, refreshToken: refreshToken),
                  BiometricKeychain.save(refreshToken: dedicated) else {
                // Revoking now would also end the biometric sign-in kept on
                // this device. Fall back to detaching the APNs token only.
                if let accessToken, let pushToken {
                    let _: MessageResponse? = try? await APIClient.shared.request(
                        "auth/push-token",
                        method: "DELETE",
                        token: accessToken,
                        body: PushTokenRegistrationBody(token: pushToken, platform: "ios"),
                        allowSessionRefresh: false
                    )
                }
                return
            }
        }
        // The user may have signed in again meanwhile (biometric sign-in
        // reuses this session); never revoke a session that is in use.
        guard KeychainStore.loadRefreshToken() == nil else { return }
        let _: MessageResponse? = try? await APIClient.shared.request(
            "auth/logout",
            method: "POST",
            token: accessToken,
            body: LogoutBody(
                refreshToken: refreshToken,
                pushToken: pushToken,
                liveActivityInstallationId: installationID
            ),
            allowSessionRefresh: false
        )
    }

    /// A new, separate session's refresh token for biometric sign-in.
    private static func biometricSession(accessToken: String?, refreshToken: String?) async -> String? {
        if let accessToken {
            do {
                let upgraded: LoginResponse = try await APIClient.shared.request(
                    "auth/session/upgrade",
                    method: "POST",
                    token: accessToken,
                    body: EmptyBody(),
                    allowSessionRefresh: false
                )
                return upgraded.refreshToken.isEmpty ? nil : upgraded.refreshToken
            } catch NetworkError.unauthorized {
                // The access token expired; renew it within the same session.
            } catch {
                return nil
            }
        }
        guard let refreshToken else { return nil }
        do {
            let renewed: LoginResponse = try await APIClient.shared.request(
                "auth/refresh",
                method: "POST",
                body: RefreshSessionBody(refreshToken: refreshToken),
                allowSessionRefresh: false
            )
            let upgraded: LoginResponse = try await APIClient.shared.request(
                "auth/session/upgrade",
                method: "POST",
                token: renewed.accessToken,
                body: EmptyBody(),
                allowSessionRefresh: false
            )
            return upgraded.refreshToken.isEmpty ? nil : upgraded.refreshToken
        } catch {
            return nil
        }
    }
}

/// Non-observing access to `SessionStore` for views that only call its
/// methods. `@EnvironmentObject` would redraw such a view on every session
/// change (working flag, errors, badge counts) although it shows none of it;
/// these views observe their feature store or local state instead.
struct SessionActions {
    fileprivate weak var weakStore: SessionStore?

    @MainActor
    var store: SessionStore {
        guard let weakStore else {
            preconditionFailure("SessionStore was not injected; use sessionEnvironment(_:)")
        }
        return weakStore
    }
}

private struct SessionActionsKey: EnvironmentKey {
    static let defaultValue = SessionActions(weakStore: nil)
}

extension EnvironmentValues {
    var sessionActions: SessionActions {
        get { self[SessionActionsKey.self] }
        set { self[SessionActionsKey.self] = newValue }
    }
}

extension View {
    /// Injects the session, its feature stores and the non-observing
    /// `SessionActions` handle. Use this wherever a view hierarchy needs
    /// `SessionStore`, so feature views can observe only their store.
    @MainActor
    func sessionEnvironment(_ session: SessionStore) -> some View {
        modifier(SessionEnvironment(session: session))
    }
}

/// The injection chain behind `sessionEnvironment(_:)`. As one modifier the
/// screens' types only nest `ModifiedContent<_, SessionEnvironment>` instead
/// of ten modifiers (iOS 17 aborted building deep SwiftUI type metadata, see
/// LegacyMeetingRoomsUIKitView).
@MainActor
private struct SessionEnvironment: ViewModifier {
    let session: SessionStore

    func body(content: Content) -> some View {
        content
            .environmentObject(session)
            .environmentObject(session.meetings)
            .environmentObject(session.menu)
            .environmentObject(session.requests)
            .environmentObject(session.badge)
            .environmentObject(session.revisions)
            .environmentObject(session.home)
            .environmentObject(session.inbox)
            .environmentObject(session.account)
            .environment(\.sessionActions, SessionActions(weakStore: session))
    }
}

/// Counters that tell screens to reload their data. They live outside
/// SessionStore's own published state so those screens are not redrawn by
/// every unrelated session change (working flag, errors, badge counts).
@MainActor
final class DataRevisions: ObservableObject {
    /// Today's punches changed, or a realtime event invalidated attendance.
    @Published fileprivate(set) var attendance = 0
    /// Requests or approvals changed on the server.
    @Published fileprivate(set) var request = 0
    /// Meeting bookings or invitations changed on the server.
    @Published fileprivate(set) var meeting = 0
    /// Notifications were read or deleted on another of this user's devices.
    @Published fileprivate(set) var inbox = 0
}

/// What Home shows from the session. Home observed the whole SessionStore and
/// redrew on every working flag, error, badge, news or notification change;
/// this publishes only when the greeting, today's punches or the AI
/// assistant setting change. Kept by SessionStore (`syncHome`).
@MainActor
final class HomeState: ObservableObject {
    struct Summary: Equatable {
        var name = "Nhân viên"
        var employeeCode = ""
        var checkIn: String?
        var checkOut: String?
    }
    @Published fileprivate(set) var summary = Summary()
    @Published fileprivate(set) var aiAssistantEnabled = true
}

/// The news and request notifications the Notifications screen lists, with
/// the news unread state. Published only when they change (see HomeState).
@MainActor
final class InboxState: ObservableObject {
    @Published fileprivate(set) var articles: [ContentItem] = []
    @Published fileprivate(set) var unreadCount = 0
    @Published fileprivate(set) var unreadArticleIDs: Set<String> = []
    @Published fileprivate(set) var requestNotifications: [RequestNotification] = []
}

/// The signed-in account for Profile and the password change, published
/// only when it changes (see HomeState).
@MainActor
final class AccountState: ObservableObject {
    @Published fileprivate(set) var profile: Profile?
    @Published fileprivate(set) var biometricsEnabled = false
    @Published fileprivate(set) var passwordChangeError: String?
}

/// The Notifications tab badge. Only the tab bar observes it.
@MainActor
final class NotificationBadgeState: ObservableObject {
    @Published fileprivate(set) var count = 0
}

@MainActor
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
    @Published var profile: Profile? { didSet { syncHome(); syncAccount() } }
    @Published var dashboard: Dashboard? { didSet { syncHome(); syncInboxArticles() } }
    @Published var errorMessage: String?
    @Published var errorTitle = "Chưa thể thực hiện"
    @Published var errorOffersSettings = false
    @Published var isWorking = false
    @Published var unreadCount = 0 { didSet { syncInboxUnread() } }
    /// News articles not opened yet, by id (the "Mới" badge). Mirrors Android.
    @Published private(set) var unreadArticleIDs: Set<String> = [] { didSet { syncInboxUnread() } }
    @Published var requestUnreadCount = 0
    let badge = NotificationBadgeState()
    /// Stored in `badge`, so only the tab bar redraws when it changes.
    var notificationBadgeCount: Int {
        get { badge.count }
        set { if badge.count != newValue { badge.count = newValue } }
    }
    @Published var biometricsEnabled = BiometricPreferences.enabled { didSet { syncAccount() } }
    @Published var passwordChangeRequiresEmail = false
    @Published var passwordChangeError: String? { didSet { syncAccount() } }
    @Published var forgotPasswordError: String?
    /// Feature stores. Views that render this data observe the store itself;
    /// the forwarding properties below keep the session's networking code
    /// unchanged while no longer publishing feature changes from the session.
    let meetings = MeetingStore()
    let menu = MenuStore()
    /// Own requests and approvals, shared by the Requests and Notifications tabs.
    let requests = EmployeeRequestStore()
    var todayMenu: TodayMenu? {
        get { menu.todayMenu }
        set { menu.todayMenu = newValue }
    }
    var meetingRooms: [MeetingRoom] {
        get { meetings.rooms }
        set { meetings.rooms = newValue }
    }
    var meetingBookings: [MeetingBooking] {
        get { meetings.bookings }
        set { meetings.replaceBookings(newValue) }
    }
    var meetingInvitees: [MeetingInvitee] {
        get { meetings.invitees }
        set { meetings.invitees = newValue }
    }
    @Published private(set) var aiAssistantMobileEnabled = true { didSet { syncHome() } }
    let revisions = DataRevisions()
    /// Read-only copies for Home, Notifications and Profile, kept by the
    /// didSets above and published only when the value they show changes.
    let home = HomeState()
    let inbox = InboxState()
    let account = AccountState()

    private func syncHome() {
        let summary = HomeState.Summary(
            name: dashboard?.name ?? profile?.name ?? "Nhân viên",
            employeeCode: dashboard?.employeeCode ?? profile?.employeeCode ?? "",
            checkIn: dashboard?.attendanceCheckIn,
            checkOut: dashboard?.attendanceCheckOut
        )
        if home.summary != summary { home.summary = summary }
        if home.aiAssistantEnabled != aiAssistantMobileEnabled { home.aiAssistantEnabled = aiAssistantMobileEnabled }
    }

    private func syncInboxArticles() {
        let articles = dashboard?.contentItems ?? []
        if inbox.articles != articles { inbox.articles = articles }
    }

    private func syncInboxUnread() {
        if inbox.unreadCount != unreadCount { inbox.unreadCount = unreadCount }
        if inbox.unreadArticleIDs != unreadArticleIDs { inbox.unreadArticleIDs = unreadArticleIDs }
    }

    private func syncInboxRequests() {
        if inbox.requestNotifications != latestRequestNotifications {
            inbox.requestNotifications = latestRequestNotifications
        }
    }

    private func syncAccount() {
        if account.profile != profile { account.profile = profile }
        if account.biometricsEnabled != biometricsEnabled { account.biometricsEnabled = biometricsEnabled }
        if account.passwordChangeError != passwordChangeError { account.passwordChangeError = passwordChangeError }
    }
    @Published private(set) var isOfflineNoticeVisible = false
    @Published private(set) var isNetworkAvailable = false

    private(set) var token: String?
    private var knownArticleIDs: Set<String> = []
    private let knownArticlesKey = "known-native-article-ids"
    private let unreadArticlesKey = "unread-native-article-ids"
    private let hiddenArticlesKey = "hidden-notification-articles"
    /// Written by older versions (local attendance inbox); only ever removed now.
    private let legacyAttendanceKeyPrefixes = [
        "known-native-attendance-ids-",
        "local-native-attendance-notifications-",
    ]
    private let acknowledgedNotificationBadgePrefix = "acknowledged-native-notification-badge-"
    private let acknowledgedNotificationBadgeDatePrefix = "acknowledged-native-notification-badge-date-"
    /// The inbox's server notifications; the Notifications screen mirrors it.
    @Published private(set) var latestRequestNotifications: [RequestNotification] = [] { didSet { syncInboxRequests() } }
    /// One shared `me/requests/notifications` request (count badge and screen).
    private var requestNotificationsTask: Task<[RequestNotification]?, Never>?
    private var requestNotificationsRerun = false
    /// Shared attendance month requests; a forced call re-runs a running one.
    private var attendanceMonthTasks: [String: Task<AttendanceMonth, Error>] = [:]
    private var attendanceMonthReruns: Set<String> = []
    private var attendanceReportsTask: Task<[AttendanceReport]?, Never>?
    private var attendanceReportsLoadedAt: Date?
    private var todayMenuRerun = false
    private var meetingDetailsReruns: Set<String> = []
    /// Read/unread news are kept per account (`<key>-<employee code>`).
    private var articleOwner: String?
    private var articleBadgeCount = 0
    private let attendanceMonthCachePrefix = "native-attendance-month-"
    private let attendanceMonthCacheOwnerKey = "native-attendance-month-cache-owner"
    private let attendanceReportsCachePrefix = "native-attendance-reports-"
    // Realtime attendance events mark every cached month stale by time instead
    // of decoding and re-encoding each month on the main thread.
    private let attendanceStaleBeforePrefix = "native-attendance-stale-before-"
    // Decoded statement list; the attendance pager reads it for every page.
    private var attendanceReportsMemory: (key: String, value: [AttendanceReport])?
    // Serialises background cache writes so an older dashboard never lands last.
    private var dashboardCacheWrite: Task<Void, Never>?
    // Single-flight dashboard refresh, see refreshDashboard().
    private var dashboardRefreshTask: Task<Void, Never>?
    private var dashboardRefreshRequested = false
    /// Set by callers that also want the notification count; served once per fetch.
    private var dashboardCountRequested = false
    /// When the dashboard was last fetched, for `ensureDashboardFresh`.
    private var dashboardLoadedAt: Date?
    private let dashboardFreshness: TimeInterval = 60
    // Days whose schedule must be fetched again after the in-flight request.
    private var meetingScheduleRerunDays: Set<String> = []
    // Keep decoded month snapshots in RAM as well as UserDefaults. The disk
    // layer survives launches; the memory layer makes repeated opens/swipes
    // avoid JSON decoding and disk reads on the main actor.
    private var attendanceMemoryCache: [String: CachedAttendanceMonth] = [:]
    private let dashboardCachePrefix = "native-dashboard-cache-"
    private let todayMenuCachePrefix = "native-today-menu-cache-"
    private let requestNotificationsCachePrefix = "native-request-notifications-cache-"
    private let aiAssistantMobileEnabledKey = "native-ai-assistant-mobile-enabled"
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
    /// Network handoffs refresh the meeting schedule only once it was opened.
    private var hasViewedMeetingSchedule = false
    /// A badge reset the server has not confirmed yet.
    private var badgeResetPending = false
    /// The live update stream connected at least once in this session; a
    /// later connection follows a gap in which events may have been missed.
    private var realtimeConnectedBefore = false
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
    private var transportReachabilityObserver: NSObjectProtocol?
    private var sessionRefreshedObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    // Foreground activation also fires after Control Center, the notification
    // shade and system sheets. Throttle the work it triggers.
    private var lastForegroundRefreshAt: Date?
    private var lastSessionRefreshAt: Date?
    private let foregroundRefreshInterval: TimeInterval = 60
    private let sessionRefreshInterval: TimeInterval = 60 * 60
    // Suppress duplicate Internet-loss alerts from concurrent API calls.
    // Reset only after a real HTTP response proves connectivity is back.
    private var hasPresentedOfflineAlertForCurrentOutage = false

    init() {
        aiAssistantMobileEnabled =
            UserDefaults.standard.object(forKey: aiAssistantMobileEnabledKey) as? Bool ?? true
        transportReachabilityObserver = NotificationCenter.default.addObserver(
            forName: .sukavinaTransportReachable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Posted after every HTTP response. Assigning an unchanged
                // @Published value still redraws every observing view.
                if !self.isNetworkAvailable { self.isNetworkAvailable = true }
                self.hasPresentedOfflineAlertForCurrentOutage = false
                if self.offlineNoticeTask != nil {
                    self.offlineNoticeTask?.cancel()
                    self.offlineNoticeTask = nil
                }
                if self.isOfflineNoticeVisible { self.isOfflineNoticeVisible = false }
            }
        }
        sessionRefreshedObserver = NotificationCenter.default.addObserver(
            forName: .sukavinaSessionRefreshed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // From APIClient (a LoginResponse) or from a Live Activity action
            // (userInfo; that file is also built into the widget extension).
            let response = notification.object as? LoginResponse
            guard let accessToken = response?.accessToken ?? notification.userInfo?["accessToken"] as? String,
                  !accessToken.isEmpty else { return }
            let refreshToken = response?.refreshToken ?? notification.userInfo?["refreshToken"] as? String ?? ""
            Task { @MainActor [weak self] in
                guard let self, self.state == .signedIn else { return }
                // The token was renewed for a request; use it from now on
                // instead of paying for a 401 + refresh on every call.
                self.token = accessToken
                self.lastSessionRefreshAt = Date()
                if self.biometricsEnabled, !refreshToken.isEmpty {
                    _ = BiometricKeychain.save(refreshToken: refreshToken)
                }
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // The realtime stream only refreshes visible UI; APNs covers the
                // background. It is reopened in appBecameActive().
                self?.eventStreamTask?.cancel()
                self?.eventStreamTask = nil
            }
        }
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
        // Property observers do not run for values set in this initializer.
        syncHome()
        syncInboxArticles()
        syncInboxUnread()
        syncInboxRequests()
        syncAccount()
    }

    deinit {
        offlineNoticeTask?.cancel()
        if let transportReachabilityObserver {
            NotificationCenter.default.removeObserver(transportReachabilityObserver)
        }
        if let sessionRefreshedObserver {
            NotificationCenter.default.removeObserver(sessionRefreshedObserver)
        }
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
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
        guard let cacheKey = attendanceMonthCacheKey(month) else { return nil }
        if let cached = attendanceMemoryCache[cacheKey] {
            return cached.value
        }
        guard let data = AccountDocumentStore.shared.data(forKey: cacheKey) else { return nil }
        if let cached = try? JSONDecoder().decode(CachedAttendanceMonth.self, from: data) {
            attendanceMemoryCache[cacheKey] = cached
            return cached.value
        }
        // One-release migration path for the former unversioned cache. Mark it
        // stale so it is painted immediately but refreshed in the background.
        if let legacy = try? JSONDecoder().decode(AttendanceMonth.self, from: data) {
            attendanceMemoryCache[cacheKey] = CachedAttendanceMonth(savedAt: .distantPast, value: legacy)
            return legacy
        }
        return nil
    }

    func shouldRevalidateAttendanceMonth(_ month: String) -> Bool {
        guard let cacheKey = attendanceMonthCacheKey(month) else { return true }
        let cached: CachedAttendanceMonth
        if let memory = attendanceMemoryCache[cacheKey] {
            cached = memory
        } else {
            guard let data = AccountDocumentStore.shared.data(forKey: cacheKey),
                  let disk = try? JSONDecoder().decode(CachedAttendanceMonth.self, from: data) else { return true }
            attendanceMemoryCache[cacheKey] = disk
            cached = disk
        }
        if let employeeCode = attendanceCacheEmployeeCode(),
           let staleBefore = UserDefaults.standard.object(forKey: attendanceStaleBeforePrefix + employeeCode) as? Date,
           cached.savedAt < staleBefore {
            return true
        }
        let currentMonth = String(VietnamTime.dayKey.string(from: Date()).prefix(7))
        let ttl: TimeInterval = month == currentMonth ? 90 : 12 * 60 * 60
        return Date().timeIntervalSince(cached.savedAt) >= ttl
    }

    /// Concurrent callers for one month share a request. `force` (a change
    /// was just announced) never settles for a request that started before
    /// it: the running one is followed by one more. A cached month is
    /// returned when the network fails.
    func loadAttendanceMonth(_ month: String, token: String, force: Bool = false) async throws -> AttendanceMonth {
        if let running = attendanceMonthTasks[month] {
            if force { attendanceMonthReruns.insert(month) }
            return try await running.value
        }
        let task = Task { @MainActor [weak self] () throws -> AttendanceMonth in
            guard let self else { throw CancellationError() }
            var loaded: AttendanceMonth
            repeat {
                self.attendanceMonthReruns.remove(month)
                do {
                    loaded = try await APIClient.shared.request(
                        "me/attendance?month=\(month)", token: self.token ?? token
                    )
                    self.saveAttendanceMonth(loaded, for: month)
                } catch {
                    if let cached = self.cachedAttendanceMonth(month) { return cached }
                    throw error
                }
            } while self.attendanceMonthReruns.contains(month) && !Task.isCancelled
            return loaded
        }
        attendanceMonthTasks[month] = task
        defer { if attendanceMonthTasks[month] == task { attendanceMonthTasks[month] = nil } }
        return try await task.value
    }

    /// Released statements never change and a new one is announced by a
    /// realtime attendance event (which clears `attendanceReportsLoadedAt`),
    /// so a list loaded within the TTL is returned without a request, and the
    /// list and detail screens share one request. Mirrors Android.
    func loadAttendanceReports() async -> [AttendanceReport] {
        guard token != nil else { return [] }
        if let attendanceReportsLoadedAt,
           Date().timeIntervalSince(attendanceReportsLoadedAt) < 30 * 60 {
            return cachedAttendanceReports()
        }
        if let running = attendanceReportsTask {
            return await running.value ?? cachedAttendanceReports()
        }
        let task = Task { @MainActor [weak self] () -> [AttendanceReport]? in
            guard let self, let token = self.token else { return nil }
            guard let reports: [AttendanceReport] = try? await APIClient.shared.request(
                "me/attendance/reports", token: token
            ) else { return nil }
            self.saveAttendanceReports(reports)
            self.attendanceReportsLoadedAt = Date()
            return reports
        }
        attendanceReportsTask = task
        let reports = await task.value
        if attendanceReportsTask == task { attendanceReportsTask = nil }
        return reports ?? cachedAttendanceReports()
    }

    /// Released attendance statements are immutable, so show this disk-backed
    /// snapshot immediately and refresh it from the server in the background.
    func cachedAttendanceReports() -> [AttendanceReport] {
        guard let cacheKey = attendanceReportsCacheKey() else { return [] }
        if let memory = attendanceReportsMemory, memory.key == cacheKey { return memory.value }
        guard let data = AccountDocumentStore.shared.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(CachedValue<[AttendanceReport]>.self, from: data) else {
            return []
        }
        attendanceReportsMemory = (cacheKey, cached.value)
        return cached.value
    }

    private func attendanceMonthCacheKey(_ month: String) -> String? {
        let employeeCode = profile?.employeeCode.nilIfEmpty
            ?? dashboard?.employeeCode.nilIfEmpty
            ?? UserDefaults.standard.string(forKey: attendanceMonthCacheOwnerKey)?.nilIfEmpty
        guard let employeeCode else { return nil }
        return attendanceMonthCachePrefix + employeeCode + "-" + month
    }

    private func attendanceReportsCacheKey() -> String? {
        let employeeCode = profile?.employeeCode.nilIfEmpty
            ?? dashboard?.employeeCode.nilIfEmpty
            ?? UserDefaults.standard.string(forKey: attendanceMonthCacheOwnerKey)?.nilIfEmpty
        guard let employeeCode else { return nil }
        return attendanceReportsCachePrefix + employeeCode
    }

    private func saveAttendanceReports(_ reports: [AttendanceReport]) {
        guard let cacheKey = attendanceReportsCacheKey(),
              let employeeCode = profile?.employeeCode.nilIfEmpty ?? dashboard?.employeeCode.nilIfEmpty,
              let data = try? JSONEncoder().encode(CachedValue(savedAt: Date(), value: reports)) else { return }
        attendanceReportsMemory = (cacheKey, reports)
        UserDefaults.standard.set(employeeCode, forKey: attendanceMonthCacheOwnerKey)
        AccountDocumentStore.shared.set(data, forKey: cacheKey)
    }

    private func saveAttendanceMonth(_ month: AttendanceMonth, for keyMonth: String) {
        guard let cacheKey = attendanceMonthCacheKey(keyMonth),
              let employeeCode = profile?.employeeCode.nilIfEmpty ?? dashboard?.employeeCode.nilIfEmpty else { return }
        let cached = CachedAttendanceMonth(savedAt: Date(), value: month)
        attendanceMemoryCache[cacheKey] = cached
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(employeeCode, forKey: attendanceMonthCacheOwnerKey)
        AccountDocumentStore.shared.set(data, forKey: cacheKey)
    }

    private func invalidateAttendanceCacheForRealtimeUpdate() {
        // Preserve snapshots for instant paint, but persistently mark them stale.
        // This survives leaving the attendance screen or restarting the app after
        // an admin/attendance realtime event, matching Android's cache semantics.
        // A single timestamp replaces decoding and re-encoding every cached
        // month on the main thread for each company-wide event.
        attendanceReportsLoadedAt = nil
        attendanceReportsTask?.cancel()
        attendanceReportsTask = nil
        guard let employeeCode = attendanceCacheEmployeeCode() else { return }
        UserDefaults.standard.set(Date(), forKey: attendanceStaleBeforePrefix + employeeCode)
        let prefix = attendanceMonthCachePrefix + employeeCode + "-"
        for (key, cached) in attendanceMemoryCache where key.hasPrefix(prefix) {
            attendanceMemoryCache[key] = CachedAttendanceMonth(savedAt: .distantPast, value: cached.value)
        }
    }

    private func attendanceCacheEmployeeCode() -> String? {
        profile?.employeeCode.nilIfEmpty
            ?? dashboard?.employeeCode.nilIfEmpty
            ?? UserDefaults.standard.string(forKey: attendanceMonthCacheOwnerKey)?.nilIfEmpty
    }

    private func restoreCachedDashboard() {
        guard let employeeCode = profile?.employeeCode.nilIfEmpty,
              let data = AccountDocumentStore.shared.data(forKey: dashboardCachePrefix + employeeCode),
              let cached = try? JSONDecoder().decode(CachedDashboard.self, from: data) else { return }
        // Shown until replaced, offline included; restore always revalidates.
        dashboard = cached.value
    }

    private func saveDashboardCache(_ value: Dashboard) {
        let employeeCode = value.employeeCode.nilIfEmpty ?? profile?.employeeCode.nilIfEmpty
        guard let employeeCode else { return }
        let key = dashboardCachePrefix + employeeCode
        let cached = CachedDashboard(savedAt: Date(), value: value)
        let previous = dashboardCacheWrite
        // The dashboard includes article HTML; encoding and writing it on the
        // main thread on every refresh caused visible hitches.
        dashboardCacheWrite = Task.detached(priority: .utility) {
            await previous?.value
            // Cancelled at sign-out: never write the previous account back.
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(cached) else { return }
            AccountDocumentStore.shared.set(data, forKey: key)
        }
    }

    private var cacheEmployeeCode: String? {
        profile?.employeeCode.nilIfEmpty ?? dashboard?.employeeCode.nilIfEmpty
    }

    private func restoreCachedTodayMenu() {
        guard let employeeCode = cacheEmployeeCode,
              let data = AccountDocumentStore.shared.data(forKey: todayMenuCachePrefix + employeeCode),
              let cached = try? JSONDecoder().decode(CachedValue<TodayMenu>.self, from: data),
              cached.value.date == VietnamTime.dayKey.string(from: Date()),
              Date().timeIntervalSince(cached.savedAt) < 24 * 60 * 60 else { return }
        todayMenu = cached.value
        todayMenuLoadedAt = cached.savedAt
    }

    private func saveTodayMenuCache(_ value: TodayMenu) {
        guard let employeeCode = cacheEmployeeCode,
              let data = try? JSONEncoder().encode(CachedValue(savedAt: Date(), value: value)) else { return }
        AccountDocumentStore.shared.set(data, forKey: todayMenuCachePrefix + employeeCode)
    }

    func cachedRequestNotifications() -> [RequestNotification] {
        guard let employeeCode = cacheEmployeeCode,
              let data = AccountDocumentStore.shared.data(forKey: requestNotificationsCachePrefix + employeeCode),
              let cached = try? JSONDecoder().decode(CachedValue<[RequestNotification]>.self, from: data) else {
            return mergedRequestNotifications([])
        }
        return mergedRequestNotifications(cached.value)
    }

    /// Returns false when there is no account to save for yet.
    private func saveRequestNotificationsCache(_ values: [RequestNotification]) -> Bool {
        let inboxValues = values.filter { !isAttendanceNotificationType($0.type) }
        guard let employeeCode = cacheEmployeeCode,
              let data = try? JSONEncoder().encode(CachedValue(savedAt: Date(), value: inboxValues)) else { return false }
        AccountDocumentStore.shared.set(data, forKey: requestNotificationsCachePrefix + employeeCode)
        return true
    }
    /// The list last written to the cache (nil: unknown, write the next one).
    private var savedRequestNotifications: [RequestNotification]?

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

    private func completeRestore(accessToken savedToken: String?, refreshToken savedRefreshToken: String?, attemptID: UUID) {
        guard activeRestoreAttempt == attemptID else { return }
        activeRestoreAttempt = nil
        guard savedToken != nil || savedRefreshToken != nil else {
            sessionRestoreLogger.notice("Restore completed: no saved session")
            // The session ended while the app was not running (or sign-out
            // was interrupted): no account data may outlive it.
            AccountDocumentStore.shared.removeAll()
            AccountDocumentStore.revalidation.removeAll()
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
        var profileFetched = false
        do {
            if let savedToken {
                do {
                    profile = try await APIClient.shared.request("auth/me", token: savedToken)
                    profileFetched = true
                    if let profile { SessionCache.save(profile: profile) }
                    if await Self.storedRefreshToken() == nil {
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
            Task {
                await NotificationManager.shared.requestAuthorizationIfNeeded()
            }
            async let aiSettings: Void = refreshAiAssistantAvailability()
            await refreshDashboard()
            // auth/me was fetched above unless the token had to be renewed.
            if !profileFetched { await refreshProfile() }
            _ = await aiSettings
            // The session was just validated: the next foreground does not
            // need to repeat the same requests.
            lastForegroundRefreshAt = Date()
            if lastSessionRefreshAt == nil { lastSessionRefreshAt = Date() }
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
        // Reopen the realtime stream closed when the app went to background.
        if eventStreamTask == nil, profile?.accountType != "CANTEEN" {
            startRealTimeUpdates()
        }
        let now = Date()
        // An in-flight refresh is left to finish: cancelling it could drop a
        // response the server has already issued.
        guard foregroundRefreshTask == nil else { return }
        if let lastForegroundRefreshAt, now.timeIntervalSince(lastForegroundRefreshAt) < foregroundRefreshInterval {
            return
        }
        lastForegroundRefreshAt = now
        let shouldRefreshSession = lastSessionRefreshAt.map { now.timeIntervalSince($0) >= sessionRefreshInterval } ?? true
        foregroundRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.foregroundRefreshTask = nil }
            if shouldRefreshSession {
                do {
                    try await self.refreshSession()
                } catch NetworkError.unauthorized {
                    self.signOut()
                    return
                } catch {
                    ConnectionDiagnostics.record("Foreground session refresh deferred: \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled else { return }
            // Fetch the tab/icon count immediately. Previously it waited for
            // the profile and dashboard refreshes to finish first.
            async let notificationCountRefresh: Void = self.refreshRequestNotificationCount()
            if self.profile?.accountType == "CANTEEN" {
                self.startSessionRefresh()
                return
            }
            async let aiSettingsRefresh: Void = self.refreshAiAssistantAvailability()
            await self.ensureDashboardFresh()
            await self.refreshTodayMenu()
            _ = await notificationCountRefresh
            _ = await aiSettingsRefresh
            if self.eventStreamTask == nil { self.startRealTimeUpdates() }
            self.startSessionRefresh()
        }
    }

    func signIn(loginId: String, password: String) async -> Bool {
        activeRestoreAttempt = nil
        isWorking = true
        defer { isWorking = false }
        let normalizedLoginId = loginId.trimmingCharacters(in: .whitespacesAndNewlines)
        ConnectionDiagnostics.record("Sign-in started; identifierLength=\(normalizedLoginId.count)")
        // NWPathMonitor is advisory and can briefly report .unsatisfied while
        // iOS hands connectivity between Wi-Fi and cellular. Let URLSession
        // make the authoritative connection attempt instead of blocking login.
        do {
            let response: LoginResponse = try await APIClient.shared.request(
                "auth/login",
                method: "POST",
                body: LoginBody(loginId: normalizedLoginId, password: password)
            )
            applySession(response)

            // Publish the authenticated UI before any optional local cleanup,
            // notification registration or path-monitor work. This prevents a
            // successful HTTP 201 from appearing stuck on slower cellular paths.
            state = .signedIn

            Task { @MainActor [weak self] in
                guard let self else { return }
                await Task.yield()
                self.resetBiometricsWhenAccountChanges(to: response.user.employeeCode)
                self.loadKnownArticles()
                self.startNetworkMonitoring()
                await self.hydrateSignedInSession(
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
            // A forced refresh reacts to a change made after the running
            // request may have started: run once more when it finishes.
            if force { todayMenuRerun = true }
            await existing.value
            return
        }

        menu.loadError = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var value: TodayMenu
                repeat {
                    self.todayMenuRerun = false
                    value = try await APIClient.shared.request("me/menu", token: self.token ?? token)
                } while self.todayMenuRerun && !Task.isCancelled
                guard !Task.isCancelled else { return }
                self.todayMenu = value
                self.menu.loadError = nil
                self.todayMenuLoadedAt = Date()
                self.saveTodayMenuCache(value)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // Keep a restored menu visible if revalidation is temporarily
                // unavailable instead of replacing useful cached UI with an alert.
                if self.todayMenu == nil {
                    // Shown on the card with a retry, not as an alert over
                    // whatever screen the user is on.
                    self.menu.loadError = error.localizedDescription
                } else {
                    ConnectionDiagnostics.record(
                        "Today menu refresh deferred: \(error.localizedDescription)"
                    )
                }
            }
        }

        todayMenuRefreshTask = task
        await task.value
        if todayMenuRefreshTask == task { todayMenuRefreshTask = nil }
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
        todayMenuRefreshTask?.cancel()
        todayMenuRefreshTask = nil
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
        todayMenuRefreshTask?.cancel()
        todayMenuRefreshTask = nil
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

    // The sensor type never changes while the app runs; views read this on
    // every redraw, so query LocalAuthentication once.
    private lazy var biometryType: LABiometryType = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }()

    var biometricName: String {
        biometryType == .touchID ? "Touch ID" : "Face ID"
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
            // The same follow-up as a password sign-in: it used to skip
            // auth/me (email, manager), the news state, notification
            // permission and the AI assistant setting.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await Task.yield()
                self.loadKnownArticles()
                self.startNetworkMonitoring()
                await self.hydrateSignedInSession(
                    isCanteen: response.user.accountType == "CANTEEN" && response.user.employeeCode != "DEMO"
                )
            }
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
        BiometricPreferences.enabled = false
        BiometricPreferences.employeeCode = nil
        biometricsEnabled = false
        Task.detached(priority: .utility) {
            BiometricKeychain.clear()
        }
    }

    private func resetBiometricsWhenAccountChanges(to employeeCode: String) {
        guard biometricsEnabled else { return }
        guard BiometricPreferences.employeeCode == employeeCode else {
            disableBiometricLogin()
            return
        }
    }

    /// Something changed (realtime event, pull-to-refresh, sign-in): fetch
    /// the dashboard. Callers share one in-flight request; a call that arrives
    /// meanwhile schedules exactly one more pass, so a change made after the
    /// first request started is still fetched and an older response can never
    /// be applied after a newer one. The notification count is refreshed once
    /// per pass, not once per caller.
    func refreshDashboard(shouldRefreshRequestNotificationCount: Bool = true) async {
        if shouldRefreshRequestNotificationCount { dashboardCountRequested = true }
        if let running = dashboardRefreshTask {
            dashboardRefreshRequested = true
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.dashboardRefreshRequested = false
                await self.fetchDashboard()
                if self.dashboardCountRequested, self.state == .signedIn {
                    self.dashboardCountRequested = false
                    await self.refreshRequestNotificationCount()
                }
            } while self.dashboardRefreshRequested && !Task.isCancelled
        }
        dashboardRefreshTask = task
        await task.value
        if dashboardRefreshTask == task { dashboardRefreshTask = nil }
    }

    /// A screen or lifecycle event wants recent data (tab appears, app
    /// returns, network comes back): join a fetch already running, and skip
    /// the request entirely when the dashboard is under a minute old. Real
    /// changes arrive through realtime events, which call `refreshDashboard`.
    func ensureDashboardFresh() async {
        if let running = dashboardRefreshTask {
            await running.value
            return
        }
        if let dashboardLoadedAt, Date().timeIntervalSince(dashboardLoadedAt) < dashboardFreshness { return }
        await refreshDashboard()
    }

    private func fetchDashboard() async {
        guard let token, profile?.accountType != "CANTEEN" else { return }
        let generation = SessionGeneration.current
        do {
            let fresh: Dashboard = try await APIClient.shared.request("me/dashboard", token: token)
            // Signed out (or into another account) while the request ran:
            // never apply, cache or show the previous account's dashboard.
            guard generation == SessionGeneration.current, state == .signedIn else { return }
            dashboardLoadedAt = Date()
            processNewArticles(fresh.contentItems)
            // Attendance screens reload when this revision changes. Bump it only
            // when today's punches actually changed, not on every dashboard
            // fetch (which made them refetch three months each time).
            let punchesChanged = dashboard.map {
                ($0.attendanceRecords ?? []).map(\.id) != (fresh.attendanceRecords ?? []).map(\.id)
            } ?? false
            dashboard = fresh
            saveDashboardCache(fresh)
            if punchesChanged { revisions.attendance &+= 1 }
            AttendanceWidgetBridge.update(from: fresh)
        } catch is CancellationError {
            // URLSession cancellation is a normal task-lifecycle event, not
            // evidence that the device has lost Internet access.
            return
        } catch {
            present(error)
        }
    }

    func isAttendanceNotificationType(_ type: String) -> Bool {
        type == "attendance_check_in" || type == "attendance_check_out"
    }

    /// Attendance alerts are delivered by APNs only and never shown in the
    /// in-app inbox.
    func mergedRequestNotifications(_ server: [RequestNotification]) -> [RequestNotification] {
        server
            .filter { !isAttendanceNotificationType($0.type) }
            .sorted { $0.createdAt > $1.createdAt }
    }


    func signOut() {
        sessionRestoreLogger.notice("Sign-out requested")
        // A refresh still in flight must not persist new tokens afterwards.
        SessionGeneration.invalidate()
        activeRestoreAttempt = nil
        let logoutToken = token
        let deviceToken = APNsRegistration.deviceToken
        let keepBiometric = biometricsEnabled
        let installationID: String?
        if #available(iOS 17.2, *) {
            installationID = MeetingLiveActivityStartRegistration.installationID
        } else {
            installationID = nil
        }
        // The server drops this device's Live Activity registrations at
        // sign-out, so the next sign-in must upload them again.
        LiveActivityTokenLedger.reset()
        hasViewedMeetingSchedule = false
        realtimeConnectedBefore = false
        lastForegroundRefreshAt = nil
        lastSessionRefreshAt = nil
        eventStreamTask?.cancel()
        eventStreamTask = nil
        realtimeRefreshTask?.cancel()
        realtimeRefreshTask = nil
        pendingRealtimeEvents.removeAll()
        meetingScheduleRefreshTasks.values.forEach { $0.cancel() }
        meetingScheduleRefreshTasks.removeAll()
        meetingScheduleRerunDays.removeAll()
        dashboardRefreshTask?.cancel()
        dashboardRefreshTask = nil
        dashboardRefreshRequested = false
        dashboardCountRequested = false
        dashboardLoadedAt = nil
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
            legacyAttendanceKeyPrefixes.forEach { defaults.removeObject(forKey: $0 + employeeCode) }
            defaults.removeObject(forKey: acknowledgedNotificationBadgePrefix + employeeCode)
            defaults.removeObject(forKey: acknowledgedNotificationBadgeDatePrefix + employeeCode)
            defaults.removeObject(forKey: todayMenuCachePrefix + employeeCode)
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
        savedRequestNotifications = nil
        requestNotificationsTask?.cancel()
        requestNotificationsTask = nil
        attendanceMonthTasks.values.forEach { $0.cancel() }
        attendanceMonthTasks.removeAll()
        attendanceMonthReruns.removeAll()
        attendanceReportsTask?.cancel()
        attendanceReportsTask = nil
        attendanceReportsLoadedAt = nil
        meetingDetailsReruns.removeAll()
        todayMenuRerun = false
        requests.reset()
        if let employeeCode = cacheEmployeeCode {
            UserDefaults.standard.removeObject(
                forKey: "native-employee-requests-cache-" + employeeCode
            )
            purgeAccountCaches(employeeCode: employeeCode)
        }
        attendanceMemoryCache.removeAll()
        attendanceReportsMemory = nil
        dashboardCacheWrite?.cancel()
        dashboardCacheWrite = nil

        SessionCache.clear()
        // Every cached document and revalidation body belongs to this account,
        // also those a sign-out without a known employee code used to miss.
        AccountDocumentStore.shared.removeAll()
        AccountDocumentStore.revalidation.removeAll()
        articleOwner = nil
        knownArticleIDs = []
        token = nil
        profile = nil
        dashboard = nil
        todayMenu = nil
        menu.loadError = nil
        meetingRooms = []
        meetings.scheduleLoaded = false
        meetings.scheduleError = nil
        meetingBookings = []
        meetingInvitees = []
        AttendanceWidgetBridge.clear()
        unreadCount = 0
        unreadArticleIDs = []
        requestUnreadCount = 0
        notificationBadgeCount = 0
        articleBadgeCount = 0
        syncApplicationBadge()
        // Move to the login UI before touching Security.framework.  On some
        // devices SecItemDelete can wait for the protected-data service.
        state = .signedOut
        sessionRestoreLogger.notice("Sign-out completed: showing authentication")
        Task.detached(priority: .utility) {
            // Read the refresh token before the local clear; the server
            // sign-out runs afterwards so the UI never waits on the network.
            let logoutRefreshToken = KeychainStore.loadRefreshToken()
            KeychainStore.clear(accessToken: logoutToken)
            await ServerSignOut.run(
                accessToken: logoutToken,
                refreshToken: logoutRefreshToken,
                pushToken: deviceToken,
                installationID: installationID,
                keepBiometric: keepBiometric
            )
        }
    }

    /// Removes every cached document that belongs to the signed-out account
    /// (dashboard, attendance, meetings) so a shared device keeps none of the
    /// previous user's data. Device-level preferences such as the personal
    /// meeting-room order are kept. Mirrors the Android sign-out cleanup.
    private func purgeAccountCaches(employeeCode: String) {
        let defaults = UserDefaults.standard
        let exactKeys = [
            dashboardCachePrefix + employeeCode,
            attendanceReportsCachePrefix + employeeCode,
            attendanceMonthCacheOwnerKey,
            attendanceStaleBeforePrefix + employeeCode,
        ]
        let prefixes = [attendanceMonthCachePrefix + employeeCode + "-"]
        let keys = defaults.dictionaryRepresentation().keys.filter { key in
            exactKeys.contains(key) || prefixes.contains { key.hasPrefix($0) }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        SessionCache.clearAccount(employeeCode: employeeCode)
    }

    private func hydrateSignedInSession(isCanteen: Bool) async {
        if isCanteen {
            await refreshProfile()
            startSessionRefresh()
            ConnectionDiagnostics.record("Canteen sign-in completed successfully")
            return
        }

        // User data must load independently of notification services. On some
        // cellular/carrier combinations notification authorization/APNs work can
        // be delayed even though the HTTPS API is already reachable.
        Task {
            await NotificationManager.shared.requestAuthorizationIfNeeded()
        }
        async let aiSettings: Void = refreshAiAssistantAvailability()
        await refreshDashboard()
        await refreshProfile()
        _ = await aiSettings
        startRealTimeUpdates()
        startSessionRefresh()
        ConnectionDiagnostics.record("Sign-in completed successfully")
    }

    /// `isRenewal`: the same session was refreshed, not a new sign-in.
    private func applySession(_ response: LoginResponse, isRenewal: Bool = false) {
        // Apply the authenticated identity in memory first. Keychain persistence
        // must not sit on the UI-critical path between HTTP 201 and the portal.
        token = response.accessToken
        let user = response.user
        // The login/refresh response carries only the token's identity. For
        // the same account keep what `auth/me` added (email, manager,
        // password date) instead of replacing it with a stripped copy, and
        // publish only when something actually changed.
        let current = profile?.employeeCode == user.employeeCode ? profile : nil
        let updated = Profile(
            id: current?.id ?? "",
            employeeCode: user.employeeCode,
            name: user.name,
            role: user.role,
            accountType: user.accountType,
            permissions: user.permissions,
            protected: user.protected,
            email: current?.email,
            managerFullName: current?.managerFullName,
            passwordChangedAt: current?.passwordChangedAt,
            mustChangePassword: user.mustChangePassword
        )
        if profile != updated { profile = updated }
        let cachedProfile = profile
        let widgetToken = response.widgetToken
        Task { @MainActor in
            // Persist/cache only after the caller has had a chance to publish
            // .signedIn. Widget/App Group work must never delay the login UI.
            await Task.yield()
            if let cachedProfile { SessionCache.save(profile: cachedProfile) }
            if !widgetToken.isEmpty {
                AttendanceWidgetBridge.configure(token: widgetToken)
            }
        }

        let accessToken = response.accessToken
        let refreshToken = response.refreshToken
        Task.detached(priority: .utility) {
            KeychainStore.save(token: accessToken)
            if !refreshToken.isEmpty {
                KeychainStore.save(refreshToken: refreshToken)
            }
        }

        // Push registration belongs to a sign-in; a token renewal keeps it.
        guard !isRenewal else { return }
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

    /// Keychain reads can block on the security daemon; keep them off the
    /// main actor (restore and token renewal run on it).
    private nonisolated static func storedRefreshToken() async -> String? {
        await Task.detached(priority: .userInitiated) { KeychainStore.loadRefreshToken() }.value
    }

    private func refreshSession() async throws {
        // Captured before any suspension so a sign-out meanwhile is detected.
        let generation = SessionGeneration.current
        guard let refreshToken = await Self.storedRefreshToken() else {
            throw NetworkError.unauthorized
        }
        let response: LoginResponse = try await APIClient.shared.request(
            "auth/refresh",
            method: "POST",
            body: RefreshSessionBody(refreshToken: refreshToken)
        )
        guard generation == SessionGeneration.current, state != .signedOut else { return }
        lastSessionRefreshAt = Date()
        applySession(response, isRenewal: true)
        if biometricsEnabled, !response.refreshToken.isEmpty {
            // Keychain items with access control can block; keep them off main.
            let refreshToken = response.refreshToken
            Task.detached(priority: .utility) { _ = BiometricKeychain.save(refreshToken: refreshToken) }
        }
    }

    private func startSessionRefresh() {
        sessionRefreshTask?.cancel()
        sessionRefreshTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                // Wake 10 minutes before the current access token expires
                // (its JWT exp), not on a fixed 12-hour cycle that ignored
                // the token's age. After a failed attempt, back off (1 min
                // doubling to 15 min) instead of retrying in a tight loop.
                guard let token = self?.token else { return }
                let renewal = AccessTokenTiming.renewalDate(for: token, now: Date())
                let backoff = failures == 0 ? 0 : min(15 * 60, 60 * pow(2, Double(failures - 1)))
                let wait = max(renewal.timeIntervalSinceNow, backoff, 0)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                do {
                    try await self.refreshSession()
                    failures = 0
                } catch NetworkError.unauthorized {
                    self.signOut()
                    return
                } catch {
                    failures += 1
                    ConnectionDiagnostics.record("Session refresh deferred: \(error.localizedDescription)")
                }
            }
        }
    }

    func refreshRequestNotificationCount() async {
        _ = await loadRequestNotifications(force: true)
    }

    /// The inbox's server notifications. The badge (realtime events) and the
    /// Notifications screen used to fetch them separately for the same
    /// change; now they share one request, and a forced call made while one
    /// runs is followed by one more instead of reusing an older response.
    @discardableResult
    func loadRequestNotifications(force: Bool = false) async -> [RequestNotification]? {
        if let running = requestNotificationsTask {
            if force { requestNotificationsRerun = true }
            return await running.value
        }
        let task = Task { @MainActor [weak self] () -> [RequestNotification]? in
            guard let self else { return nil }
            var values: [RequestNotification]?
            repeat {
                self.requestNotificationsRerun = false
                guard let token = self.token else { return nil }
                values = try? await APIClient.shared.request("me/requests/notifications", token: token)
            } while self.requestNotificationsRerun && !Task.isCancelled
            guard !Task.isCancelled, let values else { return nil }
            self.updateRequestUnreadCount(values)
            return self.latestRequestNotifications
        }
        requestNotificationsTask = task
        let result = await task.value
        if requestNotificationsTask == task { requestNotificationsTask = nil }
        return result
    }

    func updateRequestUnreadCount(_ values: [RequestNotification]) {
        let inboxValues = mergedRequestNotifications(values)
        // Every load and read mark lands here: publish and rewrite the cache
        // only when the list changed.
        if latestRequestNotifications != inboxValues { latestRequestNotifications = inboxValues }
        if savedRequestNotifications != inboxValues, saveRequestNotificationsCache(inboxValues) {
            savedRequestNotifications = inboxValues
        }
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
        let currentUnreadIDs = latestRequestNotifications.filter { !$0.read }.map(\.id)
        let acknowledgedIDs = UserDefaults.standard.stringArray(forKey: acknowledgedNotificationBadgePrefix + employeeCode) ?? []
        if notificationBadgeCount == 0, articleBadgeCount == 0, Set(acknowledgedIDs) == Set(currentUnreadIDs) { return }
        let acknowledgedAt = Date()
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
            badgeResetPending = false
        } catch {
            // Retried when the network comes back (see startNetworkMonitoring).
            badgeResetPending = true
            ConnectionDiagnostics.record("APNs badge reset sync deferred: \(error.localizedDescription)")
        }
    }

    private func syncApplicationBadge() {
        // setBadgeCount replaces applicationIconBadgeNumber (deprecated in iOS 17).
        UNUserNotificationCenter.current().setBadgeCount(max(0, notificationBadgeCount)) { _ in }
    }

    func dismissError() {
        errorMessage = nil
        errorTitle = "Chưa thể thực hiện"
        errorOffersSettings = false
    }

    private func present(_ error: Error) {
        guard !(error is CancellationError) else { return }

        let isOfflineError: Bool
        if let networkError = error as? NetworkError,
           case .offline = networkError {
            isOfflineError = true
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .resourceUnavailable, .cannotLoadFromNetwork:
                isOfflineError = true
            default:
                isOfflineError = false
            }
        } else {
            isOfflineError = false
        }

        if isOfflineError {
            // Several dashboard/profile/notification requests can fail at the
            // same time when Internet disappears. Present one alert for the
            // whole outage instead of one alert per failed request.
            guard !hasPresentedOfflineAlertForCurrentOutage else {
                ConnectionDiagnostics.record("Duplicate offline alert suppressed")
                return
            }
            hasPresentedOfflineAlertForCurrentOutage = true
            errorMessage = NetworkError.offline.localizedDescription
            errorTitle = "Kiểm tra kết nối Internet"
            errorOffersSettings = false
            return
        }

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
        guard profile?.accountType != "CANTEEN" else {
            eventStreamTask = nil
            return
        }
        eventStreamTask = Task { [weak self] in
            guard let self else { return }
            // The signed-in stream: company-wide changes plus this employee's
            // own. The anonymous public stream no longer says whose data changed.
            guard let eventsURL = URL(string: "me/events", relativeTo: SukavinaServer.api)?.absoluteURL else { return }
            // Consecutive failures without receiving data; drives the backoff.
            var failures = 0
            // One immediate token renewal per failure streak, so a revoked
            // session cannot spin in a tight 401 loop.
            var renewedAfterUnauthorized = false
            while !Task.isCancelled {
                do {
                    guard let accessToken = self.token else { return }
                    var request = URLRequest(url: eventsURL)
                    request.timeoutInterval = 60 * 60
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                    let (bytes, response) = try await NetworkSessions.events.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw NetworkError.invalidResponse
                    }
                    if http.statusCode == 401, !renewedAfterUnauthorized {
                        // Expired access token: renew it and reconnect at once.
                        renewedAfterUnauthorized = true
                        try await self.refreshSession()
                        continue
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw NetworkError.invalidResponse
                    }
                    renewedAfterUnauthorized = false

                    // Revalidate once whenever SSE establishes/re-establishes.
                    // This closes the tiny gap where an Admin toggle happened
                    // while the stream was disconnected without adding polling.
                    await self.refreshAiAssistantAvailability()

                    // After a gap (app in the background, network loss) an
                    // attendance change made meanwhile, e.g. an HR attendance-code
                    // override, was not announced: mark cached months stale (an
                    // open attendance screen reloads) and revalidate the dashboard
                    // within its freshness window. Mirrors Android.
                    let resumed = self.realtimeConnectedBefore
                    self.realtimeConnectedBefore = true
                    if resumed {
                        // Events missed during the gap can concern any area,
                        // not just attendance: open request, notification and
                        // menu views reload too, and a viewed meeting schedule.
                        self.invalidateAttendanceCacheForRealtimeUpdate()
                        self.revisions.attendance &+= 1
                        self.revisions.request &+= 1
                        self.revisions.meeting &+= 1
                        await self.ensureDashboardFresh()
                        await self.refreshTodayMenu(force: true)
                        if self.hasViewedMeetingSchedule {
                            await self.refreshMeetingSchedule(date: self.activeMeetingScheduleDate, force: true)
                        }
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        failures = 0
                        if line.hasPrefix("data:") && line.contains("_changed") {
                            scheduleRealtimeRefresh(for: line)
                        }
                    }
                    // The server closed the stream cleanly: still wait before
                    // reconnecting instead of looping immediately.
                } catch {
                    if Task.isCancelled { return }
                }
                failures += 1
                try? await Task.sleep(nanoseconds: SessionStore.realtimeReconnectDelay(failures: failures))
            }
        }
    }

    /// 2-5 s after the first failure, doubling up to about five minutes, with
    /// jitter so many devices do not reconnect at the same moment. Mirrors the
    /// Android SSE backoff.
    nonisolated static func realtimeReconnectDelay(failures: Int) -> UInt64 {
        let exponent = min(max(failures - 1, 0), 7)
        let base: UInt64 = 2_000_000_000 << UInt64(exponent)
        let jitter = UInt64.random(in: 0...(base / 2 + 1_000_000_000))
        return min(base + jitter, 300_000_000_000)
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
                // In the background the stream is closed on purpose and
                // appBecameActive refreshes on return; do not reopen it here.
                guard wasStatus != nil,
                      path.status == .satisfied,
                      wasStatus != .satisfied || wasCellular != isCellular,
                      self.token != nil,
                      UIApplication.shared.applicationState == .active else { return }
                if self.badgeResetPending { await self.syncPushBadgeReset() }
                if self.profile?.accountType == "CANTEEN" { return }
                // Reconnecting the stream revalidates the AI setting, and
                // the dashboard pass refreshes the notification count.
                self.startRealTimeUpdates()
                await self.ensureDashboardFresh()
                if self.hasViewedMeetingSchedule {
                    await self.refreshMeetingSchedule(date: self.activeMeetingScheduleDate, force: true)
                }
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

    func refreshAiAssistantAvailability() async {
        guard let token else { return }
        do {
            let settings: AiAssistantSettings = try await APIClient.shared.request(
                "me/ai-assistant/settings",
                token: token
            )
            applyAiAssistantAvailability(settings.mobileEnabled)
        } catch {
            // Keep the last confirmed value when transport is temporarily
            // unavailable. The chat endpoint remains the final server guard.
            ConnectionDiagnostics.record("AI assistant settings refresh deferred: \(error.localizedDescription)")
        }
    }

    private func applyAiAssistantAvailability(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: aiAssistantMobileEnabledKey)
        if aiAssistantMobileEnabled != enabled {
            aiAssistantMobileEnabled = enabled
        }
    }

    func loadAiAssistantHistory() async throws -> [AiAssistantHistoryItem] {
        guard let token else { throw NetworkError.unauthorized }
        return try await APIClient.shared.request(
            "me/ai-assistant/history",
            token: token
        )
    }

    func askAiAssistant(message: String, contextID: String?) async throws -> AiAssistantChatResponse {
        guard let token else { throw NetworkError.unauthorized }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NetworkError.server("Vui lòng nhập nội dung cần hỏi.")
        }

        do {
            return try await APIClient.shared.request(
                "me/ai-assistant/chat",
                method: "POST",
                token: token,
                body: AiAssistantChatBody(message: trimmed, contextId: contextID)
            )
        } catch {
            // If Admin disabled the assistant while this request was in flight,
            // refresh the authoritative setting before surfacing the error.
            await refreshAiAssistantAvailability()
            throw error
        }
    }

    func markArticlesRead() {
        guard let items = dashboard?.contentItems else { return }
        knownArticleIDs.formUnion(items.map(\.id))
        persistKnownArticles(feed: items)
        unreadArticleIDs = []
        persistUnreadArticles()
        unreadCount = 0
        notificationBadgeCount = max(0, notificationBadgeCount - articleBadgeCount)
        articleBadgeCount = 0
        syncApplicationBadge()
    }

    /// Loads this account's read/unread news. The first account opened after
    /// the update adopts the former device-wide lists (almost always the
    /// device's owner); any other account on a shared device starts fresh.
    private func loadKnownArticles() {
        guard let owner = cacheEmployeeCode, owner != articleOwner else { return }
        articleOwner = owner
        let defaults = UserDefaults.standard
        if defaults.object(forKey: knownArticlesKey + "-" + owner) == nil,
           defaults.object(forKey: knownArticlesKey) != nil {
            for key in [knownArticlesKey, unreadArticlesKey, hiddenArticlesKey] {
                if let value = defaults.stringArray(forKey: key) { defaults.set(value, forKey: key + "-" + owner) }
                defaults.removeObject(forKey: key)
            }
        }
        knownArticleIDs = Set(defaults.stringArray(forKey: knownArticlesKey + "-" + owner) ?? [])
        unreadArticleIDs = Set(defaults.stringArray(forKey: unreadArticlesKey + "-" + owner) ?? [])
        unreadCount = unreadArticleIDs.count
    }

    /// News hidden from this account's Notifications list.
    func hiddenArticleIDs() -> Set<String> {
        guard let owner = articleOwner ?? cacheEmployeeCode else { return [] }
        return Set(UserDefaults.standard.stringArray(forKey: hiddenArticlesKey + "-" + owner) ?? [])
    }

    func saveHiddenArticleIDs(_ ids: Set<String>) {
        guard let owner = articleOwner ?? cacheEmployeeCode else { return }
        UserDefaults.standard.set(Array(ids), forKey: hiddenArticlesKey + "-" + owner)
    }

    /// Opening one article marks only that article as read.
    func markArticleRead(_ id: String) {
        guard unreadArticleIDs.remove(id) != nil else { return }
        persistUnreadArticles()
        unreadCount = unreadArticleIDs.count
        if articleBadgeCount > 0 {
            articleBadgeCount -= 1
            notificationBadgeCount = max(0, notificationBadgeCount - 1)
            syncApplicationBadge()
        }
    }

    private func persistUnreadArticles() {
        guard let articleOwner else { return }
        UserDefaults.standard.set(Array(unreadArticleIDs), forKey: unreadArticlesKey + "-" + articleOwner)
    }

    private func processNewArticles(_ items: [ContentItem]) {
        loadKnownArticles()
        if knownArticleIDs.isEmpty {
            knownArticleIDs = Set(items.map(\.id))
            persistKnownArticles(feed: items)
            return
        }
        let newItems = items.filter { !knownArticleIDs.contains($0.id) }
        if !newItems.isEmpty {
            unreadArticleIDs.formUnion(newItems.map(\.id))
            persistUnreadArticles()
            unreadCount = unreadArticleIDs.count
            articleBadgeCount += newItems.count
            notificationBadgeCount += newItems.count
            syncApplicationBadge()
            NotificationManager.shared.notifyNewArticles(newItems, badge: notificationBadgeCount)
            knownArticleIDs.formUnion(newItems.map(\.id))
            persistKnownArticles(feed: items)
        }
    }

    /// Saves at most 300 seen ids, always including every article still in
    /// `feed`. Trimming an arbitrary 300 from the set (as before) could drop
    /// a listed article, which the next refresh announced again as new.
    private func persistKnownArticles(feed: [ContentItem]) {
        guard let articleOwner else { return }
        var listed: [String] = []
        var listedSet = Set<String>()
        for id in feed.map(\.id) where knownArticleIDs.contains(id) && listedSet.insert(id).inserted {
            listed.append(id)
        }
        let others = knownArticleIDs.subtracting(listedSet).sorted()
        let kept = listed + others.prefix(max(0, 300 - listed.count))
        knownArticleIDs = Set(kept)
        UserDefaults.standard.set(kept, forKey: knownArticlesKey + "-" + articleOwner)
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
            // Whether the account lacks an email is a fact of its profile, not
            // of the error's wording (any message mentioning "email" used to
            // count). Re-read the profile: the copy on the device may predate
            // the change. A failed read keeps it and shows the server's text.
            if let token = self.token,
               let current: Profile = try? await APIClient.shared.request("auth/me", token: token) {
                profile = current
                SessionCache.save(profile: current)
            }
            if !hasLinkedEmail {
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
        hasViewedMeetingSchedule = true
        activeMeetingScheduleDate = date
        let day = VietnamTime.dayKey.string(from: date)
        displayCachedMeetingScheduleIfNeeded(for: day)

        guard let token else { return }
        // NWPathMonitor is advisory only. Let URLSession decide whether the
        // current Wi-Fi/cellular route can actually reach the API.
        guard force || shouldRevalidateMeetingSchedule(day: day) else { return }

        // Tab activation, foreground changes and SwiftUI lifecycle callbacks can
        // arrive together. Coalesce them into one request per day.
        if let existing = meetingScheduleRefreshTasks[day] {
            // A forced refresh (after a mutation or realtime event) must not
            // be satisfied by an older in-flight request: run once more.
            if force { meetingScheduleRerunDays.insert(day) }
            await existing.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.meetingScheduleRerunDays.remove(day)
                guard let token = self.token else { return }
                await self.fetchMeetingSchedule(day: day, token: token)
            } while self.meetingScheduleRerunDays.contains(day) && !Task.isCancelled
        }
        meetingScheduleRefreshTasks[day] = task
        await task.value
        if meetingScheduleRefreshTasks[day] == task { meetingScheduleRefreshTasks[day] = nil }
    }

    private func shouldRevalidateMeetingSchedule(day: String) -> Bool {
        guard let employeeCode = meetingCacheEmployeeCode,
              let savedAt = SessionCache.meetingScheduleSavedAt(day: day, employeeCode: employeeCode)
        else { return true }

        let today = VietnamTime.dayKey.string(from: Date())
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
            meetings.scheduleLoaded = true
            meetings.scheduleError = nil
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
            // Known rooms stay usable offline; with none the list shows a retry.
            if meetingRooms.isEmpty {
                meetings.scheduleError = error.localizedDescription
            }
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
        if !rooms.isEmpty { meetings.scheduleLoaded = true }
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
                guard !Task.isCancelled else { return nil }
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
        if meetingInviteesRefreshTask == task { meetingInviteesRefreshTask = nil }
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
            if forceRefresh { meetingDetailsReruns.insert(id) }
            return await existing.value
        }

        guard let token else { return cached?.value }

        let staleValue = cached?.value
        let task = Task { @MainActor [weak self] () -> MeetingBookingDetails? in
            guard let self else { return staleValue }
            do {
                var fresh: MeetingBookingDetails
                repeat {
                    self.meetingDetailsReruns.remove(id)
                    fresh = try await APIClient.shared.request(
                        "me/meeting-bookings/\(id)",
                        token: self.token ?? token
                    )
                } while self.meetingDetailsReruns.contains(id) && !Task.isCancelled
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
        if meetingDetailsRefreshTasks[id] == task { meetingDetailsRefreshTasks[id] = nil }
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
            participants: current.participants,
            isLimitedViewer: current.isLimitedViewer
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
        let day = VietnamTime.dayKey.string(from: activeMeetingScheduleDate)
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
                isOwner: booking.isOwner,
                organizerName: booking.organizerName
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
                isOwner: serverBooking.isOwner ?? current.isOwner,
                organizerName: serverBooking.organizerName ?? current.organizerName
            )
        }

        meetingBookings = normalizedMeetingBookings(updated)
        let day = VietnamTime.dayKey.string(from: activeMeetingScheduleDate)
        saveMeetingSchedule(
            MeetingScheduleResponse(rooms: meetingRooms, bookings: meetingBookings),
            for: day
        )
    }

    /// See `MeetingBookingDeduplication`.
    private func normalizedMeetingBookings(_ bookings: [MeetingBooking]) -> [MeetingBooking] {
        let entries = bookings.map { MeetingBookingDeduplication.Entry(id: $0.id, roomId: $0.roomId, start: $0.startDate) }
        return MeetingBookingDeduplication.keptIndices(entries).map { bookings[$0] }
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
    /// Shared by the Live Activity and the in-app ten-minute reminder.  The
    /// endpoint remains unchanged for older clients; only the optional minute
    /// choice is new UI state sent to the existing extend API.
    func performMeetingControl(bookingID: String, action: String, extensionMinutes: Int = 5) async -> String? {
        // Callers show the message next to the control (not globally too).
        guard let token else {
            return "Phiên đăng nhập đã hết hạn. Vui lòng mở ứng dụng và đăng nhập lại."
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
                MeetingLiveActivityManager.end(bookingID: bookingID)

            case "extend":
                let extended: MeetingBooking = try await APIClient.shared.request(
                    "me/meeting-bookings/\(bookingID)/extend", method: "POST", token: token,
                    body: ExtendMeetingBookingBody(minutes: extensionMinutes)
                )
                replaceMeetingInCurrentSchedule(extended)
                if let endsAt = extended.endDate {
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
            // Callers show this next to the control that failed; presenting
            // it globally as well showed the same error twice.
            return error.localizedDescription
        }
    }
    /// Returns a server-facing failure message so the booking form can present
    /// a short, contextual notice instead of a global blocking alert.
    func createMeeting(room: MeetingRoom, title: String, start: Date, duration: Int, participants: [String]) async -> String? {
        guard let token else { return "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại." }
        isWorking = true
        defer { isWorking = false }
        do {
            let end = start.addingTimeInterval(Double(duration) * 60)
            let body = CreateMeetingBookingBody(
                roomId: room.id,
                startsAt: VietnamTime.iso8601String(from: start),
                endsAt: VietnamTime.iso8601String(from: end),
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
                isOwner: true,
                organizerName: nil
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

    /// `line` is one SSE line; see `RealtimeEvent` for the format and the
    /// employee scope (events for other employees are ignored).
    private func scheduleRealtimeRefresh(for line: String) {
        guard let event = RealtimeEvent(line: line, employeeCode: profile?.employeeCode.nilIfEmpty) else { return }
        if let enabled = event.aiAssistantEnabled {
            applyAiAssistantAvailability(enabled)
            return
        }
        pendingRealtimeEvents.formUnion(event.changes.map(\.rawValue))
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
                self.revisions.request &+= 1
                // One forced reload for every screen showing requests
                // (Requests and Notifications share this store). Mirrors Android.
                Task { await self.requests.load(self.token, force: true) }
            }
            if events.contains("attendance_changed") || events.contains("employee_changed") {
                // Employee/shift edits can change the calculated attendance
                // status for an already cached month just like holiday edits.
                self.invalidateAttendanceCacheForRealtimeUpdate()
                self.revisions.attendance &+= 1
            }
            if events.contains("own_profile_changed") {
                await self.refreshProfile()
            }
            // The dashboard carries attendance and news. Requests and meeting
            // invitations only change the notification count.
            if events.contains("attendance_changed") ||
                events.contains("employee_changed") ||
                events.contains("content_changed") {
                await self.refreshDashboard()
            } else if events.contains("request_changed") || events.contains("meeting_changed") || events.contains("inbox_changed") {
                await self.refreshRequestNotificationCount()
            }
            if events.contains("inbox_changed") {
                self.revisions.inbox &+= 1
            }
            if events.contains("meal_changed") {
                // Forced: the 90 s freshness window would otherwise drop an
                // admin's menu change announced right after a load. Mirrors Android.
                await self.refreshTodayMenu(force: true)
            }
            if events.contains("meeting_changed") {
                self.revisions.meeting &+= 1
                // Only a device that opened the meeting schedule keeps it fresh;
                // refreshing here also marked it viewed, so every device
                // fetched the schedule on every booking change.
                if self.hasViewedMeetingSchedule {
                    await self.refreshMeetingSchedule(date: self.activeMeetingScheduleDate, force: true)
                }
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
