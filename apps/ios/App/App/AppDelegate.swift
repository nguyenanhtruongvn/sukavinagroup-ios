import UIKit
import SwiftUI
import Combine
import Security
import UserNotifications
import Network
import LocalAuthentication
import WidgetKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import WebKit

extension Notification.Name {
    static let sukavinaAPNsTokenUpdated = Notification.Name("net.sukavinagroup.apns-token-updated")
    static let sukavinaMeetingChanged = Notification.Name("net.sukavinagroup.meeting-changed")
}

struct APNsNotificationRoute: Equatable {
    let type: String
    let referenceID: String?
}

/// Keeps an APNs tap available while SwiftUI restores a signed-in session.
final class APNsNotificationRouter: ObservableObject {
    @Published private(set) var pendingRoute: APNsNotificationRoute?

    func handle(userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String, !type.isEmpty else { return }
        let referenceID = (userInfo["requestId"] as? String) ?? (userInfo["bookingId"] as? String)
        DispatchQueue.main.async { [weak self] in
            self?.pendingRoute = APNsNotificationRoute(type: type, referenceID: referenceID)
        }
    }

    func consume(_ route: APNsNotificationRoute) {
        guard pendingRoute == route else { return }
        pendingRoute = nil
    }
}

enum APNsRegistration {
    private static let deviceTokenKey = "net.sukavinagroup.apns-device-token"

    static var deviceToken: String? {
        guard let value = UserDefaults.standard.string(forKey: deviceTokenKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    @MainActor
    static func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        let isAuthorized: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        case .denied:
            isAuthorized = false
        @unknown default:
            isAuthorized = false
        }

        guard isAuthorized else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    static func store(deviceToken: Data) {
        let value = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard !value.isEmpty, value != self.deviceToken else { return }
        UserDefaults.standard.set(value, forKey: deviceTokenKey)
        NotificationCenter.default.post(name: .sukavinaAPNsTokenUpdated, object: nil)
    }
}

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?
    private let notificationRouter = APNsNotificationRouter()
    private var appContainer: NativeAppContainerViewController?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithTransparentBackground()
        tabBarAppearance.backgroundColor = .clear
        // iOS 17–18 do not reliably apply SwiftUI's tab-bar material after a
        // screen has extended below the safe area. Keep the material on the
        // native bar itself; unlike an opaque background, this does not add a
        // bottom panel or reserve extra content height.
        if #available(iOS 26.0, *) {
            tabBarAppearance.backgroundEffect = nil
        } else {
            tabBarAppearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        }
        tabBarAppearance.shadowColor = .clear
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        UITabBar.appearance().isTranslucent = true
        UNUserNotificationCenter.current().delegate = self
        let window = UIWindow(frame: UIScreen.main.bounds)
        let appContainer = NativeAppContainerViewController(notificationRouter: notificationRouter)
        window.rootViewController = appContainer
        window.makeKeyAndVisible()
        self.window = window
        self.appContainer = appContainer
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        appContainer?.appBecameActive()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        publishMeetingChangeIfNeeded(notification.request.content.userInfo)
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        notificationRouter.handle(userInfo: response.notification.request.content.userInfo)
        publishMeetingChangeIfNeeded(response.notification.request.content.userInfo)
        completionHandler()
    }

    private func publishMeetingChangeIfNeeded(_ userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String, type.hasPrefix("meeting_") else { return }
        NotificationCenter.default.post(name: .sukavinaMeetingChanged, object: nil)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        APNsRegistration.store(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        ConnectionDiagnostics.record("APNs registration failed: \(error.localizedDescription)")
    }
}

/// iOS 17's Swift runtime aborts while resolving the large conditional
/// `SukavinaAppView.body` metadata emitted by Xcode 26.  Keep the app's
/// lifecycle in UIKit and host one concrete SwiftUI screen at a time instead.
/// The displayed screens remain the native SwiftUI application; this only
/// removes the incompatible root metadata graph from the first layout pass.
@available(iOS 17.0, *)
@MainActor
private final class NativeAppContainerViewController: UIViewController {
    private let session = SessionStore()
    private let notificationRouter: APNsNotificationRouter
    private var stateObservation: AnyCancellable?
    private var profileObservation: AnyCancellable?
    private var errorObservation: AnyCancellable?
    private var offlineNoticeObservation: AnyCancellable?
    private var host: UIHostingController<AnyView>?
    private let offlineNotice = UILabel()

    init(notificationRouter: APNsNotificationRouter) {
        self.notificationRouter = notificationRouter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        installRootView()
        stateObservation = session.$state.sink { [weak self] _ in
            self?.installRootView()
        }
        profileObservation = session.$profile.sink { [weak self] _ in
            guard self?.session.state == .signedIn else { return }
            self?.installRootView()
        }
        errorObservation = session.$errorMessage.sink { [weak self] message in
            self?.showErrorIfNeeded(message)
        }
        configureOfflineNotice()
        offlineNoticeObservation = session.$isOfflineNoticeVisible.sink { [weak self] isVisible in
            self?.offlineNotice.isHidden = !isVisible
        }
        Task { [weak self] in
            await self?.session.restore()
        }
    }

    func appBecameActive() {
        session.appBecameActive()
    }

    private func installRootView() {
        let rootView = screenForCurrentSession()
        guard let host else {
            let host = UIHostingController(rootView: rootView)
            host.view.backgroundColor = .clear
            addChild(host)
            view.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            host.didMove(toParent: self)
            self.host = host
            return
        }
        host.rootView = rootView
    }

    private func screenForCurrentSession() -> AnyView {
        switch session.state {
        case .restoring:
            return AnyView(NativeLaunchView())
        case .signedOut:
            return AnyView(AuthenticationView().environmentObject(session).environmentObject(notificationRouter))
        case .signedIn:
            if session.profile?.accountType == "CANTEEN" && session.profile?.employeeCode != "DEMO" {
                return AnyView(CanteenScannerView().environmentObject(session).environmentObject(notificationRouter))
            }
            return AnyView(EmployeePortalView().environmentObject(session).environmentObject(notificationRouter))
        }
    }

    private func configureOfflineNotice() {
        offlineNotice.translatesAutoresizingMaskIntoConstraints = false
        offlineNotice.text = "  Mất kết nối internet  "
        offlineNotice.textColor = .white
        offlineNotice.font = .systemFont(ofSize: 14, weight: .semibold)
        offlineNotice.backgroundColor = UIColor(white: 0.11, alpha: 0.96)
        offlineNotice.layer.cornerRadius = 18
        offlineNotice.layer.masksToBounds = true
        offlineNotice.isHidden = true
        view.addSubview(offlineNotice)
        NSLayoutConstraint.activate([
            offlineNotice.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            offlineNotice.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            offlineNotice.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func showErrorIfNeeded(_ message: String?) {
        guard let message, presentedViewController == nil else { return }
        let alert = UIAlertController(title: session.errorTitle, message: message, preferredStyle: .alert)
        if session.errorOffersSettings {
            alert.addAction(UIAlertAction(title: "Mở Cài đặt", style: .default) { _ in
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(settingsURL)
            })
        }
        alert.addAction(UIAlertAction(title: "Đã hiểu", style: .cancel) { [weak self] _ in
            self?.session.dismissError()
        })
        present(alert, animated: true)
    }
}

/// iOS 15–16 compatibility mode. The modern native experience remains the
/// primary app on current systems; older systems use the same responsive,
/// secured employee portal so core workflows stay available instead of
/// crashing on newer SwiftUI APIs.
private final class LegacyPortalViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let portalURL = URL(string: "https://sukavinagroup.net")
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "Sukavina iOS Compatibility"
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.showsHorizontalScrollIndicator = false
        return view
    }()
    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.isHidden = true
        return label
    }()
    private let retryButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Thử lại", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.isHidden = true
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.906, green: 0.914, blue: 0.929, alpha: 1)
        view.addSubview(webView)
        view.addSubview(statusLabel)
        view.addSubview(retryButton)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -22),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        retryButton.addTarget(self, action: #selector(reloadPortal), for: .touchUpInside)
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(refreshPortal(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
        reloadPortal()
    }

    @objc private func reloadPortal() {
        showError(nil)
        guard let portalURL else {
            showError("Địa chỉ máy chủ không hợp lệ.")
            return
        }
        webView.load(URLRequest(url: portalURL, cachePolicy: .reloadRevalidatingCacheData))
    }

    @objc private func refreshPortal(_ sender: UIRefreshControl) {
        webView.reload()
        sender.endRefreshing()
    }

    private func showError(_ message: String?) {
        let hasError = message != nil
        statusLabel.text = message
        statusLabel.isHidden = !hasError
        retryButton.isHidden = !hasError
        webView.isHidden = hasError
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        showError(nil)
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        showError("Không thể kết nối đến máy chủ. Hãy kiểm tra mạng rồi thử lại.")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.host == portalURL?.host {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            decisionHandler(.allow)
        } else if url.scheme == "https" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.cancel)
        }
    }

    @available(iOS 15.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(origin.host == portalURL?.host && type == .camera ? .grant : .deny)
    }
}
