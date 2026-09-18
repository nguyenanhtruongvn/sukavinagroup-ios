import ActivityKit
import Foundation

/// Registers the device-scoped token that lets the server start a new Live
/// Activity while the app is suspended. This is deliberately separate from
/// an activity's push token, which can only update or end an existing one.
@available(iOS 17.2, *)
enum MeetingLiveActivityStartRegistration {
    private static let baseURL = URL(string: "https://sukavinagroup.net/api/")!
    private static var observationTask: Task<Void, Never>?

    static func observe() {
        // Do not consume the initial token stream before a user has signed
        // in: Apple may not emit the current token a second time.
        guard KeychainStore.loadToken() != nil, observationTask == nil else { return }

        observationTask = Task {
            for await token in Activity<MeetingLiveActivityAttributes>.pushToStartTokenUpdates {
                await upload(token: token)
            }
        }
    }

    private static func upload(token: Data) async {
        guard let accessToken = KeychainStore.loadToken() else {
            ConnectionDiagnostics.record("Live Activity start token skipped: no access token")
            return
        }

        let tokenValue = token.map { String(format: "%02x", $0) }.joined()
        guard !tokenValue.isEmpty else { return }

        var request = URLRequest(
            url: URL(string: "me/meeting-bookings/live-activity-start-token", relativeTo: baseURL)!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": tokenValue])

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

}
