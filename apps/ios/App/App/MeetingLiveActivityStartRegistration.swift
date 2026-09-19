import ActivityKit
import Foundation

/// Registers the device-scoped token that lets the server start a new Live
/// Activity while the app is suspended. This is deliberately separate from
/// an activity's push token, which can only update or end an existing one.
@available(iOS 17.2, *)
enum MeetingLiveActivityStartRegistration {
    private static let baseURL = URL(string: "https://sukavinagroup.net/api/")!
    private static let cachedTokenKey = "net.sukavinagroup.live-activity-push-to-start-token"
    private static let installationIDKey = "net.sukavinagroup.live-activity-installation-id"
    private static var observationTask: Task<Void, Never>?

    static func observe() {
        // ActivityKit exposes the token that is valid *right now*. Upload it
        // immediately instead of relying only on the updates sequence: the
        // sequence isn't required to re-emit an already-issued token after a
        // login, app update, or a previous failed upload.
        syncCurrentTokenIfAvailable()

        guard observationTask == nil else { return }
        observationTask = Task {
            for await token in Activity<MeetingLiveActivityAttributes>.pushToStartTokenUpdates {
                let tokenValue = token.map { String(format: "%02x", $0) }.joined()
                guard !tokenValue.isEmpty else { continue }

                // Persist before networking. Push-to-Start tokens may not be
                // re-emitted merely because a previous upload failed.
                UserDefaults.standard.set(tokenValue, forKey: cachedTokenKey)
                await upload(tokenValue: tokenValue)
            }
        }
    }

    private static func syncCurrentTokenIfAvailable() {
        if let token = Activity<MeetingLiveActivityAttributes>.pushToStartToken {
            let tokenValue = token.map { String(format: "%02x", $0) }.joined()
            guard !tokenValue.isEmpty else { return }
            UserDefaults.standard.set(tokenValue, forKey: cachedTokenKey)
            Task {
                await upload(tokenValue: tokenValue)
            }
            return
        }

        retryCachedTokenIfPossible()
    }

    private static func retryCachedTokenIfPossible() {
        guard KeychainStore.loadToken() != nil,
              let tokenValue = UserDefaults.standard.string(forKey: cachedTokenKey),
              !tokenValue.isEmpty else { return }

        Task {
            await upload(tokenValue: tokenValue)
        }
    }

    private static func upload(tokenValue: String) async {
        guard let accessToken = KeychainStore.loadToken() else {
            ConnectionDiagnostics.record("Live Activity start token cached until sign-in")
            return
        }

        var request = URLRequest(
            url: URL(string: "me/meeting-bookings/live-activity-start-token", relativeTo: baseURL)!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: [
                "token": tokenValue,
                "installationId": installationID,
            ]
        )

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                ConnectionDiagnostics.record("Live Activity start token upload was rejected")
                return
            }
            ConnectionDiagnostics.record("Live Activity start token registered")
        } catch {
            ConnectionDiagnostics.record("Live Activity start token upload failed: \(error.localizedDescription)")
        }
    }

    private static var installationID: String {
        if let value = UserDefaults.standard.string(forKey: installationIDKey),
           !value.isEmpty {
            return value
        }

        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: installationIDKey)
        return value
    }
}
