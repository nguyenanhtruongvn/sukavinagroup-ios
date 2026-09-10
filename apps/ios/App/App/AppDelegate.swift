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

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = AppTheme.inkUIColor
        tabBarAppearance.shadowColor = .clear
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        UITabBar.appearance().isTranslucent = false
        UNUserNotificationCenter.current().delegate = self
        let window = UIWindow(frame: UIScreen.main.bounds)
        if #available(iOS 17.0, *) {
            window.rootViewController = UIHostingController(
                rootView: SukavinaAppView().environmentObject(notificationRouter)
            )
        } else {
            window.rootViewController = LegacyPortalViewController()
        }
        window.makeKeyAndVisible()
        self.window = window
        return true
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
