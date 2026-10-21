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

struct ProfileView: View {
    private enum LegalPage: String, Identifiable {
        case privacy
        case support
        case deletion

        var id: String { rawValue }
    }

    // Observes AccountState (profile, Face ID setting), not the whole
    // session, which redrew this screen on every unrelated change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @EnvironmentObject private var account: AccountState
    @State private var biometricsSwitch = false
    @AppStorage("sukavina.appearanceMode") private var appearanceMode = AppAppearanceMode.system.rawValue
    @State private var showDelete = false
    @State private var showPasswordChange = false
    @State private var showPasswordChangeLimit = false
    @State private var legalPage: LegalPage?
    @State private var showSignOutConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    PortalPageTitle("Tài khoản")
                    ZStack {
                        Circle().fill(AppTheme.red.opacity(0.18)).frame(width: 96, height: 96)
                        Text(initials).font(.title.bold()).foregroundColor(AppTheme.redText)
                    }
                    Text(account.profile?.name ?? "Nhân viên").font(.title2.bold())
                    Text(account.profile?.employeeCode ?? "").font(.subheadline.monospacedDigit()).foregroundColor(AppTheme.muted)

                    accountSectionTitle("THÔNG TIN TÀI KHOẢN")
                    VStack(spacing: 0) {
                        ProfileLine(label: "Chức vụ", value: displayedJobTitle)
                        Divider().padding(.leading, 18)
                        ProfileLine(label: "Loại tài khoản", value: accountType)
                        Divider().padding(.leading, 18)
                        ProfileLine(label: "Quản lý trực tiếp", value: displayedManagerName)
                    }
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                    accountSectionTitle("GIAO DIỆN")
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 9) {
                            Label("Chế độ hiển thị", systemImage: "circle.lefthalf.filled")
                                .font(.headline)
                            Picker("Chế độ hiển thị", selection: $appearanceMode) {
                                ForEach(AppAppearanceMode.allCases) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                    }
                    .padding(18)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    accountSectionTitle("BẢO MẬT")
                    Button {
                        if !isDemoAccount && !session.hasLinkedEmail { session.presentMissingEmailForPasswordChange() }
                        else if !isDemoAccount && passwordChangedThisMonth { showPasswordChangeLimit = true }
                        else { showPasswordChange = true }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "key.fill").foregroundColor(AppTheme.red).frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Đổi mật khẩu").font(.headline).foregroundColor(.primary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(AppTheme.muted)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    HStack(spacing: 14) {
                        Image(systemName: session.biometricIcon)
                            .font(.title3)
                            .foregroundColor(AppTheme.red)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Đăng nhập bằng \(session.biometricName)")
                                .font(.headline)
                        }
                        Spacer(minLength: 8)
                        // Named for VoiceOver; the visible text sits beside it.
                        // The switch follows the tap at once and then the
                        // result: a cancelled or failed change leaves the
                        // setting as it was, which publishes nothing, so the
                        // switch must be put back from here.
                        Toggle("Đăng nhập bằng \(session.biometricName)", isOn: Binding(
                            get: { biometricsSwitch },
                            set: { enabled in
                                biometricsSwitch = enabled
                                Task {
                                    await session.setBiometricLogin(enabled: enabled)
                                    biometricsSwitch = account.biometricsEnabled
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(AppTheme.red)
                        .onAppear { biometricsSwitch = account.biometricsEnabled }
                        .onChange(of: account.biometricsEnabled) { _, enabled in biometricsSwitch = enabled }
                    }
                    .padding(18)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    accountSectionTitle("QUYỀN RIÊNG TƯ & HỖ TRỢ")
                    VStack(spacing: 0) {
                        Button {
                            legalPage = .privacy
                        } label: {
                            accountLink(icon: "hand.raised.fill", title: "Chính sách quyền riêng tư", opensExternally: false)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 58)
                        Button {
                            legalPage = .support
                        } label: {
                            accountLink(icon: "questionmark.circle.fill", title: "Hỗ trợ người dùng", opensExternally: false)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 58)
                        Button {
                            legalPage = .deletion
                        } label: {
                            accountLink(icon: "person.crop.circle.badge.minus", title: "Hướng dẫn xóa tài khoản", opensExternally: false)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 58)
                        Button {
                            guard let settingsURL = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                            UIApplication.shared.open(settingsURL)
                        } label: {
                            accountLink(icon: "bell.badge.fill", title: "Cài đặt thông báo")
                        }
                        .buttonStyle(.plain)
                    }
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    accountSectionTitle("PHIÊN ĐĂNG NHẬP")
                    Button {
                        showSignOutConfirmation = true
                    } label: {
                        Label("Đăng xuất", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.headline)
                            .foregroundColor(AppTheme.redText)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    if (account.profile?.protected != true || account.profile?.employeeCode == "DEMO") && account.profile?.accountType != "SUPER_ADMIN" {
                        accountSectionTitle("VÙNG NGUY HIỂM")
                        Button("Yêu cầu xóa tài khoản", role: .destructive) { showDelete = true }
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                }
                .padding(20)
                .padding(.bottom, 90)
            }
            .hidesPortalBottomScrollEdgeEffect()
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .alert("Xóa tài khoản vĩnh viễn?", isPresented: $showDelete) {
                Button("Hủy", role: .cancel) {}
                Button("Xóa vĩnh viễn", role: .destructive) {
                    Task { _ = await session.deleteAccount() }
                }
            } message: {
                Text("Thao tác này không thể hoàn tác. Tài khoản, dữ liệu cá nhân, đơn từ, lựa chọn món và dữ liệu ứng dụng liên quan sẽ bị xóa. Hồ sơ chấm công hoặc hồ sơ lao động bắt buộc có thể vẫn được lưu theo chính sách Công ty.")
            }
        }
        .sheet(isPresented: $showPasswordChange) {
            PasswordChangeView().sessionEnvironment(session)
        }
        .sheet(item: $legalPage) { page in
            NativeLegalView(page: {
                switch page {
                case .privacy: return .privacy
                case .support: return .support
                case .deletion: return .deletion
                }
            }())
        }
        .alert("Chưa thể đổi mật khẩu", isPresented: $showPasswordChangeLimit) {
            Button("Đã hiểu", role: .cancel) {}
        } message: {
            Text("Bạn chỉ được đổi mật khẩu một lần mỗi tháng. Bạn có thể đổi lại từ ngày 01/\(nextPasswordChangeMonth).")
        }
        .alert("Xác nhận đăng xuất?", isPresented: $showSignOutConfirmation) {
            Button("Hủy", role: .cancel) {}
            Button("Đăng xuất", role: .destructive) { session.signOut() }
        } message: {
            Text("Bạn sẽ cần đăng nhập lại để tiếp tục sử dụng Sukavina trên thiết bị này.")
        }
    }

    private var initials: String {
        let words = (account.profile?.name ?? "NV").split(separator: " ")
        return words.suffix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
    private var accountType: String {
        switch account.profile?.accountType {
        case "SUPER_ADMIN": return "Quản trị viên tổng"
        case "ADMIN": return "Quản trị viên"
        default: return "Nhân viên"
        }
    }
    /// auth/me exposes the employee's role, kept in sync with their
    /// job title when an administrator updates the employee record.
    private var displayedJobTitle: String {
        let title = account.profile?.role.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Chưa cập nhật" : title
    }
    /// The session keeps the full profile (auth/me) for the signed-in account
    /// (a token renewal no longer blanks it), so read it directly.
    private var displayedManagerName: String {
        let name = account.profile?.managerFullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Chưa cập nhật" : name
    }

    private var passwordChangedThisMonth: Bool {
        if isAdminAccount { return false }
        guard let changedAt = account.profile?.passwordChangedAt else { return false }
        return VietnamTime.calendar.isDate(changedAt, equalTo: Date(), toGranularity: .month)
    }
    private var isAdminAccount: Bool {
        account.profile?.accountType == "ADMIN" || account.profile?.accountType == "SUPER_ADMIN"
    }
    private var isDemoAccount: Bool { account.profile?.isDemoAccount == true }

    private func accountSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .tracking(1.2)
            .foregroundColor(AppTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }
    private func accountLink(icon: String, title: String, opensExternally: Bool = true) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundColor(AppTheme.red).frame(width: 26)
            Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
            Spacer()
            Image(systemName: opensExternally ? "arrow.up.right" : "chevron.right")
                .font(.caption.bold())
                .foregroundColor(AppTheme.muted)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
    private var nextPasswordChangeMonth: String {
        let next = VietnamTime.calendar.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        return VietnamTime.monthYear.string(from: next)
    }
}

struct NativeLegalView: View {
    enum Page {
        case privacy
        case support
        case deletion
    }

    @Environment(\.dismiss) private var dismiss
    let page: Page

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(AppTheme.red.opacity(0.15))
                            .frame(width: 62, height: 62)
                        Image(systemName: page == .privacy ? "hand.raised.fill" : page == .support ? "questionmark.bubble.fill" : "person.crop.circle.badge.minus")
                            .font(.title2)
                            .foregroundColor(AppTheme.red)
                    }
                    Text(page == .privacy ? "Quyền riêng tư tại Sukavina" : page == .support ? "Chúng tôi có thể hỗ trợ gì?" : "Kiểm soát tài khoản của bạn")
                        .font(.title2.bold())
                    Text(page == .privacy ? "Cập nhật lần cuối: 29/07/2026" : page == .support ? "Hỗ trợ dành riêng cho nhân viên Sukavina" : "Hướng dẫn dành cho tài khoản nội bộ")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.muted)

                    if page == .privacy {
                        legalSection("Ứng dụng nội bộ", "Sukavina chỉ dành cho nhân viên và người được Công ty ủy quyền. Tài khoản do Công ty tạo, cấp và quản lý; ứng dụng không có đăng ký công khai.")
                        legalSection("Dữ liệu được xử lý", "Hệ thống xử lý hồ sơ công việc, thông tin liên hệ, chấm công, đơn từ, lựa chọn suất ăn, thông báo và dữ liệu bảo mật cần thiết để vận hành.")
                        legalSection("Không quảng cáo hoặc theo dõi", "Sukavina không hiển thị quảng cáo, không bán dữ liệu và không theo dõi người dùng giữa các ứng dụng hoặc website. Ứng dụng không truy cập vị trí, danh bạ hoặc micro.")
                        legalSection("Camera", "Camera chỉ được dùng trên tài khoản nhà ăn để quét mã QR suất ăn, và chỉ khi bạn mở màn hình quét. Ứng dụng chỉ đọc nội dung mã QR, không chụp, lưu hay gửi hình ảnh. Tài khoản nhân viên không dùng camera. Bạn có thể tắt quyền này trong Cài đặt > Sukavina.")
                        legalSection("Sinh trắc học", "Face ID và Touch ID được xử lý trên thiết bị. Sukavina chỉ nhận kết quả xác thực, không nhận hoặc lưu khuôn mặt, vân tay hay mẫu sinh trắc học.")
                        legalSection("Lưu trữ và quyền của nhân viên", "Dữ liệu được bảo vệ bằng HTTPS và giới hạn truy cập theo tài khoản. Nhân viên có thể yêu cầu xem, sửa hoặc xóa dữ liệu trong phạm vi cho phép; hồ sơ bắt buộc có thể được lưu theo quy định.")
                    } else if page == .support {
                        legalSection("Liên hệ hỗ trợ", "Email: group@sukavina.com")
                        legalSection("Khi báo lỗi", "Vui lòng cung cấp mã nhân viên, mô tả sự cố, thời điểm xảy ra và ảnh chụp màn hình nếu có.")
                        legalSection("Bảo vệ tài khoản", "Không gửi mật khẩu hoặc mã OTP cho bất kỳ ai, kể cả khi yêu cầu hỗ trợ.")
                        legalSection("Xóa tài khoản", "Bạn có thể gửi yêu cầu trong tab Tài khoản. Nếu không thể đăng nhập, hãy gửi yêu cầu từ email đã liên kết tới group@sukavina.com.")
                    } else {
                        legalSection("Xóa trong ứng dụng", "Quay lại tab Tài khoản, chọn “Yêu cầu xóa tài khoản” ở cuối trang, đọc kỹ cảnh báo rủi ro và xác nhận thao tác.")
                        legalSection("Không thể đăng nhập", "Gửi yêu cầu từ email đã liên kết tới group@sukavina.com. Hãy cung cấp họ tên và mã nhân viên, không gửi mật khẩu hoặc mã OTP.")
                        legalSection("Dữ liệu được xử lý", "Tài khoản ứng dụng và dữ liệu không còn cần thiết sẽ bị xóa. Hồ sơ lao động, chấm công hoặc dữ liệu bắt buộc có thể được giữ theo chính sách Công ty và quy định áp dụng.")
                        legalSection("Lưu ý", "Xóa tài khoản là thao tác không thể hoàn tác. Hãy liên hệ Nhân sự nếu bạn chỉ cần sửa thông tin hồ sơ.")
                    }
                }
                .padding(22)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle(page == .privacy ? "Chính sách quyền riêng tư" : page == .support ? "Hỗ trợ" : "Xóa tài khoản")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundColor(AppTheme.redText)
                }
            }
        }
    }

    private func legalSection(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(content)
                .font(.subheadline)
                .foregroundColor(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct PasswordChangeView: View {
    // Observes AccountState and the working flag (below) only: the form
    // redrew while typing on every unrelated session change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @EnvironmentObject private var account: AccountState
    @State private var isSessionWorking = false
    @Environment(\.dismiss) private var dismiss
    /// Shown by the app container while the default password is in use: it
    /// cannot be closed, only completed or left by signing out.
    var isForced = false
    @State private var email = ""
    @State private var code = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var otpSent = false
    @State private var completed = false
    @State private var attemptedSubmit = false

    private var isDemoAccount: Bool { account.profile?.isDemoAccount == true }

    private var currentPasswordError: String? {
        guard isDemoAccount,
              let message = account.passwordChangeError,
              message.localizedCaseInsensitiveContains("Mật khẩu hiện tại") else { return nil }
        return message
    }

    private var reusedPasswordError: String? {
        guard isDemoAccount,
              let message = account.passwordChangeError,
              message.localizedCaseInsensitiveContains("Mật khẩu mới phải khác") else { return nil }
        return message
    }

    /// The error under the form, unless it is shown under its field (the
    /// demo account's current/reused password). A demo account's other
    /// errors (no connection, ...) used to be shown nowhere.
    private var regularAccountError: String? {
        guard currentPasswordError == nil, reusedPasswordError == nil else { return nil }
        return account.passwordChangeError
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(AppTheme.red.opacity(0.14)).frame(width: 58, height: 58)
                            Image(systemName: "key.fill").font(.title2).foregroundColor(AppTheme.red)
                        }
                        Text(isForced ? "Đổi mật khẩu mặc định" : "Bảo vệ tài khoản").font(.title2.bold())
                        Text(isForced
                             ? "Bạn đang dùng mật khẩu mặc định. Hãy đặt mật khẩu mới để tiếp tục sử dụng ứng dụng."
                             : (isDemoAccount
                                ? "Nhập mật khẩu hiện tại trước khi thiết lập mật khẩu mới."
                                : "Xác minh email trước khi thiết lập mật khẩu mới."))
                            .font(.subheadline).foregroundColor(AppTheme.muted)
                    }

                    if !isDemoAccount { HStack(spacing: 10) {
                        stepBadge(number: 1, title: "Nhận OTP", active: true)
                        Rectangle().fill(otpSent ? AppTheme.red : AppTheme.fieldBorder).frame(height: 2)
                        stepBadge(number: 2, title: "Mật khẩu mới", active: otpSent)
                    } }

                    if !isDemoAccount { VStack(alignment: .leading, spacing: 14) {
                        Label(otpSent ? "OTP đã gửi tới \(email)" : (isDemoAccount ? "Xác minh qua Thông báo" : "Xác minh qua email"), systemImage: isDemoAccount ? "bell.badge.fill" : "envelope.badge.fill")
                            .font(.headline).foregroundColor(AppTheme.redText)
                        Text(otpSent
                             ? "Mã gồm 6 số và có hiệu lực trong 10 phút."
                             : (isDemoAccount
                                ? "Mã OTP giả định sẽ được gửi vào mục Thông báo và có hiệu lực trong 10 phút."
                                : "Mã OTP sẽ được gửi tới email liên kết. Nếu chưa có email, vui lòng liên hệ Nhân sự để cập nhật."))
                            .font(.subheadline).foregroundColor(AppTheme.muted)
                    }
                    .padding(18).background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.cardBorder)) }

                    // Before the OTP is sent: the Profile entry point checks
                    // for an email first, the forced screen cannot, so say it
                    // here (and show a failed "Gửi mã OTP" at all).
                    if !otpSent && !isDemoAccount {
                        if isForced && !session.hasLinkedEmail {
                            Label("Tài khoản chưa có email liên kết nên chưa thể nhận mã OTP. Vui lòng liên hệ Nhân sự để cập nhật email, sau đó mở lại ứng dụng.", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline).foregroundColor(AppTheme.redText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if let regularAccountError {
                            Label(regularAccountError, systemImage: "exclamationmark.circle.fill")
                                .font(.caption).foregroundColor(AppTheme.redText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if otpSent || isDemoAccount {
                        VStack(spacing: 14) {
                            if isDemoAccount {
                                NativeSecureField(title: "Mật khẩu hiện tại", text: $currentPassword)
                                    .onChange(of: currentPassword) { _, _ in session.clearPasswordChangeError() }
                                if attemptedSubmit && currentPassword.isEmpty {
                                    validationMessage("Vui lòng nhập mật khẩu hiện tại.")
                                }
                                if let currentPasswordError {
                                    Label(currentPasswordError, systemImage: "exclamationmark.circle.fill")
                                        .font(.caption).foregroundColor(AppTheme.redText).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                NativeField(title: "Mã OTP gồm 6 số", text: $code, icon: "number", keyboard: .numberPad, textContentType: .oneTimeCode)
                                    .onChange(of: code) { _, value in
                                        code = String(value.filter(\.isNumber).prefix(6))
                                        session.clearPasswordChangeError()
                                    }
                                if attemptedSubmit && code.count != 6 {
                                    validationMessage("Mã OTP phải gồm đủ 6 chữ số.")
                                }
                            }
                            NativeSecureField(title: "Mật khẩu mới, ít nhất 6 ký tự gồm chữ và số", text: $newPassword)
                                .onChange(of: newPassword) { _, _ in session.clearPasswordChangeError() }
                            if let reusedPasswordError {
                                Label(reusedPasswordError, systemImage: "exclamationmark.circle.fill")
                                    .font(.caption).foregroundColor(AppTheme.redText).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            NativeSecureField(title: "Nhập lại mật khẩu mới", text: $confirmPassword)
                            if attemptedSubmit && newPassword != confirmPassword {
                                validationMessage("Mật khẩu nhập lại không khớp.")
                            }
                            if attemptedSubmit, let passwordRuleError {
                                validationMessage(passwordRuleError)
                            }
                            if let regularAccountError {
                                Label(regularAccountError, systemImage: "exclamationmark.circle.fill")
                                    .font(.caption).foregroundColor(AppTheme.redText).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(18).background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    Button {
                        attemptedSubmit = true
                        if isDemoAccount {
                            guard canConfirm else { return }
                            Task {
                                if await session.confirmPasswordChange(currentPassword: currentPassword, newPassword: newPassword) { completed = true }
                            }
                        } else if otpSent {
                            guard canConfirm else { return }
                            Task {
                                if await session.confirmPasswordChange(code: code, newPassword: newPassword) { completed = true }
                            }
                        } else {
                            Task {
                                if let response = await session.requestPasswordChange() {
                                    email = response.email
                                    otpSent = true
                                }
                            }
                        }
                    } label: {
                        HStack {
                            if isSessionWorking { ProgressView().tint(.white) }
                            Text(isDemoAccount || otpSent ? "Xác nhận đổi mật khẩu" : "Gửi mã OTP").fontWeight(.bold)
                            Spacer()
                            Image(systemName: isDemoAccount || otpSent ? "checkmark.shield.fill" : "arrow.right")
                        }.padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.plain).foregroundColor(.white).background(AppTheme.red)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .disabled(isSessionWorking)
                    .opacity(isSessionWorking ? 0.55 : 1)
                }
                .padding(22)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("Đổi mật khẩu")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isForced {
                        Button("Đăng xuất") { session.signOut() }
                    } else {
                        Button("Đóng") { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(isForced)
            .onReceive(session.$isWorking) { isSessionWorking = $0 }
            .alert("Đổi mật khẩu thành công", isPresented: $completed) {
                // Forced: the refreshed profile clears the flag and the app
                // container closes this screen itself.
                Button("Hoàn tất") { if !isForced { dismiss() } }
            } message: {
                Text("Các thiết bị khác đang đăng nhập tài khoản này đã được đăng xuất; thiết bị này vẫn tiếp tục sử dụng bình thường.")
            }
        }
    }

    private var canConfirm: Bool {
        (isDemoAccount ? !currentPassword.isEmpty : (code.count == 6 && code.allSatisfy(\.isNumber))) &&
            isPasswordValid && newPassword == confirmPassword
    }

    private var isPasswordValid: Bool { passwordRuleError == nil }

    private var passwordRuleError: String? { PasswordPolicy.problem(newPassword) }

    private func validationMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundColor(AppTheme.redText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func stepBadge(number: Int, title: String, active: Bool) -> some View {
        HStack(spacing: 7) {
            Text("\(number)").font(.caption.bold()).foregroundColor(active ? .white : AppTheme.muted)
                .frame(width: 25, height: 25).background(active ? AppTheme.red : AppTheme.field)
                .clipShape(Circle())
            Text(title).font(.caption.weight(.semibold)).foregroundColor(active ? .primary : AppTheme.muted)
        }.fixedSize()
    }
}

struct ProfileLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(AppTheme.muted)
            Spacer()
            Text(value).fontWeight(.medium)
        }.padding(18)
    }
}

struct NativeField: View {
    let title: String
    @Binding var text: String
    let icon: String
    var keyboard: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundColor(AppTheme.muted)
            TextField(title, text: $text)
                .keyboardType(keyboard)
                .textContentType(textContentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(AppTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AppTheme.fieldBorder, lineWidth: 1))
    }
}

struct NativeSecureField: View {
    let title: String
    @Binding var text: String
    @State private var visible = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").frame(width: 22).foregroundColor(AppTheme.muted)
            Group {
                if visible { TextField(title, text: $text) }
                else { SecureField(title, text: $text) }
            }
            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }.foregroundColor(AppTheme.muted)
            .accessibilityLabel(visible ? "Ẩn mật khẩu" : "Hiện mật khẩu")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(AppTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AppTheme.fieldBorder, lineWidth: 1))
    }
}
