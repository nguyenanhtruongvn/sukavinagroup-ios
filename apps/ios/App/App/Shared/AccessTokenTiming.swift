import Foundation

/// When to renew the session: shortly before the access token actually
/// expires, read from its JWT \`exp\` claim. A fixed "every 12 hours" loop
/// ignored the token's age: a session restored with a 20-hour-old token ran
/// into 401s before the next renewal. Mirrors Android SessionTokens timing.
enum AccessTokenTiming {
    /// Renew this long before expiry.
    static let renewalLead: TimeInterval = 10 * 60

    /// The \`exp\` of a JWT, or nil when the token is not a readable JWT.
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (object["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// When to renew \`token\`; \`fallback\` after now when its expiry is unknown.
    static func renewalDate(for token: String, now: Date, fallback: TimeInterval = 12 * 60 * 60) -> Date {
        guard let expiry = expiry(of: token) else { return now.addingTimeInterval(fallback) }
        return max(now, expiry.addingTimeInterval(-renewalLead))
    }
}
