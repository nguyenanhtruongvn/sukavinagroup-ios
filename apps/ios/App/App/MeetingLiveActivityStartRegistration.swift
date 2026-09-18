import ActivityKit
import Foundation
import Security

@available(iOS 17.0, *)
enum MeetingLiveActivityStartRegistration {
    private static let baseURL = URL(string: "https://sukavinagroup.net/api/")!

    static func observe() {
        Task {
            for await token in Activity<MeetingLiveActivityAttributes>.pushToStartTokenUpdates {
                await upload(token: token)
            }
        }
    }

    private static func upload(token: Data) async {
        guard let accessToken = accessToken() else { return }

        let tokenValue = token.map {
            String(format: "%02x", $0)
        }.joined()

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
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                ConnectionDiagnostics.record("Live Activity start token upload rejected")
                return
            }
        } catch {
            ConnectionDiagnostics.record("Live Activity start token upload failed: \(error.localizedDescription)")
        }
    }

    private static func accessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.sukavinagroup.user",
            kSecAttrAccount as String: "access-token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
