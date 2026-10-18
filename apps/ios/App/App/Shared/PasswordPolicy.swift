import Foundation

/// The new-password rule (at least 6 characters with a letter and a digit),
/// checked before sending. Shared by "Quên mật khẩu" and "Đổi mật khẩu",
/// which each had their own copy.
enum PasswordPolicy {
    static let minimumLength = 6

    /// Why `password` cannot be used, or nil when it can.
    static func problem(_ password: String) -> String? {
        if password.count < minimumLength { return "Mật khẩu phải có ít nhất \(minimumLength) ký tự." }
        if password.rangeOfCharacter(from: .letters) == nil { return "Mật khẩu phải có ít nhất một chữ cái." }
        if password.rangeOfCharacter(from: .decimalDigits) == nil { return "Mật khẩu phải có ít nhất một chữ số." }
        return nil
    }
}
