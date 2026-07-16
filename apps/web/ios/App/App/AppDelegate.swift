import UIKit
import Capacitor
import WebKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UIGestureRecognizerDelegate {

    var window: UIWindow?
    private weak var portalWebView: WKWebView?
    private var hasConfiguredPortal = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        DispatchQueue.main.async { [weak self] in
            self?.configurePortalExperience()
        }
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {}

    func applicationDidEnterBackground(_ application: UIApplication) {}

    func applicationWillEnterForeground(_ application: UIApplication) {}

    func applicationDidBecomeActive(_ application: UIApplication) {
        configurePortalExperience()
    }

    func applicationWillTerminate(_ application: UIApplication) {}

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        ApplicationDelegateProxy.shared.application(
            application,
            continue: userActivity,
            restorationHandler: restorationHandler
        )
    }

    private func configurePortalExperience() {
        guard !hasConfiguredPortal else { return }
        guard let bridgeController = window?.rootViewController as? CAPBridgeViewController,
              let webView = bridgeController.webView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.configurePortalExperience()
            }
            return
        }

        hasConfiguredPortal = true
        portalWebView = webView
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.showsHorizontalScrollIndicator = false

        let appModeScript = WKUserScript(
            source: Self.appModeJavaScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(appModeScript)
        webView.evaluateJavaScript(Self.appModeJavaScript)

        let backGesture = UIScreenEdgePanGestureRecognizer(
            target: self,
            action: #selector(handleBackGesture(_:))
        )
        backGesture.edges = .left
        backGesture.delegate = self
        webView.addGestureRecognizer(backGesture)
    }

    @objc private func handleBackGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended,
              gesture.translation(in: gesture.view).x > 70,
              gesture.velocity(in: gesture.view).x > 0,
              let webView = portalWebView,
              webView.canGoBack else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        webView.goBack()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    private static let appModeJavaScript = #"""
    (() => {
      if (!document.documentElement) return;
      document.documentElement.classList.add('sukavina-ios-app');

      let viewport = document.querySelector('meta[name="viewport"]');
      if (!viewport) {
        viewport = document.createElement('meta');
        viewport.name = 'viewport';
        document.head.appendChild(viewport);
      }
      viewport.content = 'width=device-width, initial-scale=1, viewport-fit=cover';

      if (document.getElementById('sukavina-ios-app-style')) return;
      const style = document.createElement('style');
      style.id = 'sukavina-ios-app-style';
      style.textContent = `
        html.sukavina-ios-app {
          -webkit-text-size-adjust: 100%;
          background: #121116;
          overscroll-behavior-x: none;
        }
        .sukavina-ios-app body {
          min-height: 100dvh;
          margin: 0;
          max-width: 100vw;
          overflow-x: hidden;
          -webkit-tap-highlight-color: transparent;
        }
        .sukavina-ios-app *,
        .sukavina-ios-app *::before,
        .sukavina-ios-app *::after { box-sizing: border-box; }
        .sukavina-ios-app img,
        .sukavina-ios-app video,
        .sukavina-ios-app iframe { max-width: 100%; height: auto; }
        .sukavina-ios-app input,
        .sukavina-ios-app select,
        .sukavina-ios-app textarea { font-size: 16px !important; }
        .sukavina-ios-app button,
        .sukavina-ios-app [role='button'],
        .sukavina-ios-app a { touch-action: manipulation; }
        .sukavina-ios-app button,
        .sukavina-ios-app [role='button'] { min-height: 44px; }
        .sukavina-ios-app ::-webkit-scrollbar { width: 0; height: 0; }
        @media (max-width: 640px) {
          .sukavina-ios-app table {
            display: block;
            max-width: 100%;
            overflow-x: auto;
          }
          .sukavina-ios-app main,
          .sukavina-ios-app [role='main'] {
            width: 100%;
            max-width: 100%;
          }
        }
      `;
      document.head.appendChild(style);
    })();
    """#
}
