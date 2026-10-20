import Foundation
import Security

/// The attendance widget's token, shared by the app and its widget through a
/// Keychain access group (`<Team ID>.net.sukavinagroup.shared`) instead of
/// the App Group's UserDefaults plist, which is a plain file in the shared
/// container and is included in device backups. The item is readable after
/// the first unlock (the widget refreshes while the phone is locked) and
/// never leaves this device.
///
/// The group comes from the `SukavinaKeychainGroup` Info.plist key, set to
/// `$(AppIdentifierPrefix)net.sukavinagroup.shared` in both targets. A build
/// signed without that entitlement (or an unsigned CI build) has no usable
/// group: `isAvailable` is false and callers keep the App Group fallback, so
/// the widget never stops working.
enum WidgetTokenKeychain {
    private static let service = "net.sukavinagroup.widget"
    private static let account = "attendance-widget-token"

    /// The shared access group, when this build is signed with it.
    static var accessGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SukavinaKeychainGroup") as? String,
              isTeamPrefixed(value) else { return nil }
        return value
    }

    static var isAvailable: Bool { accessGroup != nil }

    static func load() -> String? {
        guard var query = baseQuery() else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    /// True when the token is stored in the shared Keychain group.
    @discardableResult
    static func save(_ token: String) -> Bool {
        guard let query = baseQuery() else { return false }
        let data = Data(token.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        guard let query = baseQuery() else { return }
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery() -> [String: Any]? {
        guard let accessGroup else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    /// "ABCDE12345.net.sukavinagroup.shared": a 10-character Team ID prefix.
    /// An unexpanded or empty `$(AppIdentifierPrefix)` does not qualify.
    static func isTeamPrefixed(_ group: String) -> Bool {
        guard let dot = group.firstIndex(of: ".") else { return false }
        let prefix = group[..<dot]
        return prefix.count == 10
            && prefix.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
            && group[group.index(after: dot)...] == "net.sukavinagroup.shared"
    }
}
